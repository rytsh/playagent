-- Scrollable chat transcript. Crank or up/down scrolls.

local gfx <const> = playdate.graphics

ChatView = {}
ChatView.__index = ChatView

local SCREEN_W <const> = 400
local SCREEN_H <const> = 240
local MARGIN <const> = 6
local TEXT_W <const> = SCREEN_W - MARGIN * 2 - 16

function ChatView.new(session)
    local self = setmetatable({}, ChatView)
    self.session = session
    self.scroll = 0        -- pixels from top
    self.autoFollow = true
    self.cache = {}        -- messageIndex -> { lines, height, role }
    return self
end

local function displayable(msg)
    if msg.role == "system" then return false end
    if msg.role == "tool" then return false end
    if msg.content == nil or msg.content == "" then
        -- assistant message that only carried tool calls
        return msg.role == "assistant" and msg.tool_calls ~= nil
    end
    return true
end

function ChatView:_entryFor(i, font, lineH)
    local cached = self.cache[i]
    if cached ~= nil then return cached end
    local msg = self.session.messages[i]
    local text = msg.content
    if (text == nil or text == "") and msg.tool_calls ~= nil then
        local names = {}
        for _, c in ipairs(msg.tool_calls) do
            names[#names + 1] = (c["function"] or {}).name or "?"
        end
        text = "[using tools: " .. table.concat(names, ", ") .. "]"
    end
    local prefix = (msg.role == "user") and "YOU" or "AGENT"
    local lines = TextWrap.wrap(font, text, TEXT_W)
    local entry = {
        prefix = prefix,
        role = msg.role,
        lines = lines,
        height = #lines * lineH + 18,
    }
    self.cache[i] = entry
    return entry
end

function ChatView:invalidate()
    self.cache = {}
end

function ChatView:contentHeight(font, lineH)
    local h = MARGIN
    for i, msg in ipairs(self.session.messages) do
        if displayable(msg) then
            h += self:_entryFor(i, font, lineH).height + 6
        end
    end
    return h
end

function ChatView:scrollToBottom()
    self.autoFollow = true
end

-- statusText: optional line rendered at the bottom (e.g. "Thinking...")
-- allowInput: false when another UI is handling controls over the transcript.
function ChatView:update(statusText, allowInput)
    local font = AppFont
    local lineH = font:getHeight() + 2
    local statusH = (statusText ~= nil) and 20 or 0
    local viewH = SCREEN_H - statusH

    local total = self:contentHeight(font, lineH)
    local maxScroll = math.max(0, total - viewH)

    if allowInput ~= false then
        local delta = 0
        if playdate.buttonIsPressed(playdate.kButtonDown) then delta += 5 end
        if playdate.buttonIsPressed(playdate.kButtonUp) then delta -= 5 end
        local crank = playdate.getCrankChange()
        if crank ~= 0 then delta += crank * 0.7 end
        if delta ~= 0 then
            self.autoFollow = false
            self.scroll = math.max(0, math.min(maxScroll, self.scroll + delta))
            if self.scroll >= maxScroll - 2 then self.autoFollow = true end
        end
    end
    if self.autoFollow then self.scroll = maxScroll end

    local y = MARGIN - self.scroll
    gfx.setColor(gfx.kColorBlack)
    for i, msg in ipairs(self.session.messages) do
        if displayable(msg) then
            local entry = self:_entryFor(i, font, lineH)
            if y + entry.height > 0 and y < viewH then
                AppFontBold:drawText(entry.prefix, MARGIN + 2, y)
                local ty = y + 16
                for _, line in ipairs(entry.lines) do
                    font:drawText(line, MARGIN + 14, ty)
                    ty += lineH
                end
                if entry.role == "user" then
                    gfx.fillRect(MARGIN + 6, y + 16, 2, entry.height - 18)
                end
            end
            y += entry.height + 6
        end
    end

    if statusText ~= nil then
        gfx.setColor(gfx.kColorWhite)
        gfx.fillRect(0, SCREEN_H - statusH, SCREEN_W, statusH)
        gfx.setColor(gfx.kColorBlack)
        gfx.drawLine(0, SCREEN_H - statusH, SCREEN_W, SCREEN_H - statusH)
        font:drawText(statusText, MARGIN, SCREEN_H - statusH + 3)
    end
end
