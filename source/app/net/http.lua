-- Small async HTTP helper built on playdate.network (Playdate OS 2.7+).
--
-- Http.request{
--     host = "api.example.com",
--     port = 443,            -- optional (443 for ssl, 80 otherwise)
--     ssl = true,            -- default true
--     method = "POST",       -- "GET" or "POST"
--     path = "/v1/things",
--     headers = { ... },     -- optional table
--     body = "...",          -- optional string
--     reason = "...",        -- shown in the system permission dialog
--     connectTimeout = 15,   -- seconds
--     callback = function(resp) end,
-- }
--
-- resp: { ok, status, headers, body, error }
--
-- NOTE: creating a connection may show the system permission dialog, which
-- yields; therefore Http.request must be called from the playdate.update()
-- context (not from a system/input callback).

Http = {}

local DEFAULT_REASON <const> = "PlayAgent needs network access to talk to your AI services."

-- Request blanket HTTP access up front, from the playdate.update() context.
-- Later connections (LLM host, MCP hosts, ...) then never trigger the
-- permission dialog from inside a network/system callback, which the OS
-- does not allow.
local accessRequested = false
function Http.ensureAccess()
    if accessRequested then return end
    accessRequested = true
    if playdate.network ~= nil and playdate.network.http ~= nil
        and playdate.network.http.requestAccess ~= nil then
        playdate.network.http.requestAccess(nil, nil, true, DEFAULT_REASON)
    end
end

-- Streaming variant (for SSE): pass stream = true plus
--   onData(chunk)   -- called as body data arrives
--   onClose(err)    -- called once when the connection ends
-- Returns the connection object (close() it to cancel), or nil on failure.
function Http.request(opts)
    local conn
    local port = opts.port
    if opts.ssl == false then
        conn = playdate.network.http.new(opts.host, port or 80, false, opts.reason or DEFAULT_REASON)
    else
        conn = playdate.network.https.new(opts.host, port or 443, opts.reason or DEFAULT_REASON)
    end
    if conn == nil then
        local err = "could not open connection to " .. tostring(opts.host)
        if opts.stream then
            if opts.onClose then opts.onClose(err) end
        else
            opts.callback({ ok = false, error = err })
        end
        return nil
    end

    if opts.stream then
        return Http._streamRequest(conn, opts)
    end

    conn:setConnectTimeout(opts.connectTimeout or 15)
    conn:setReadTimeout(2)
    conn:setReadBufferSize(64 * 1024)
    conn:setKeepAlive(false)

    local chunks = {}
    local finished = false

    local function drain()
        local n = conn:getBytesAvailable()
        while n ~= nil and n > 0 do
            local data = conn:read(math.min(n, 32 * 1024))
            if data == nil or #data == 0 then break end
            chunks[#chunks + 1] = data
            n = conn:getBytesAvailable()
        end
    end

    local function finish(errmsg)
        if finished then return end
        finished = true
        drain()
        local status = conn:getResponseStatus()
        local headers = conn:getResponseHeaders()
        local cerr = errmsg or conn:getError()
        conn:close()
        opts.callback({
            ok = (cerr == nil) and (status ~= nil),
            status = status,
            headers = headers or {},
            body = table.concat(chunks),
            error = cerr,
        })
    end

    conn:setRequestCallback(drain)
    conn:setRequestCompleteCallback(function() finish(nil) end)
    conn:setConnectionClosedCallback(function() finish(nil) end)

    local ok, qerr
    if (opts.method or "GET") == "GET" then
        ok, qerr = conn:get(opts.path, opts.headers)
    else
        ok, qerr = conn:post(opts.path, opts.headers, opts.body or "")
    end
    if not ok then
        finish(qerr or "failed to queue request")
    end
    return conn
end

-- Long-lived streaming request (SSE). Delivers chunks via opts.onData and
-- signals termination via opts.onClose(err).
function Http._streamRequest(conn, opts)
    conn:setConnectTimeout(opts.connectTimeout or 15)
    conn:setReadTimeout(1)
    conn:setReadBufferSize(32 * 1024)

    local closed = false

    local function drain()
        local n = conn:getBytesAvailable()
        while n ~= nil and n > 0 do
            local data = conn:read(math.min(n, 16 * 1024))
            if data == nil or #data == 0 then break end
            if opts.onData then opts.onData(data) end
            n = conn:getBytesAvailable()
        end
    end

    local function finish()
        if closed then return end
        closed = true
        drain()
        local err = conn:getError()
        local status = conn:getResponseStatus()
        if err == nil and status ~= nil and status >= 300 then
            err = "HTTP " .. tostring(status)
        end
        conn:close()
        if opts.onClose then opts.onClose(err) end
    end

    conn:setRequestCallback(drain)
    conn:setRequestCompleteCallback(finish)
    conn:setConnectionClosedCallback(finish)

    local ok, qerr
    if (opts.method or "GET") == "GET" then
        ok, qerr = conn:get(opts.path, opts.headers)
    else
        ok, qerr = conn:post(opts.path, opts.headers, opts.body or "")
    end
    if not ok then
        finish()
        return nil
    end
    return conn
end

-- Case-insensitive response header lookup.
function Http.header(headers, name)
    if headers == nil then return nil end
    local lname = string.lower(name)
    for k, v in pairs(headers) do
        if string.lower(k) == lname then return v end
    end
    return nil
end
