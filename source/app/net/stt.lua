-- Speech-to-text: uploads a WAV file recorded from the Playdate microphone
-- to an OpenAI-compatible /audio/transcriptions endpoint (Whisper API).

STT = {}

local function readWholeFile(path)
    local size = playdate.file.getSize(path)
    if size == nil or size <= 0 then return nil, "empty recording" end
    local f, err = playdate.file.open(path, playdate.file.kFileRead)
    if f == nil then return nil, err or "cannot open recording" end
    local chunks = {}
    local remaining = size
    while remaining > 0 do
        local data = f:read(math.min(remaining, 32 * 1024))
        if data == nil or #data == 0 then break end
        chunks[#chunks + 1] = data
        remaining -= #data
    end
    f:close()
    return table.concat(chunks), nil
end

-- Resolve the endpoint: the dedicated STT server when enabled and
-- configured, otherwise the chat API endpoint.
-- Returns { host, port, ssl, basePath, key, external }.
function STT.endpoint()
    local s = Config.data.stt
    if s.useExternal == true then
        if s.host == nil or #s.host == 0 then
            return nil, "external STT is enabled but its host is empty"
        end
        return {
            host = s.host,
            port = s.port or (s.ssl and 443 or 80),
            ssl = s.ssl == true,
            basePath = (s.basePath ~= nil and #s.basePath > 0) and s.basePath or "/v1",
            -- deliberately NOT falling back to api.key: don't leak the LLM
            -- key to a different (usually local, auth-less) server
            key = s.key or "",
            external = true,
        }
    end
    local a = Config.data.api
    return {
        host = a.host,
        port = a.port,
        ssl = a.ssl,
        basePath = a.basePath or "/v1",
        key = a.key or "",
        external = false,
    }
end

-- wavPath: file in the game's Data directory (e.g. "rec.wav")
-- callback(text, err)
-- contextPrompt (optional): passed as the Whisper "prompt" field; live
-- dictation sends the tail of the transcript so far, which keeps chunk
-- boundaries coherent (spelling, casing, continuation).
function STT.transcribe(wavPath, callback, contextPrompt)
    local wav, ferr = readWholeFile(wavPath)
    if wav == nil then
        callback(nil, ferr)
        return
    end

    local c, endpointErr = STT.endpoint()
    if c == nil then
        callback(nil, endpointErr)
        return
    end
    local sttModel
    if c.external then
        sttModel = Config.data.stt.externalModel or "Systran/faster-whisper-small"
    else
        sttModel = Config.data.stt.model or "whisper-1"
    end
    local secs = playdate.getSecondsSinceEpoch()
    local boundary = "----PlayAgentBoundary" .. tostring(secs)

    local parts = {}
    local function field(name, value)
        parts[#parts + 1] = "--" .. boundary .. "\r\n"
            .. 'Content-Disposition: form-data; name="' .. name .. '"\r\n\r\n'
            .. value .. "\r\n"
    end
    field("model", sttModel)
    if Config.data.stt.language ~= nil and #Config.data.stt.language > 0 then
        field("language", Config.data.stt.language)
    end
    if contextPrompt ~= nil and #contextPrompt > 0 then
        field("prompt", contextPrompt)
    end
    parts[#parts + 1] = "--" .. boundary .. "\r\n"
        .. 'Content-Disposition: form-data; name="file"; filename="rec.wav"\r\n'
        .. "Content-Type: audio/wav\r\n\r\n"
    parts[#parts + 1] = wav
    parts[#parts + 1] = "\r\n--" .. boundary .. "--\r\n"

    local headers = {
        ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
    }
    if #c.key > 0 then
        headers["Authorization"] = "Bearer " .. c.key
    end

    Http.whenConnected(function(networkErr)
        if networkErr ~= nil then
            callback(nil, networkErr)
            return
        end
        Http.request({
            host = c.host,
            port = c.port,
            ssl = c.ssl,
            method = "POST",
            path = c.basePath .. "/audio/transcriptions",
            headers = headers,
            body = table.concat(parts),
            callback = function(resp)
                if not resp.ok then
                    callback(nil, "STT " .. c.host .. ": "
                        .. (resp.error or "network error"))
                    return
                end
                if resp.status ~= 200 then
                    callback(nil, "STT " .. c.host .. " HTTP "
                        .. tostring(resp.status) .. " "
                        .. (resp.body or ""):sub(1, 160))
                    return
                end
                local data = json.decode(resp.body)
                if data == nil or data.text == nil then
                    callback(nil, "unexpected transcription response from " .. c.host)
                    return
                end
                callback(data.text, nil)
            end,
        })
    end)
end
