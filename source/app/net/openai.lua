-- OpenAI-compatible chat completions client.
-- Works with api.openai.com or any server speaking the same protocol
-- (llama.cpp server, Ollama, vLLM, OpenRouter, ...).

OpenAI = {}

-- messages: OpenAI-format message array
-- tools: OpenAI-format tool definition array (or nil)
-- callback(message, err, usage): message = choices[1].message on success;
-- usage = the response "usage" table (prompt/completion/total tokens) if
-- the server reported one
function OpenAI.chat(messages, tools, callback)
    local c = Config.data.api
    local payload = {
        model = c.model,
        messages = messages,
        stream = false,
    }
    if tools ~= nil and #tools > 0 then
        payload.tools = tools
    end

    Http.request({
        host = c.host,
        port = c.port,
        ssl = c.ssl,
        method = "POST",
        path = (c.basePath or "/v1") .. "/chat/completions",
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. (c.key or ""),
        },
        body = json.encode(payload),
        callback = function(resp)
            if not resp.ok then
                callback(nil, resp.error or "network error")
                return
            end
            if resp.status ~= 200 then
                local snippet = (resp.body or ""):sub(1, 200)
                callback(nil, "HTTP " .. tostring(resp.status) .. " " .. snippet)
                return
            end
            local data = json.decode(resp.body)
            if data == nil or data.choices == nil or data.choices[1] == nil then
                callback(nil, "unexpected response from LLM")
                return
            end
            callback(data.choices[1].message, nil, data.usage)
        end,
    })
end
