-- Modal choice dialog: a question plus 2-5 options.
-- This is how the LLM "asks" the user (ask_user tool).

local gfx <const> = playdate.graphics

ChoiceDialog = {}
ChoiceDialog.__index = ChoiceDialog

-- callback(index, label) — index is nil if dismissable and dismissed with B
function ChoiceDialog.new(question, options, callback, dismissable)
    local self = setmetatable({}, ChoiceDialog)
    self.question = question
    self.callback = callback
    self.dismissable = dismissable == true
    local items = {}
    for _, opt in ipairs(options) do
        items[#items + 1] = { text = tostring(opt) }
    end
    self.list = ListView.new(items)
    self.list.rowHeight = 22
    return self
end

-- Returns true while the dialog stays open.
function ChoiceDialog:update()
    local margin <const> = 14
    local w <const> = 400 - margin * 2
    local font = AppFont

    local qlines = TextWrap.wrap(AppFontBold, self.question, w - 24)
    local lineH = AppFontBold:getHeight() + 2
    local qh = #qlines * lineH
    local listH = math.min(#self.list.items, 5) * self.list.rowHeight
    local boxH = qh + listH + 30
    local boxY = math.max(6, math.floor((240 - boxH) / 2))

    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(margin - 4, boxY - 4, w + 8, boxH + 8, 6)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRoundRect(margin - 4, boxY - 4, w + 8, boxH + 8, 6)

    for i, line in ipairs(qlines) do
        AppFontBold:drawText(line, margin + 8, boxY + 6 + (i - 1) * lineH)
    end

    local selected = self.list:handleInput()
    self.list:draw(margin + 4, boxY + qh + 18, w - 12, listH + 4)

    if selected then
        local item, idx = self.list:current()
        if item ~= nil then
            self.callback(idx, item.text)
            return false
        end
    end
    if self.dismissable and playdate.buttonJustPressed(playdate.kButtonB) then
        self.callback(nil, nil)
        return false
    end
    return true
end
