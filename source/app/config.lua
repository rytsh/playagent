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
    },
    stt = {
        model = "whisper-1",
        maxSeconds = 15,
        language = "", -- empty = auto
    },
    -- Remote MCP servers (Streamable HTTP transport).
    -- Each: { name, host, port, ssl, path, enabled }
    mcpServers = {},
    -- opencode servers to remote-control.
    -- Each: { name, host, port, username, password }
    remotes = {},
    personaId = "assistant",
    customPersona = "",
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
    deepMerge(data, DEFAULTS)
    -- datastore JSON round-trip turns empty tables into arrays; make sure
    -- mcpServers is a plain array table.
    if type(data.mcpServers) ~= "table" then data.mcpServers = {} end
    if type(data.remotes) ~= "table" then data.remotes = {} end
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

function Config.enabledMcpServers()
    local out = {}
    for _, s in ipairs(Config.data.mcpServers) do
        if s.enabled then out[#out + 1] = s end
    end
    return out
end
