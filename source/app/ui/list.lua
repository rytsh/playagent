-- Simple scrollable list menu driven by d-pad and crank.

local gfx <const> = playdate.graphics

ListView = {}
ListView.__index = ListView

-- items: array of { text = "...", detail = "..." (optional) }
function ListView.new(items)
    local self = setmetatable({}, ListView)
    self.items = items or {}
    self.selected = 1
    self.rowHeight = 24
    self.scroll = 0
    return self
end

function ListView:setItems(items)
    self.items = items or {}
    if self.selected > #self.items then self.selected = math.max(1, #self.items) end
end

function ListView:current()
    return self.items[self.selected], self.selected
end

-- Call every frame; moves selection. Returns true if A was just pressed.
function ListView:handleInput()
    local moved = 0
    if playdate.buttonJustPressed(playdate.kButtonDown) then moved = 1 end
    if playdate.buttonJustPressed(playdate.kButtonUp) then moved = -1 end
    local ticks = playdate.getCrankTicks(6)
    if ticks ~= 0 then moved = ticks end
    if moved ~= 0 and #self.items > 0 then
        self.selected = math.max(1, math.min(#self.items, self.selected + moved))
    end
    return playdate.buttonJustPressed(playdate.kButtonA)
end

function ListView:draw(x, y, w, h)
    local font = AppFont
    local visible = math.floor(h / self.rowHeight)
    if self.selected - self.scroll > visible then
        self.scroll = self.selected - visible
    elseif self.selected - 1 < self.scroll then
        self.scroll = self.selected - 1
    end
    gfx.setColor(gfx.kColorBlack)
    for row = 1, visible do
        local idx = row + self.scroll
        local item = self.items[idx]
        if item == nil then break end
        local ry = y + (row - 1) * self.rowHeight
        if idx == self.selected then
            gfx.fillRoundRect(x, ry, w, self.rowHeight - 2, 4)
            gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
        end
        local label = tostring(item.text)
        font:drawText(label, x + 8, ry + 4)
        if item.detail ~= nil then
            local detailWidth = w - font:getTextWidth(label) - 28
            local detail = TextWrap.truncate(font, tostring(item.detail), detailWidth)
            local dw = font:getTextWidth(detail)
            font:drawText(detail, x + w - dw - 8, ry + 4)
        end
        gfx.setImageDrawMode(gfx.kDrawModeCopy)
    end
    -- scrollbar
    if #self.items > visible then
        local barH = math.max(12, h * visible / #self.items)
        local barY = y + (h - barH) * self.scroll / (#self.items - visible)
        gfx.fillRect(x + w + 3, barY, 3, barH)
    end
end
