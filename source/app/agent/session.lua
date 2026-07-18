-- Chat sessions, persisted with playdate.datastore.
-- Index file: "sessions" -> { nextId, list = { {id, title, personaId, created} } }
-- Each session:  "session_<id>" -> { id, personaId, messages = {...} }

Sessions = {}

function Sessions.loadIndex()
    local idx = playdate.datastore.read("sessions")
    if idx == nil then idx = { nextId = 1, list = {} } end
    if type(idx.list) ~= "table" then idx.list = {} end
    return idx
end

function Sessions.saveIndex(idx)
    playdate.datastore.write(idx, "sessions")
end

-- buddyName: custom pet name for buddy sessions (optional).
function Sessions.create(personaId, buddyName)
    local idx = Sessions.loadIndex()
    local id = idx.nextId
    idx.nextId = id + 1
    local t = playdate.getTime()
    local prefix = buddyName or "Session"
    local title = string.format("%s %d (%02d/%02d %02d:%02d)", prefix, id, t.day, t.month, t.hour, t.minute)
    table.insert(idx.list, 1, { id = id, title = title, personaId = personaId })
    Sessions.saveIndex(idx)

    local session = {
        id = id,
        personaId = personaId,
        buddyName = buddyName,
        messages = {
            { role = "system",
                content = Personas.systemPrompt(personaId, buddyName) },
        },
    }
    Sessions.save(session)
    return session
end

function Sessions.save(session)
    playdate.datastore.write(session, "session_" .. session.id)
end

function Sessions.load(id)
    return playdate.datastore.read("session_" .. id)
end

function Sessions.delete(id)
    playdate.datastore.delete("session_" .. id)
    local idx = Sessions.loadIndex()
    for i, meta in ipairs(idx.list) do
        if meta.id == id then
            table.remove(idx.list, i)
            break
        end
    end
    Sessions.saveIndex(idx)
end
