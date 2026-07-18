-- REST client for an opencode server (`opencode serve`).
-- Plain HTTP + optional Basic auth; see https://opencode.ai/docs/server

OcClient = {}
OcClient.__index = OcClient

-- remote: { name, host, port, username, password }
function OcClient.new(remote)
    local self = setmetatable({}, OcClient)
    self.remote = remote
    return self
end

function OcClient:_headers(hasBody)
    local headers = { ["Accept"] = "application/json" }
    if hasBody then headers["Content-Type"] = "application/json" end
    local pass = self.remote.password
    if pass ~= nil and #pass > 0 then
        local user = self.remote.username
        if user == nil or #user == 0 then user = "opencode" end
        headers["Authorization"] = "Basic " .. Base64.encode(user .. ":" .. pass)
    end
    return headers
end

-- callback(data, err) — data is the JSON-decoded body (true for 204/empty)
function OcClient:req(method, path, body, callback)
    Http.request({
        host = self.remote.host,
        port = self.remote.port or 4096,
        ssl = false,
        method = method,
        path = path,
        headers = self:_headers(body ~= nil),
        body = body,
        callback = function(resp)
            if not resp.ok then
                callback(nil, resp.error or "network error")
                return
            end
            if resp.status == nil or resp.status >= 300 then
                callback(nil, "HTTP " .. tostring(resp.status)
                    .. " " .. (resp.body or ""):sub(1, 120))
                return
            end
            if resp.body == nil or #resp.body == 0 then
                callback(true, nil)
                return
            end
            local data = json.decode(resp.body)
            if data == nil then
                callback(true, nil) -- 2xx with non-JSON body
                return
            end
            callback(data, nil)
        end,
    })
end

function OcClient:health(cb)
    self:req("GET", "/global/health", nil, cb)
end

function OcClient:sessions(cb)
    self:req("GET", "/session", nil, cb)
end

function OcClient:createSession(cb)
    self:req("POST", "/session", "{}", cb)
end

function OcClient:deleteSession(id, cb)
    self:req("DELETE", "/session/" .. id, nil, cb)
end

-- Returns map: sessionID -> { type = "idle"|"busy"|"retry", ... }
function OcClient:status(cb)
    self:req("GET", "/session/status", nil, cb)
end

-- Returns array of { info = Message, parts = Part[] }
function OcClient:messages(id, limit, cb)
    local path = "/session/" .. id .. "/message"
    if limit ~= nil then path = path .. "?limit=" .. limit end
    self:req("GET", path, nil, cb)
end

function OcClient:promptAsync(id, text, agent, cb)
    local body = { parts = { { type = "text", text = text } } }
    if agent ~= nil and #agent > 0 then body.agent = agent end
    self:req("POST", "/session/" .. id .. "/prompt_async", json.encode(body), cb)
end

function OcClient:abort(id, cb)
    self:req("POST", "/session/" .. id .. "/abort", "{}", cb)
end

-- response: "once" | "always" | "reject"
function OcClient:respondPermission(sessionID, permissionID, response, cb)
    self:req("POST", "/session/" .. sessionID .. "/permissions/" .. permissionID,
        json.encode({ response = response }), cb)
end

function OcClient:todo(id, cb)
    self:req("GET", "/session/" .. id .. "/todo", nil, cb)
end

function OcClient:agents(cb)
    self:req("GET", "/agent", nil, cb)
end

function OcClient:commands(cb)
    self:req("GET", "/command", nil, cb)
end

function OcClient:runCommand(id, command, arguments, cb)
    self:req("POST", "/session/" .. id .. "/command",
        json.encode({ command = command, arguments = arguments or "" }), cb)
end
