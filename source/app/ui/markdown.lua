-- Minimal markdown layout for the 1-bit chat view.
--
-- Supported subset:
--   ## headers          -> bold line
--   - / * / 1. lists    -> hanging indent, marker kept
--   ``` code fences     -> indented block with a left rule
--   **whole-line bold** -> bold line
--   ---                 -> horizontal rule
-- Inline markers (**bold**, `code`, [text](url)) are stripped to clean text;
-- everything else renders as a plain paragraph.

Markdown = {}

-- Strip inline markers, keep the readable text.
local function inlineStrip(s)
    s = s:gsub("%[([^%]]-)%]%(([^%)]-)%)", "%1") -- [text](url) -> text
    s = s:gsub("%*%*(.-)%*%*", "%1")             -- **bold**
    s = s:gsub("__(.-)__", "%1")                 -- __bold__
    s = s:gsub("`([^`]*)`", "%1")                -- `code`
    return s
end

-- Parse text into blocks: { style = "p"|"b"|"h"|"bullet"|"code"|"rule",
--                           text, prefix (bullets only) }
function Markdown.blocks(text)
    local blocks = {}
    local inCode = false
    for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        if line:match("^%s*```") then
            inCode = not inCode
        elseif inCode then
            blocks[#blocks + 1] = { style = "code", text = line }
        elseif line:match("^%-%-%-+%s*$") then
            blocks[#blocks + 1] = { style = "rule", text = "" }
        else
            local header = line:match("^#+%s+(.*)$")
            local bulletText = line:match("^%s*[-*+]%s+(.*)$")
            local numPrefix, numText = line:match("^%s*(%d+[.)])%s+(.*)$")
            local boldLine = line:match("^%*%*(.+)%*%*%s*$")
            if header ~= nil then
                blocks[#blocks + 1] = { style = "h", text = inlineStrip(header) }
            elseif bulletText ~= nil then
                blocks[#blocks + 1] = {
                    style = "bullet", prefix = "- ",
                    text = inlineStrip(bulletText),
                }
            elseif numText ~= nil then
                blocks[#blocks + 1] = {
                    style = "bullet", prefix = numPrefix .. " ",
                    text = inlineStrip(numText),
                }
            elseif boldLine ~= nil then
                blocks[#blocks + 1] = { style = "b", text = inlineStrip(boldLine) }
            else
                blocks[#blocks + 1] = { style = "p", text = inlineStrip(line) }
            end
        end
    end
    return blocks
end

-- Wrap blocks into drawable lines:
--   { text, bold = bool, indent = px, code = bool, rule = bool }
function Markdown.layout(text, font, boldFont, maxWidth)
    local out = {}
    for _, b in ipairs(Markdown.blocks(text)) do
        if b.style == "rule" then
            out[#out + 1] = { text = "", rule = true, indent = 0 }
        elseif b.style == "h" or b.style == "b" then
            for _, line in ipairs(TextWrap.wrap(boldFont, b.text, maxWidth)) do
                out[#out + 1] = { text = line, bold = true, indent = 0 }
            end
        elseif b.style == "code" then
            for _, line in ipairs(TextWrap.wrap(font, b.text, maxWidth - 10)) do
                out[#out + 1] = { text = line, code = true, indent = 10 }
            end
        elseif b.style == "bullet" then
            local pw = font:getTextWidth(b.prefix)
            for i, line in ipairs(TextWrap.wrap(font, b.text, maxWidth - pw)) do
                if i == 1 then
                    out[#out + 1] = { text = b.prefix .. line, indent = 0 }
                else
                    out[#out + 1] = { text = line, indent = pw }
                end
            end
        else
            for _, line in ipairs(TextWrap.wrap(font, b.text, maxWidth)) do
                out[#out + 1] = { text = line, indent = 0 }
            end
        end
    end
    if #out == 0 then out[1] = { text = "", indent = 0 } end
    return out
end
