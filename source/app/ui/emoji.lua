-- Emoji fallback for the 1-bit bitmap font.
--
-- The font covers Latin + a few symbols only; emoji codepoints would render
-- as nothing. Instead of invisible characters, common emoji are translated
-- to readable ASCII ("+1", ":)", "<3", ...) and everything else emoji-like
-- (incl. ZWJ sequences, variation selectors, skin tones, flags) is removed.
--
-- TextWrap runs every displayed string through Emoji.filter, so this covers
-- the chat view, lists, dialogs and the opencode remote transcript alike.

Emoji = {}

local CHECK <const> = "\u{2713}" -- in the font
local CROSS <const> = "\u{2717}" -- in the font

local MAP <const> = {
    -- punctuation-ish
    [0x203C] = "!!", [0x2049] = "!?",
    -- checks & crosses
    [0x2705] = CHECK, [0x2714] = CHECK, [0x2611] = CHECK,
    [0x274C] = CROSS, [0x274E] = CROSS, [0x2716] = "x",
    -- stars & sparkles
    [0x2B50] = "*", [0x2728] = "*", [0x2605] = "*", [0x2606] = "*",
    [0x1F31F] = "*",
    -- hearts
    [0x2764] = "<3", [0x2665] = "<3", [0x1F494] = "</3",
    [0x1F5A4] = "<3", [0x1F90D] = "<3", [0x1F90E] = "<3", [0x1F9E1] = "<3",
    -- smileys
    [0x1F600] = ":D", [0x1F601] = ":D", [0x1F602] = ":'D", [0x1F603] = ":D",
    [0x1F604] = ":D", [0x1F605] = ":D", [0x1F606] = "XD", [0x1F607] = "O:)",
    [0x1F609] = ";)", [0x1F60A] = ":)", [0x1F60B] = ":P", [0x1F60D] = "<3",
    [0x1F60E] = "B)", [0x1F610] = ":|", [0x1F611] = ":|", [0x1F614] = ":(",
    [0x1F615] = ":/", [0x1F617] = ":*", [0x1F618] = ";*", [0x1F61A] = ":*",
    [0x1F61B] = ":P", [0x1F61C] = ";P", [0x1F61D] = "XP", [0x1F61E] = ":(",
    [0x1F620] = ">:(", [0x1F621] = ">:(", [0x1F622] = ":'(", [0x1F625] = ":'(",
    [0x1F628] = "D:", [0x1F62D] = ":'(", [0x1F62E] = ":O", [0x1F631] = "D:",
    [0x1F632] = ":O", [0x1F642] = ":)", [0x1F643] = "(:", [0x1F914] = "(hmm)",
    -- hands
    [0x1F44D] = "+1", [0x1F44E] = "-1", [0x1F44B] = "o/", [0x1F44C] = "(ok)",
    [0x1F44F] = "(clap)", [0x1F64F] = "(pray)",
    -- objects the model loves
    [0x1F389] = "\\o/", [0x1F38A] = "\\o/", [0x1F973] = "\\o/",
    [0x1F525] = "(fire)", [0x1F4A1] = "(idea)", [0x1F680] = "(rocket)",
    [0x1F916] = "(robot)", [0x26A0] = "(!)", [0x2757] = "!", [0x2753] = "?",
}

-- Replacement string for a codepoint, or nil to keep it as-is.
local function translate(cp)
    local m = MAP[cp]
    if m ~= nil then return m end
    if cp >= 0x1F495 and cp <= 0x1F49C then return "<3" end
    if cp == 0x200D or cp == 0x20E3 then return "" end     -- ZWJ, keycap
    if cp >= 0xFE00 and cp <= 0xFE0F then return "" end    -- variation sel.
    if cp >= 0x1F000 and cp <= 0x1FFFF then return "" end  -- emoji planes
    if cp >= 0x2600 and cp <= 0x27BF then                  -- misc symbols
        if cp == 0x2713 or cp == 0x2717 then return nil end -- in the font
        return ""
    end
    if cp >= 0x2B00 and cp <= 0x2BFF then return "" end    -- misc arrows etc
    return nil
end

function Emoji.filter(text)
    text = tostring(text or "")
    -- fast path: nothing that could be emoji-related
    if text:find("[\xE2\xEF\xF0-\xF4]") == nil then return text end

    local out = {}
    local i, n = 1, #text
    while i <= n do
        local b = text:byte(i)
        local len = 1
        if b >= 0xF0 then len = 4
        elseif b >= 0xE0 then len = 3
        elseif b >= 0xC0 then len = 2 end
        local chunk = text:sub(i, i + len - 1)
        -- only sequences that can carry emoji need decoding
        if (b == 0xE2 or b == 0xEF or b >= 0xF0) and #chunk == len then
            local cp
            if len == 3 then cp = b & 0x0F else cp = b & 0x07 end
            local ok = true
            for k = 1, len - 1 do
                local cb = text:byte(i + k)
                if cb == nil or cb < 0x80 or cb > 0xBF then
                    ok = false
                    break
                end
                cp = (cp << 6) | (cb & 0x3F)
            end
            if ok then
                local rep = translate(cp)
                if rep ~= nil then chunk = rep end
            end
        end
        out[#out + 1] = chunk
        i += len
    end
    return table.concat(out)
end
