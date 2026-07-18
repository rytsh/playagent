-- Buddy mode scenes: pick a pet, then hang out with it.
-- The buddy is drawn big on the left, its replies appear in a speech
-- bubble; input reuses the chat mechanisms (keyboard, mic, live dictation).

local gfx <const> = playdate.graphics

------------------------------------------------------------------------
-- BuddyPickScene
------------------------------------------------------------------------

BuddyPickScene = {}
BuddyPickScene.__index = BuddyPickScene

function BuddyPickScene.new()
    local self = setmetatable({}, BuddyPickScene)
    local items = {}
    for _, b in ipairs(Buddies.list) do
        items[#items + 1] = { text = b.name, detail = b.kind, id = b.id }
    end
    self.list = ListView.new(items)
    return self
end

-- Ask for a pet name (pre-filled with the default), then adopt.
function BuddyPickScene:adopt(buddy)
    TextInput.show("Name your " .. buddy.kind .. ":", buddy.name,
        function(text)
            if text == nil then return end -- cancelled
            local name = text:match("^%s*(.-)%s*$") -- trim
            if #name == 0 then name = buddy.name end
            local session = Sessions.create("buddy:" .. buddy.id, name)
            Scenes.pop()
            Scenes.push(BuddyScene.new(session))
        end)
end

function BuddyPickScene:update()
    if TextInput.active then
        TextInput.draw()
        return
    end

    AppFontBold:drawText("Pick a buddy", 8, 6)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawLine(0, 26, 400, 26)

    -- preview of the selected buddy
    local item = self.list:current()
    if item ~= nil then
        local img = Buddies.images(item.id).idle1
        if img ~= nil then img:draw(252, 60) end
    end

    if self.list:handleInput() then
        if item ~= nil then
            self:adopt(Buddies.byId(item.id))
        end
        return
    end
    if playdate.buttonJustPressed(playdate.kButtonB) then
        Scenes.pop()
        return
    end
    self.list:draw(10, 36, 220, 160)
    AppFont:drawText("A: adopt & name   B: back", 8, 222)
end

------------------------------------------------------------------------
-- BuddyScene
------------------------------------------------------------------------

local BUBBLE_X <const> = 148
local BUBBLE_W <const> = 244
local BUBBLE_Y <const> = 8
local TEXT_PAD <const> = 10
local LINE_H <const> = 18
local MAX_LINES <const> = 10

BuddyScene = {}
BuddyScene.__index = BuddyScene

function BuddyScene.new(session)
    local self = setmetatable({}, BuddyScene)
    self.session = session
    self.buddy = Buddies.fromPersonaId(session.personaId)
        or Buddies.list[1]
    self.name = session.buddyName or self.buddy.name
    self.images = Buddies.images(self.buddy.id)
    self.modal = nil
    self.status = nil
    self.mcpConnected = false
    self.scroll = 0
    self.talkUntil = 0
    self.happyUntil = 0
    self.blinkUntil = 0
    self.nextBlink = playdate.getCurrentTimeMilliseconds()
        + math.random(1500, 4000)

    self.agent = Agent.new(session, {
        onStatus = function(text) self.status = text end,
        onAskUser = function(question, options, cb)
            self.modal = ChoiceDialog.new(question, options, function(_, label)
                cb(label or "(no answer)")
            end, false)
        end,
        onConfirm = function(question, cb)
            self.modal = ChoiceDialog.new(question, { "Allow", "Reject" },
                function(idx)
                    self.modal = nil
                    cb(idx == 1)
                end, false)
        end,
        onDone = function(err)
            self.status = nil
            if err ~= nil then
                self:flash("Error: " .. tostring(err))
                return
            end
            local text = self:bubbleText()
            if text ~= nil then
                local ms = math.max(900, math.min(4500, #text * 30))
                self.talkUntil = playdate.getCurrentTimeMilliseconds() + ms
            end
            self.scroll = 0
        end,
    })
    return self
end

function BuddyScene:flash(text)
    self.flashText = text
    self.flashUntil = playdate.getCurrentTimeMilliseconds() + 5000
end

function BuddyScene:persist()
    Sessions.save(self.session)
end

function BuddyScene:enter()
    if self.mcpConnected then return end
    local function ready()
        self.mcpConnected = true
        -- Fresh session: let the buddy greet the user.
        if #self.session.messages == 1 and not self.agent.busy then
            Sfx.preset(self.buddy.sound)
            self.agent:run()
        end
    end
    local servers = Config.enabledMcpServers()
    if #servers > 0 then
        self.status = "Connecting MCP..."
        Mcp.connectAll(function(name, err)
            if err ~= nil then self:flash("MCP " .. name .. ": " .. err) end
        end, function()
            self.status = nil
            ready()
        end)
    else
        ready()
    end
end

-- Last assistant message with actual text, or nil.
function BuddyScene:bubbleText()
    for i = #self.session.messages, 1, -1 do
        local m = self.session.messages[i]
        if m.role == "assistant" and type(m.content) == "string"
            and #m.content > 0 then
            return m.content
        end
    end
    return nil
end

function BuddyScene:currentFrame()
    local now = playdate.getCurrentTimeMilliseconds()
    if now < self.happyUntil then return "happy" end
    if now < self.talkUntil then
        return (math.floor(now / 160) % 2 == 0) and "talk1" or "talk2"
    end
    if now < self.blinkUntil then return "blink" end
    if now >= self.nextBlink then
        self.blinkUntil = now + 180
        self.nextBlink = now + math.random(1800, 5000)
        return "blink"
    end
    return (math.floor(now / 700) % 2 == 0) and "idle1" or "idle2"
end

function BuddyScene:send(text)
    self.scroll = 0
    self.agent:sendUser(text)
end

function BuddyScene:openActionMenu()
    local options = {
        "Type message", "Speak (mic)", "Dictate (live)",
        "Pet " .. self.name, "History",
    }
    self.modal = ChoiceDialog.new("What do you want to do?", options,
        function(_, label)
            self.modal = nil
            if label == "Type message" then
                TextInput.show("Say to " .. self.name .. ":", "",
                    function(text)
                        if text ~= nil and #text > 0 then self:send(text) end
                    end)
            elseif label == "Speak (mic)" then
                self.modal = MicRecorder.new(function(wavPath, err)
                    self.modal = nil
                    if err ~= nil then
                        self:flash("Mic: " .. err)
                    elseif wavPath ~= nil then
                        self.status = "Transcribing..."
                        STT.transcribe(wavPath, function(text, terr)
                            self.status = nil
                            if terr ~= nil then
                                self:flash("STT: " .. terr)
                            elseif text ~= nil and #text > 0 then
                                self:send(text)
                            end
                        end)
                    end
                end)
            elseif label == "Dictate (live)" then
                self.modal = LiveMic.new(function(text, err)
                    self.modal = nil
                    if err ~= nil then
                        self:flash("Mic: " .. err)
                    elseif text ~= nil and #text > 0 then
                        self:send(text)
                    end
                end)
            elseif label == "Pet " .. self.name then
                self.happyUntil = playdate.getCurrentTimeMilliseconds() + 2400
                Sfx.preset(self.buddy.sound)
                self:send("*The user pets you.*")
            elseif label == "History" then
                Scenes.push(ChatScene.new(self.session))
            end
        end, true)
end

function BuddyScene:drawBubble(text, talking)
    local font = AppFont
    local maxW = BUBBLE_W - 2 * TEXT_PAD
    local lines = TextWrap.wrap(font, text, maxW)

    local visible = math.min(#lines, MAX_LINES)
    local maxScroll = math.max(0, #lines - MAX_LINES)
    if self.scroll > maxScroll then self.scroll = maxScroll end
    local h = visible * LINE_H + 2 * TEXT_PAD - 4

    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(BUBBLE_X, BUBBLE_Y, BUBBLE_W, h, 8)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRoundRect(BUBBLE_X, BUBBLE_Y, BUBBLE_W, h, 8)

    -- tail pointing at the buddy (only when it has said something)
    if talking then
        local ty = math.min(BUBBLE_Y + h - 14, 96)
        gfx.setColor(gfx.kColorWhite)
        gfx.fillTriangle(BUBBLE_X + 1, ty, BUBBLE_X + 1, ty + 16,
            BUBBLE_X - 16, ty + 22)
        gfx.setColor(gfx.kColorBlack)
        gfx.drawLine(BUBBLE_X + 1, ty, BUBBLE_X - 16, ty + 22)
        gfx.drawLine(BUBBLE_X - 16, ty + 22, BUBBLE_X + 1, ty + 16)
    end

    for i = 1, visible do
        local line = lines[i + self.scroll]
        if line == nil then break end
        font:drawText(line, BUBBLE_X + TEXT_PAD,
            BUBBLE_Y + TEXT_PAD - 2 + (i - 1) * LINE_H)
    end

    if maxScroll > 0 then
        local hint = string.format("%d/%d", self.scroll + MAX_LINES, #lines)
        font:drawText(hint, BUBBLE_X + BUBBLE_W - font:getTextWidth(hint) - 6,
            BUBBLE_Y + h + 2)
    end
    return maxScroll
end

function BuddyScene:update()
    if TextInput.active then
        TextInput.draw()
        return
    end

    if self.modal ~= nil then
        local m = self.modal
        if not m:update() and self.modal == m then
            self.modal = nil
        end
        return
    end

    -- buddy sprite + name
    local img = self.images[self:currentFrame()]
    if img ~= nil then img:draw(12, 84) end
    local name = self.name
    local nw = AppFontBold:getTextWidth(name)
    AppFontBold:drawText(name, 12 + (128 - nw) / 2, 62)

    -- speech bubble
    local maxScroll = 0
    local text = self:bubbleText()
    if self.agent.busy then
        local dots = math.floor(playdate.getCurrentTimeMilliseconds()
            / 400) % 3 + 1
        self:drawBubble(string.rep(".", dots), false)
    elseif text ~= nil then
        maxScroll = self:drawBubble(text, true)
    else
        self:drawBubble("...", false)
    end

    -- crank scrolls long bubble text
    if maxScroll > 0 then
        local ticks = playdate.getCrankTicks(4)
        if ticks ~= 0 then
            self.scroll = math.max(0,
                math.min(maxScroll, self.scroll + ticks))
        end
    end

    -- status / hint line
    local statusLine = self.status
    if statusLine == nil and self.flashText ~= nil then
        if playdate.getCurrentTimeMilliseconds() < self.flashUntil then
            statusLine = self.flashText
        else
            self.flashText = nil
        end
    end
    if self.agent.busy and statusLine ~= nil then
        statusLine = statusLine .. "   B: cancel"
    end
    if statusLine == nil then
        statusLine = "A: talk    B: back"
        if maxScroll > 0 then statusLine = statusLine .. "    crank: scroll" end
    end
    AppFont:drawText(statusLine, 8, 222)

    -- input
    if self.agent.busy then
        if playdate.buttonJustPressed(playdate.kButtonB) then
            self.agent:cancel()
            self:flash("Cancelled.")
        end
    elseif playdate.buttonJustPressed(playdate.kButtonA) then
        self:openActionMenu()
    elseif playdate.buttonJustPressed(playdate.kButtonB) then
        Sessions.save(self.session)
        Scenes.pop()
    end
end
