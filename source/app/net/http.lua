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
--     requestTimeout = 20,   -- optional overall timeout, seconds
--     bodyComplete = function(body, headers) return false end, -- optional
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

local networkWaiters = {}
local networkDeadline = nil
local networkError = nil
local bodyPollers = {}

local function enableNetwork()
    if playdate.network ~= nil and playdate.network.setEnabled ~= nil then
        networkError = nil
        playdate.network.setEnabled(true, function(err)
            networkError = err
        end)
    end
end

local function finishNetworkWaiters(err)
    local waiters = networkWaiters
    networkWaiters = {}
    networkDeadline = nil
    networkError = nil
    for _, callback in ipairs(waiters) do callback(err) end
end

-- Request blanket HTTP access up front, from the playdate.update() context.
-- Later connections (LLM host, MCP hosts, ...) then never trigger the
-- permission dialog from inside a network/system callback, which the OS
-- does not allow.
local accessRequested = false
function Http.ensureAccess()
    if not accessRequested then
        accessRequested = true
        if playdate.network ~= nil and playdate.network.http ~= nil
            and playdate.network.http.requestAccess ~= nil then
            playdate.network.http.requestAccess(nil, nil, true, DEFAULT_REASON)
        end
        -- Wake the radio before the first request. Connecting to an AP can
        -- take up to ten seconds, while Playdate normally waits until a
        -- request arrives and powers Wi-Fi down again after an idle period.
        enableNetwork()
    end

    -- Pump connection waiters here so their HTTP requests start from the
    -- playdate.update() context, not from a mic/network system callback.
    if #networkWaiters > 0 then
        local status = playdate.network.getStatus()
        if status == playdate.network.kStatusConnected then
            finishNetworkWaiters(nil)
        elseif networkError ~= nil then
            finishNetworkWaiters("Wi-Fi: " .. tostring(networkError))
        elseif networkDeadline ~= nil
            and playdate.getCurrentTimeMilliseconds() >= networkDeadline then
            finishNetworkWaiters("Wi-Fi: not connected to an access point")
        end
    end

    -- On device, chunked HTTP responses do not always trigger the data
    -- callback for every chunk. Polling available bytes is non-blocking and
    -- lets callers recognize a complete body without waiting for a timeout.
    -- Iterate over a snapshot: completing a request can start the next one,
    -- which registers a new poller (mutating the table mid-iteration).
    local polls = {}
    for poll in pairs(bodyPollers) do polls[#polls + 1] = poll end
    for _, poll in ipairs(polls) do poll() end
end

-- Run callback(err) once the device is connected to its configured Wi-Fi
-- access point. The callback is dispatched by ensureAccess() from update().
function Http.whenConnected(callback)
    if playdate.network == nil or playdate.network.getStatus == nil then
        callback(nil)
        return
    end
    if playdate.network.getStatus() == playdate.network.kStatusConnected then
        callback(nil)
        return
    end
    networkWaiters[#networkWaiters + 1] = callback
    if networkDeadline == nil then
        networkDeadline = playdate.getCurrentTimeMilliseconds() + 15000
        enableNetwork()
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
    local timeoutTimer = nil
    local bodyPoller = nil
    local finish

    local function drain(checkComplete)
        local n = conn:getBytesAvailable()
        while n ~= nil and n > 0 do
            local data = conn:read(math.min(n, 32 * 1024))
            if data == nil or #data == 0 then break end
            chunks[#chunks + 1] = data
            n = conn:getBytesAvailable()
        end
        if checkComplete and not finished then
            local headers = conn:getResponseHeaders() or {}
            local body, done = Http.effectiveBody(table.concat(chunks), headers)
            if done == true then
                finish(nil)
            elseif opts.bodyComplete ~= nil and opts.bodyComplete(body, headers) then
                finish(nil)
            end
        end
    end

    finish = function(errmsg)
        if finished then return end
        finished = true
        if timeoutTimer ~= nil then
            timeoutTimer:remove()
            timeoutTimer = nil
        end
        if bodyPoller ~= nil then
            bodyPollers[bodyPoller] = nil
            bodyPoller = nil
        end
        drain(false)
        local status = conn:getResponseStatus()
        local headers = conn:getResponseHeaders() or {}
        local cerr = errmsg or conn:getError()
        conn:close()
        opts.callback({
            ok = (cerr == nil) and (status ~= nil),
            status = status,
            headers = headers,
            body = (Http.effectiveBody(table.concat(chunks), headers)),
            error = cerr,
        })
    end

    conn:setRequestCallback(function() drain(true) end)
    conn:setRequestCompleteCallback(function() finish(nil) end)
    conn:setConnectionClosedCallback(function() finish(nil) end)

    if opts.bodyComplete ~= nil then
        bodyPoller = function()
            if not finished then drain(true) end
        end
        bodyPollers[bodyPoller] = true
    end

    if opts.requestTimeout ~= nil then
        timeoutTimer = playdate.timer.performAfterDelay(opts.requestTimeout * 1000,
            function() finish("request timed out") end)
    end

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

-- Decode a raw Transfer-Encoding: chunked body. Returns decoded, done.
-- done is true once the terminating 0-size chunk has been seen.
function Http.dechunk(raw)
    local out = {}
    local pos = 1
    while true do
        local s, e, hex = raw:find("^(%x+)[^\r\n]*\r\n", pos)
        if s == nil then return table.concat(out), false end
        local size = tonumber(hex, 16)
        if size == nil then return table.concat(out), false end
        if size == 0 then return table.concat(out), true end
        local dataEnd = e + size
        if #raw < dataEnd then return table.concat(out), false end
        out[#out + 1] = raw:sub(e + 1, dataEnd)
        pos = dataEnd + 1
        if raw:sub(pos, pos + 1) == "\r\n" then
            pos = pos + 2
        elseif pos <= #raw then
            -- malformed / partial chunk boundary; wait for more data
            return table.concat(out), false
        else
            return table.concat(out), false
        end
    end
end

-- The device does not always dechunk HTTP bodies itself. If the response
-- says chunked and the raw bytes still look chunked, decode them here.
-- Returns body, done (done = nil when unknown).
function Http.effectiveBody(raw, headers)
    local te = Http.header(headers, "Transfer-Encoding") or ""
    if te:lower():find("chunked") and raw:find("^%x+[^\r\n]*\r\n") then
        local decoded, done = Http.dechunk(raw)
        -- Only trust the decoded form once the terminating chunk was seen;
        -- otherwise keep the raw bytes (avoids mangling misdetected bodies,
        -- e.g. SSE data that happens to start with hex characters).
        if done then return decoded, true end
        return raw, false
    end
    return raw, nil
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
