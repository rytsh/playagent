-- Minimal MCP (Model Context Protocol) client over the Streamable HTTP
-- transport: JSON-RPC 2.0 via HTTP POST, answers either as plain JSON or
-- as an SSE stream (we parse both).

Mcp = {}
Mcp.clients = {} -- name -> McpClient (connected clients for the running session)

McpClient = {}
McpClient.__index = McpClient

local PROTOCOL_VERSION <const> = "2025-03-26"
-- Generous: the first request may include waking the Wi-Fi radio (up to
-- ~10s) plus a TLS handshake, which is slow on the device.
local CONNECT_TIMEOUT_MS <const> = 30000

-- server: { name, host, port, ssl, path }
function McpClient.new(server)
    local self = setmetatable({}, McpClient)
    self.server = server
    self.sessionId = nil
    self.nextId = 1
    self.tools = {}   -- MCP tool list (as returned by tools/list)
    self.prompts = {} -- MCP prompt list
    self.ready = false
    self.lastError = nil
    return self
end

-- Extract the JSON-RPC response object from a Streamable HTTP body.
function Mcp.parseBody(body, headers)
    local ctype = Http.header(headers, "Content-Type") or ""
    if ctype:find("event%-stream") or (body or ""):match("^%s*[a-z]+:") then
        local last = nil
        for line in (body or ""):gmatch("[^\r\n]+") do
            local d = line:match("^data:%s*(.+)$")
            if d ~= nil then
                local obj = json.decode(d)
                if obj ~= nil and (obj.result ~= nil or obj.error ~= nil) then
                    last = obj
                end
            end
        end
        return last
    end
    if body == nil or #body == 0 then return nil end
    return json.decode(body)
end

-- Requests are queued: the OS rejects concurrent requests with "Busy".
function McpClient:_post(payload, callback)
    self.queue = self.queue or {}
    self.queue[#self.queue + 1] = { payload = payload, callback = callback }
    self:_pump()
end

function McpClient:_pump()
    if self.inFlight or self.queue == nil or #self.queue == 0 then return end
    self.inFlight = true
    local item = table.remove(self.queue, 1)
    self:_send(item.payload, function(resp)
        self.inFlight = false
        item.callback(resp)
        self:_pump()
    end)
end

-- Each request uses its own connection. Reusing a keep-alive connection
-- looks tempting (TLS handshakes are slow on the device), but Playdate
-- delivers stale completion events on reused connections — the next request
-- then instantly "completes" with an empty body. Fresh connection per
-- request plus Connection: close is the reliable option; the JSON body is
-- parsed as soon as it is complete, so responses do not wait for teardown.
function McpClient:_send(payload, callback)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json, text/event-stream",
        ["Connection"] = "close",
    }
    if self.sessionId ~= nil then
        headers["Mcp-Session-Id"] = self.sessionId
    end
    Http.request({
        host = self.server.host,
        port = self.server.port,
        ssl = self.server.ssl,
        method = "POST",
        path = self.server.path or "/mcp",
        headers = headers,
        body = json.encode(payload),
        requestTimeout = CONNECT_TIMEOUT_MS / 1000,
        bodyComplete = function(body, responseHeaders)
            return Mcp.parseBody(body, responseHeaders) ~= nil
        end,
        callback = function(resp)
            local sid = Http.header(resp.headers, "Mcp-Session-Id")
            if sid ~= nil then self.sessionId = sid end
            callback(resp)
        end,
    })
end

-- callback(result, err)
function McpClient:rpc(method, params, callback)
    local id = self.nextId
    self.nextId = id + 1
    local payload = { jsonrpc = "2.0", id = id, method = method }
    if params ~= nil then payload.params = params end
    local function handle(resp)
        if not resp.ok then
            callback(nil, tostring(method) .. ": " .. (resp.error or "network error"))
            return
        end
        if resp.status ~= nil and resp.status >= 300 then
            callback(nil, tostring(method) .. ": HTTP " .. tostring(resp.status))
            return
        end
        local obj = Mcp.parseBody(resp.body, resp.headers)
        if obj == nil then
            -- Include diagnostics: which call, HTTP status, body prefix.
            local snippet = tostring(resp.body or ""):gsub("%s+", " "):sub(1, 50)
            print("MCP bad response [" .. tostring(method) .. "] status="
                .. tostring(resp.status) .. " body=" .. tostring(resp.body))
            callback(nil, "bad response [" .. tostring(method) .. " s="
                .. tostring(resp.status) .. "] " .. snippet)
            return
        end
        if obj.error ~= nil then
            callback(nil, obj.error.message or ("MCP error " .. tostring(obj.error.code)))
            return
        end
        callback(obj.result, nil)
    end
    self:_post(payload, handle)
end

-- callback(err) is optional.
function McpClient:notify(method, callback)
    self:_post({ jsonrpc = "2.0", method = method }, function(resp)
        if callback == nil then return end
        if not resp.ok then
            callback(resp.error or "network error")
        elseif resp.status ~= nil and resp.status >= 300 then
            callback("HTTP " .. tostring(resp.status))
        else
            callback(nil)
        end
    end)
end

-- Connects, then loads tools and prompts. callback(client, err)
function McpClient:connect(callback)
    local finished = false
    local timeoutTimer = nil
    local stage = "initialize"

    local function fail(err)
        if finished then return end
        finished = true
        if timeoutTimer ~= nil then timeoutTimer:remove() end
        self.lastError = err
        callback(nil, err)
    end

    local function ready()
        if finished then return end
        finished = true
        if timeoutTimer ~= nil then timeoutTimer:remove() end
        self.ready = true
        callback(self, nil)
    end

    timeoutTimer = playdate.timer.performAfterDelay(CONNECT_TIMEOUT_MS,
        function() fail("connection timed out (" .. stage .. ")") end)

    self:rpc("initialize", {
        protocolVersion = PROTOCOL_VERSION,
        -- NOTE: value must encode to a JSON object, so it cannot be an
        -- empty Lua table (json.encode would emit []).
        capabilities = { roots = { listChanged = false } },
        clientInfo = { name = "PlayAgent", version = "0.1.0" },
    }, function(result, err)
        if finished then return end
        if err ~= nil then
            fail(err)
            return
        end
        local capabilities = result and result.capabilities or {}
        self:notify("notifications/initialized")
        stage = "tools/prompts"
        do

            local pending = 0
            if capabilities.tools ~= nil then pending += 1 end
            if capabilities.prompts ~= nil then pending += 1 end
            if pending == 0 then
                ready()
                return
            end

            local failed = false
            local function listDone(err)
                if failed or finished then return end
                if err ~= nil then
                    failed = true
                    fail(err)
                    return
                end
                pending -= 1
                if pending == 0 then ready() end
            end

            -- Both lists load concurrently, each on its own connection.
            if capabilities.prompts ~= nil then
                self:rpc("prompts/list", nil, function(pres, perr)
                    if pres ~= nil and pres.prompts ~= nil then self.prompts = pres.prompts end
                    listDone(perr)
                end)
            end
            if capabilities.tools ~= nil then
                self:rpc("tools/list", nil, function(tres, terr)
                    if tres ~= nil and tres.tools ~= nil then self.tools = tres.tools end
                    listDone(terr)
                end)
            end
        end
    end)
end

-- callback(text, isError)
function McpClient:callTool(name, arguments, callback)
    local params = { name = name }
    if arguments ~= nil and next(arguments) ~= nil then
        params.arguments = arguments
    end
    self:rpc("tools/call", params, function(result, err)
        if err ~= nil then
            callback("MCP error: " .. err, true)
            return
        end
        local out = {}
        if result ~= nil and result.content ~= nil then
            for _, item in ipairs(result.content) do
                if item.type == "text" and item.text ~= nil then
                    out[#out + 1] = item.text
                else
                    out[#out + 1] = "[" .. tostring(item.type) .. " content]"
                end
            end
        end
        local text = table.concat(out, "\n")
        if #text == 0 then text = "(empty result)" end
        callback(text, result ~= nil and result.isError == true)
    end)
end

-- callback(messages, err) — messages in MCP prompt format
function McpClient:getPrompt(name, arguments, callback)
    local params = { name = name }
    if arguments ~= nil and next(arguments) ~= nil then
        params.arguments = arguments
    end
    self:rpc("prompts/get", params, function(result, err)
        if err ~= nil then
            callback(nil, err)
            return
        end
        callback(result and result.messages or {}, nil)
    end)
end

------------------------------------------------------------------------
-- Registry helpers
------------------------------------------------------------------------

-- Connect all enabled servers from Config. progress(name, err) is called per
-- server; done() after all finished.
function Mcp.connectAll(progress, done)
    local previous = Mcp.clients
    Mcp.clients = {}
    local servers = Config.enabledMcpServers()
    -- Servers connect one after another: the OS rejects concurrent
    -- requests with "Busy".
    local i = 0
    local function nextServer()
        i += 1
        local server = servers[i]
        if server == nil then
            done()
            return
        end
        local client = previous[server.name]
        local old = client and client.server
        if client ~= nil and client.ready
            and old.host == server.host and old.port == server.port
            and old.ssl == server.ssl and old.path == server.path then
            Mcp.clients[server.name] = client
            if progress ~= nil then progress(server.name, nil) end
            nextServer()
        else
            client = McpClient.new(server)
            client:connect(function(_, err)
                if err == nil then Mcp.clients[server.name] = client end
                if progress ~= nil then progress(server.name, err) end
                nextServer()
            end)
        end
    end
    nextServer()
end

local function sanitize(name)
    return (tostring(name):gsub("[^%w_%-]", "_"))
end

-- Build OpenAI-format tool definitions for every connected MCP server.
-- Returns defs, routing where routing[fnName] = { client = c, tool = "name" }.
function Mcp.openaiToolDefs()
    local defs, routing = {}, {}
    for sname, client in pairs(Mcp.clients) do
        for _, tool in ipairs(client.tools) do
            local fnName = sanitize(sname) .. "__" .. sanitize(tool.name)
            fnName = fnName:sub(1, 64)
            defs[#defs + 1] = {
                type = "function",
                ["function"] = {
                    name = fnName,
                    description = tool.description or ("Tool " .. tool.name .. " from MCP server " .. sname),
                    parameters = tool.inputSchema or { type = "object", properties = {} },
                },
            }
            routing[fnName] = { client = client, tool = tool.name }
        end
    end
    return defs, routing
end
