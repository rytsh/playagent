-- Persistent app configuration, stored via playdate.datastore ("config.json").

Config = {}

local DEFAULTS = {
    api = {
        host = "api.openai.com",
        port = 443,
        ssl = true,
        basePath = "/v1",
        key = "",
        model = "gpt-4o-mini",
        -- context window of the model, used for the session fullness meter
        contextTokens = 128000,
    },
    stt = {
        model = "whisper-1",
        externalModel = "Systran/faster-whisper-small",
        maxSeconds = 15,
        language = "", -- empty = auto
        -- Separate STT endpoint. Only used when useExternal is true AND a
        -- host is set; otherwise transcription goes to the chat API
        -- endpoint (api.*). key may stay empty for LAN servers without
        -- auth (speaches / faster-whisper-server).
        useExternal = false,
        host = "",
        port = 8000,
        ssl = false,
        basePath = "/v1",
        key = "",
        -- Live dictation (LiveMic): speech is cut into small chunks that are
        -- transcribed while you keep talking.
        -- 5s chunks: pauses usually cut earlier; the hard limit only kicks
        -- in during continuous speech, and longer chunks transcribe better.
        chunkSeconds = 5,      -- hard upper bound per chunk
        minChunkSeconds = 1.2, -- don't cut before this much audio
        silenceMs = 350,       -- pause length that triggers a cut
        levelThreshold = 0.02, -- mic level below this counts as silence
    },
    -- Remote MCP servers (Streamable HTTP transport).
    -- Each: { name, host, port, ssl, path, enabled }
    mcpServers = {},
    -- opencode servers to remote-control.
    -- Each: { name, host, port, username, password }
    remotes = {},
    personaId = "assistant",
    customPersona = "",
    -- User-defined personas: plain name -> system prompt map.
    -- Editable from the Persona scene and by the agent itself via the
    -- add_persona / remove_persona tools (always behind a confirm dialog).
    personas = {},
}

local function deepMerge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            deepMerge(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

function Config.load()
    local data = playdate.datastore.read("config") or {}
    -- Before external STT had an explicit toggle/model field, its model was
    -- stored in stt.model. Preserve that setup without accidentally sending
    -- a local model name to the main API when external STT defaults to off.
    if type(data.stt) == "table"
        and data.stt.externalModel == nil
        and type(data.stt.host) == "string" and #data.stt.host > 0
        and type(data.stt.model) == "string" and data.stt.model ~= "whisper-1" then
        data.stt.externalModel = data.stt.model
        data.stt.model = "whisper-1"
    end
    deepMerge(data, DEFAULTS)
    -- Migrate the old live-dictation default: 3s chunks cut words
    -- mid-syllable. The settings UI never exposed this field, so a stored 3
    -- can only be the old default.
    if type(data.stt) == "table" and data.stt.chunkSeconds == 3 then
        data.stt.chunkSeconds = 5
    end
    -- datastore JSON round-trip turns empty tables into arrays; make sure
    -- mcpServers is a plain array table.
    if type(data.mcpServers) ~= "table" then data.mcpServers = {} end
    if type(data.remotes) ~= "table" then data.remotes = {} end
    if type(data.personas) ~= "table" then data.personas = {} end
    Config.data = data
end

-- Merge a provisioning payload (from tools/provision.py) into the config.
-- Returns a short summary of what was imported.
function Config.applyImport(t)
    local d = Config.data
    local parts = {}
    if type(t.api) == "table" then
        for k, v in pairs(t.api) do d.api[k] = v end
        parts[#parts + 1] = "api"
    end
    if type(t.stt) == "table" then
        for k, v in pairs(t.stt) do d.stt[k] = v end
        parts[#parts + 1] = "stt"
    end
    if type(t.mcpServers) == "table" then
        d.mcpServers = t.mcpServers
        parts[#parts + 1] = "mcp:" .. #t.mcpServers
    end
    if type(t.remotes) == "table" then
        d.remotes = t.remotes
        parts[#parts + 1] = "remotes:" .. #t.remotes
    end
    if type(t.personaId) == "string" then
        d.personaId = t.personaId
        parts[#parts + 1] = "persona"
    end
    if type(t.customPersona) == "string" then
        d.customPersona = t.customPersona
    end
    if type(t.personas) == "table" then
        local n = 0
        for name, prompt in pairs(t.personas) do
            if type(name) == "string" and type(prompt) == "string" then
                d.personas[name] = prompt
                n += 1
            end
        end
        if n > 0 then parts[#parts + 1] = "personas:" .. n end
    end
    Config.save()
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

function Config.addRemote(remote)
    table.insert(Config.data.remotes, remote)
    Config.save()
end

function Config.removeRemote(index)
    table.remove(Config.data.remotes, index)
    Config.save()
end

function Config.save()
    playdate.datastore.write(Config.data, "config")
end

function Config.addMcpServer(server)
    server.enabled = server.enabled ~= false
    table.insert(Config.data.mcpServers, server)
    Config.save()
end

function Config.removeMcpServer(index)
    table.remove(Config.data.mcpServers, index)
    Config.save()
end

function Config.setPersona(name, prompt)
    Config.data.personas[name] = prompt
    Config.save()
end

function Config.removePersona(name)
    Config.data.personas[name] = nil
    -- if the active persona was deleted, fall back to the default
    if Config.data.personaId == "user:" .. name then
        Config.data.personaId = "assistant"
    end
    Config.save()
end

function Config.enabledMcpServers()
    local out = {}
    for _, s in ipairs(Config.data.mcpServers) do
        if s.enabled then out[#out + 1] = s end
    end
    return out
end
