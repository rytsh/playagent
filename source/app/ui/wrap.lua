-- Word wrapping for a given font and max pixel width.

TextWrap = {}

-- Returns an array of lines. Handles \n and splits over-long words.
function TextWrap.wrap(font, text, maxWidth)
    local lines = {}
    text = tostring(text or "")
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
                        local cut = #word - 1
                        while cut > 1 and font:getTextWidth(word:sub(1, cut)) > maxWidth do
                            cut -= 1
                        end
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
