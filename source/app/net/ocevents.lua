-- SSE consumer for the opencode server's /event stream, with automatic
-- reconnection. Delivers decoded bus events to a handler.
--
-- Usage:
--   local ev = OcEvents.new(client, function(type, properties) ... end)
--   ev:start()
--   ev:update()   -- call every frame (handles reconnect timing)
--   ev:stop()
--   ev.connected  -- true while the stream is live

OcEvents = {}
OcEvents.__index = OcEvents

local RECONNECT_MS <const> = 5000

function OcEvents.new(client, onEvent)
    local self = setmetatable({}, OcEvents)
    self.client = client
    self.onEvent = onEvent
    self.connected = false
    self.conn = nil
    self.buffer = ""
    self.reconnectAt = nil
    self.stopped = true
    return self
end

function OcEvents:_dispatchBlock(block)
    -- An SSE block: one or more lines; we care about "data:" lines.
    local datas = {}
    for line in block:gmatch("[^\r\n]+") do
        local d = line:match("^data:%s?(.*)$")
        if d ~= nil then datas[#datas + 1] = d end
    end
    if #datas == 0 then return end
    local obj = json.decode(table.concat(datas, "\n"))
    if obj ~= nil and obj.type ~= nil then
        self.onEvent(obj.type, obj.properties or {})
    end
end

function OcEvents:_feed(chunk)
    self.buffer = self.buffer .. chunk
    while true do
        local s, e = self.buffer:find("\r?\n\r?\n")
        if s == nil then break end
        local block = self.buffer:sub(1, s - 1)
        self.buffer = self.buffer:sub(e + 1)
        if #block > 0 then
            self:_dispatchBlock(block)
        end
    end
    -- safety: don't let a mis-framed stream grow unbounded
    if #self.buffer > 64 * 1024 then
        self.buffer = ""
    end
end

function OcEvents:start()
    self.stopped = false
    self.buffer = ""
    self.conn = Http.request({
        host = self.client.remote.host,
        port = self.client.remote.port or 4096,
        ssl = false,
        method = "GET",
        path = "/event",
        headers = (function()
            local h = self.client:_headers(false)
            h["Accept"] = "text/event-stream"
            return h
        end)(),
        stream = true,
        onData = function(chunk)
            self.connected = true
            self:_feed(chunk)
        end,
        onClose = function(err)
            self.connected = false
            self.conn = nil
            if not self.stopped then
                self.reconnectAt = playdate.getCurrentTimeMilliseconds() + RECONNECT_MS
            end
        end,
    })
    if self.conn == nil and not self.stopped then
        self.reconnectAt = playdate.getCurrentTimeMilliseconds() + RECONNECT_MS
    end
end

function OcEvents:update()
    if self.stopped or self.conn ~= nil then return end
    if self.reconnectAt ~= nil
        and playdate.getCurrentTimeMilliseconds() >= self.reconnectAt then
        self.reconnectAt = nil
        self:start()
    end
end

function OcEvents:stop()
    self.stopped = true
    self.connected = false
    if self.conn ~= nil then
        self.conn:close()
        self.conn = nil
    end
end
