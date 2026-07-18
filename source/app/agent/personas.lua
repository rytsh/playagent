-- Agent personas. "self" is special: the agent decides who it is by itself
-- at the start of each session.

Personas = {}

local BASE <const> = [[
You are running on a Playdate, a tiny handheld console with a 400x240 1-bit
black & white screen, a crank, a d-pad and two buttons (A/B). Typing is slow
for the user, so keep answers short and to the point. You may use minimal
markdown: **bold**, ## short headers, - bullet lists and ``` code blocks.
No tables, no images, no emoji, no long lists. When a decision is needed,
prefer the ask_user tool to present the user a small set of choices instead
of asking open questions.]]

Personas.list = {
    {
        id = "assistant",
        name = "Assistant",
        prompt = "You are a helpful, concise assistant.",
    },
    {
        id = "self",
        name = "Self-determined",
        prompt = [[You decide for yourself who you are: pick your own name,
personality and speaking style at the start of the session, introduce
yourself in one short sentence, and stay in character afterwards.]],
    },
    {
        id = "gamemaster",
        name = "Game master",
        prompt = [[You are a game master running a short interactive text
adventure. Describe scenes in 2-3 sentences and always offer the next moves
via the ask_user tool with 2-4 options.]],
    },
    {
        id = "robot",
        name = "Retro robot",
        prompt = [[You are CRANK-1, a cheerful retro robot living inside a
yellow Playdate console. You speak in short, slightly mechanical sentences
and love the crank.]],
    },
    {
        id = "custom",
        name = "Custom...",
        prompt = nil, -- taken from Config.data.customPersona
    },
}

-- User-defined personas live in Config.data.personas (name -> prompt map)
-- and get the id "user:<name>".

function Personas.userNames()
    local names = {}
    for name in pairs(Config.data.personas or {}) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

-- Builtins plus user-defined personas, for pickers.
function Personas.all()
    local out = {}
    for _, p in ipairs(Personas.list) do out[#out + 1] = p end
    for _, name in ipairs(Personas.userNames()) do
        out[#out + 1] = {
            id = "user:" .. name,
            name = name,
            prompt = Config.data.personas[name],
            user = true,
        }
    end
    return out
end

function Personas.byId(id)
    -- Buddy mode personas ("buddy:<animal>") live in app/buddy.lua.
    local buddy = Buddies.fromPersonaId(id)
    if buddy ~= nil then
        return {
            id = id,
            name = buddy.name .. " (" .. buddy.kind .. ")",
            prompt = Buddies.prompt(buddy),
            buddy = true,
        }
    end
    local userName = (id or ""):match("^user:(.+)$")
    if userName ~= nil then
        local prompt = (Config.data.personas or {})[userName]
        if prompt ~= nil then
            return { id = id, name = userName, prompt = prompt, user = true }
        end
    end
    for _, p in ipairs(Personas.list) do
        if p.id == id then return p end
    end
    return Personas.list[1]
end

-- buddyName: custom pet name for buddy personas (optional).
function Personas.systemPrompt(id, buddyName)
    local p = Personas.byId(id)
    local prompt = p.prompt
    if p.buddy and buddyName ~= nil then
        prompt = Buddies.prompt(Buddies.fromPersonaId(id), buddyName)
    end
    if p.id == "custom" then
        prompt = Config.data.customPersona
        if prompt == nil or #prompt == 0 then
            prompt = Personas.list[1].prompt
        end
    end
    return BASE .. "\n\n" .. prompt
end
