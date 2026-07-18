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

-- wavPath: file in the game's Data directory (e.g. "rec.wav")
-- callback(text, err)
function STT.transcribe(wavPath, callback)
    local wav, ferr = readWholeFile(wavPath)
    if wav == nil then
        callback(nil, ferr)
        return
    end

    local c = Config.data.api
    local sttModel = Config.data.stt.model or "whisper-1"
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
    parts[#parts + 1] = "--" .. boundary .. "\r\n"
        .. 'Content-Disposition: form-data; name="file"; filename="rec.wav"\r\n'
        .. "Content-Type: audio/wav\r\n\r\n"
    parts[#parts + 1] = wav
    parts[#parts + 1] = "\r\n--" .. boundary .. "--\r\n"

    Http.request({
        host = c.host,
        port = c.port,
        ssl = c.ssl,
        method = "POST",
        path = (c.basePath or "/v1") .. "/audio/transcriptions",
        headers = {
            ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
            ["Authorization"] = "Bearer " .. (c.key or ""),
        },
        body = table.concat(parts),
        callback = function(resp)
            if not resp.ok then
                callback(nil, resp.error or "network error")
                return
            end
            if resp.status ~= 200 then
                callback(nil, "HTTP " .. tostring(resp.status) .. " " .. (resp.body or ""):sub(1, 160))
                return
            end
            local data = json.decode(resp.body)
            if data == nil or data.text == nil then
                callback(nil, "unexpected transcription response")
                return
            end
            callback(data.text, nil)
        end,
    })
end
