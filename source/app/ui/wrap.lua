-- Word wrapping for a given font and max pixel width.

TextWrap = {}

local function characterStart(text, pos)
    while pos > 1 do
        local byte = text:byte(pos)
        if byte < 0x80 or byte >= 0xC0 then break end
        pos -= 1
    end
    return pos
end

function TextWrap.truncate(font, text, maxWidth)
    text = Emoji.filter(text)
    if maxWidth <= 0 then return "" end
    if font:getTextWidth(text) <= maxWidth then return text end

    local suffix = "..."
    if font:getTextWidth(suffix) > maxWidth then return "" end
    local cut = #text
    while cut > 0 do
        cut = characterStart(text, cut) - 1
        local candidate = text:sub(1, cut) .. suffix
        if font:getTextWidth(candidate) <= maxWidth then return candidate end
    end
    return suffix
end

-- Returns an array of lines. Handles \n and splits over-long words.
function TextWrap.wrap(font, text, maxWidth)
    local lines = {}
    text = Emoji.filter(text)
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        if #paragraph == 0 then
            lines[#lines + 1] = ""
        else
            local line = ""
            for word in paragraph:gmatch("%S+") do
                local candidate = (#line > 0) and (line .. " " .. word) or word
                if font:getTextWidth(candidate) <= maxWidth then
                    line = candidate
                else
                    if #line > 0 then lines[#lines + 1] = line end
                    -- Split words that are wider than the whole line.
                    while font:getTextWidth(word) > maxWidth and #word > 1 do
                        local cut = characterStart(word, #word) - 1
                        while cut > 0 and font:getTextWidth(word:sub(1, cut)) > maxWidth do
                            cut = characterStart(word, cut) - 1
                        end
                        if cut == 0 then break end
                        lines[#lines + 1] = word:sub(1, cut)
                        word = word:sub(cut + 1)
                    end
                    line = word
                end
            end
            if #line > 0 then lines[#lines + 1] = line end
        end
    end
    if #lines == 0 then lines[1] = "" end
    return lines
end
