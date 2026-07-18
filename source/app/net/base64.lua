-- Minimal base64 encoder (for HTTP Basic auth).

Base64 = {}

local ALPHABET <const> = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function Base64.encode(data)
    local out = {}
    local len = #data
    local i = 1
    while i <= len - 2 do
        local a, b, c = data:byte(i, i + 2)
        local n = a << 16 | b << 8 | c
        out[#out + 1] = ALPHABET:sub((n >> 18) + 1, (n >> 18) + 1)
            .. ALPHABET:sub((n >> 12 & 63) + 1, (n >> 12 & 63) + 1)
            .. ALPHABET:sub((n >> 6 & 63) + 1, (n >> 6 & 63) + 1)
            .. ALPHABET:sub((n & 63) + 1, (n & 63) + 1)
        i += 3
    end
    local rem = len - i + 1
    if rem == 2 then
        local a, b = data:byte(i, i + 1)
        local n = a << 16 | b << 8
        out[#out + 1] = ALPHABET:sub((n >> 18) + 1, (n >> 18) + 1)
            .. ALPHABET:sub((n >> 12 & 63) + 1, (n >> 12 & 63) + 1)
            .. ALPHABET:sub((n >> 6 & 63) + 1, (n >> 6 & 63) + 1)
            .. "="
    elseif rem == 1 then
        local a = data:byte(i)
        local n = a << 16
        out[#out + 1] = ALPHABET:sub((n >> 18) + 1, (n >> 18) + 1)
            .. ALPHABET:sub((n >> 12 & 63) + 1, (n >> 12 & 63) + 1)
            .. "=="
    end
    return table.concat(out)
end
