-- Wrapper around the system keyboard for prompt-style text entry.

local gfx <const> = playdate.graphics

TextInput = {}
TextInput.active = false

-- callback(text or nil) — nil when cancelled
function TextInput.show(prompt, initial, callback)
    TextInput.active = true
    TextInput.prompt = prompt or ""
    TextInput.callback = callback
    playdate.keyboard.text = initial or ""

    playdate.keyboard.keyboardWillHideCallback = function(ok)
        TextInput.result = ok and playdate.keyboard.text or nil
    end
    playdate.keyboard.keyboardDidHideCallback = function()
        TextInput.active = false
        TextInput.finished = true
    end
    playdate.keyboard.show(initial or "")
end

-- Deliver the callback from the playdate.update() context (system callbacks
-- must not start network requests / permission dialogs). Called by Scenes.
function TextInput.poll()
    if TextInput.finished then
        TextInput.finished = false
        local cb = TextInput.callback
        TextInput.callback = nil
        if cb ~= nil then cb(TextInput.result) end
    end
end

-- Draw prompt + current text on the visible part of the screen while the
-- keyboard is up. Call from the scene's update.
function TextInput.draw()
    if not TextInput.active then return end
    local font = AppFont
    local w = math.max(60, playdate.keyboard.left() - 16)
    font:drawText(TextInput.prompt, 8, 8)
    local lines = TextWrap.wrap(font, playdate.keyboard.text .. "_", w)
    local lineH = font:getHeight() + 2
    for i, line in ipairs(lines) do
        if 32 + i * lineH > 232 then break end
        font:drawText(line, 8, 24 + (i - 1) * lineH)
    end
end
