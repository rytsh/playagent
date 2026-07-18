-- Remote control scenes for opencode servers:
--   RemoteListScene     manage configured servers
--   RemoteSessionsScene pick/create a session on a server
--   RemoteChatScene     live transcript, prompts, permissions, commands

local gfx <const> = playdate.graphics

local function drawTitle(text)
    AppFontBold:drawText(text, 8, 6)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawLine(0, 26, 400, 26)
end

local function drawHint(text)
    AppFont:drawText(text, 8, 222)
end

local function now()
    return playdate.getCurrentTimeMilliseconds()
end

------------------------------------------------------------------------
-- RemoteListScene
------------------------------------------------------------------------

RemoteListScene = {}
RemoteListScene.__index = RemoteListScene

function RemoteListScene.new()
    local self = setmetatable({}, RemoteListScene)
    self.list = ListView.new({})
    self.modal = nil
    return self
end

function RemoteListScene:refresh()
    local items = {}
    for i, r in ipairs(Config.data.remotes) do
        items[#items + 1] = {
            text = r.name,
            detail = r.host .. ":" .. tostring(r.port),
            index = i,
        }
    end
    items[#items + 1] = { text = "+ Add opencode server", add = true }
    self.list:setItems(items)
end

function RemoteListScene:enter()
    self:refresh()
end

function RemoteListScene:addFlow()
    local remote = { port = 4096, username = "opencode", password = "" }
    TextInput.show("Name:", "", function(name)
        if name == nil or #name == 0 then return end
        remote.name = name
        TextInput.show("Host (PC's LAN IP):", "", function(host)
            if host == nil or #host == 0 then return end
            remote.host = host
            TextInput.show("Port:", "4096", function(port)
                if port == nil then return end
                remote.port = tonumber(port) or 4096
                TextInput.show("Password (empty if none):", "", function(pass)
                    if pass == nil then return end
                    remote.password = pass
                    Config.addRemote(remote)
                    self:refresh()
                end)
            end)
        end)
    end)
end

function RemoteListScene:serverMenu(item)
    local r = Config.data.remotes[item.index]
    if r == nil then return end
    self.modal = ChoiceDialog.new(r.name .. " (" .. r.host .. ":" .. r.port .. ")",
        { "Connect", "Delete" },
        function(_, label)
            self.modal = nil
            if label == "Connect" then
                self.testing = "Connecting to " .. r.name .. "..."
                local client = OcClient.new(r)
                client:health(function(data, err)
                    self.testing = nil
                    if err ~= nil then
                        self.testing = r.name .. ": " .. err
                    else
                        local v = (type(data) == "table" and data.version) or "?"
                        self.testing = "opencode " .. tostring(v)
                        Scenes.push(RemoteSessionsScene.new(client))
                    end
                end)
            elseif label == "Delete" then
                Config.removeRemote(item.index)
                self:refresh()
            end
        end, true)
end

function RemoteListScene:update()
    if TextInput.active then
        TextInput.draw()
        return
    end
    drawTitle("opencode servers")
    if self.modal ~= nil then
        local m = self.modal
        if not m:update() and self.modal == m then self.modal = nil end
        return
    end

    if self.list:handleInput() then
        local item = self.list:current()
        if item ~= nil then
            if item.add then self:addFlow() else self:serverMenu(item) end
        end
        return
    end
    if playdate.buttonJustPressed(playdate.kButtonB) then
        Scenes.pop()
        return
    end
    self.list:draw(10, 36, 370, 160)
    if self.testing ~= nil then
        AppFont:drawText(self.testing, 8, 200)
    end
    drawHint("A: select   B: back")
end

------------------------------------------------------------------------
-- RemoteSessionsScene
------------------------------------------------------------------------

RemoteSessionsScene = {}
RemoteSessionsScene.__index = RemoteSessionsScene

local function truncate(s, n)
    s = tostring(s or "")
    if #s > n then return s:sub(1, n - 3) .. "..." end
    return s
end

function RemoteSessionsScene.new(client)
    local self = setmetatable({}, RemoteSessionsScene)
    self.client = client
    self.list = ListView.new({ { text = "Loading..." } })
    self.modal = nil
    return self
end

function RemoteSessionsScene:enter()
    self:refresh()
end

function RemoteSessionsScene:refresh()
    self.client:sessions(function(sessions, err)
        if err ~= nil then
            self.error = err
            return
        end
        table.sort(sessions, function(a, b)
            local au = (a.time and a.time.updated) or 0
            local bu = (b.time and b.time.updated) or 0
            return au > bu
        end)
        self.sessions = sessions
        self.client:status(function(statusMap, serr)
            self.statusMap = statusMap or {}
            self:rebuild()
        end)
    end)
end

function RemoteSessionsScene:rebuild()
    local items = { { text = "+ New session", add = true } }
    for _, s in ipairs(self.sessions or {}) do
        local st = self.statusMap and self.statusMap[s.id]
        local badge = (st and st.type ~= "idle") and st.type or nil
        items[#items + 1] = {
            text = truncate(s.title or s.id, 34),
            detail = badge,
            session = s,
        }
    end
    self.list:setItems(items)
end

function RemoteSessionsScene:update()
    drawTitle("Sessions @ " .. self.client.remote.name)

    if self.modal ~= nil then
        local m = self.modal
        if not m:update() and self.modal == m then self.modal = nil end
        return
    end

    if self.list:handleInput() then
        local item = self.list:current()
        if item ~= nil then
            if item.add then
                self.client:createSession(function(session, err)
                    if err ~= nil then
                        self.error = err
                    else
                        Scenes.push(RemoteChatScene.new(self.client, session))
                    end
                end)
            elseif item.session ~= nil then
                self.modal = ChoiceDialog.new(item.session.title or item.session.id,
                    { "Open", "Delete" },
                    function(_, label)
                        self.modal = nil
                        if label == "Open" then
                            Scenes.push(RemoteChatScene.new(self.client, item.session))
                        elseif label == "Delete" then
                            self.client:deleteSession(item.session.id, function()
                                self:refresh()
                            end)
                        end
                    end, true)
            end
        end
        return
    end
    if playdate.buttonJustPressed(playdate.kButtonB) then
        Scenes.pop()
        return
    end
    self.list:draw(10, 36, 370, 180)
    if self.error ~= nil then
        AppFont:drawText(self.error, 8, 200)
    end
    drawHint("A: open   B: back")
end

------------------------------------------------------------------------
-- RemoteChatScene
------------------------------------------------------------------------

RemoteChatScene = {}
RemoteChatScene.__index = RemoteChatScene

local function partsToText(parts)
    local out = {}
    for _, p in ipairs(parts or {}) do
        if p.type == "text" and p.text ~= nil and #p.text > 0 and p.ignored ~= true then
            out[#out + 1] = p.text
        elseif p.type == "tool" then
            local st = p.state or {}
            local label = st.title
            if label == nil or #label == 0 then label = st.status or "" end
            if st.status == "error" then label = "ERROR " .. (st.error or "") end
            out[#out + 1] = "[" .. (p.tool or "tool") .. "] " .. truncate(label, 90)
        end
    end
    return table.concat(out, "\n")
end

function RemoteChatScene.new(client, session)
    local self = setmetatable({}, RemoteChatScene)
    self.client = client
    self.session = session
    self.vsession = { messages = {} }
    self.view = ChatView.new(self.vsession)
    self.modal = nil
    self.permQueue = {}
    self.currentPerm = nil
    self.statusType = "idle"
    self.pollDue = 0
    self.fetching = false
    self.signature = ""
    self.agentName = nil

    self.events = OcEvents.new(client, function(etype, props)
        self:onEvent(etype, props)
    end)
    return self
end

function RemoteChatScene:enter()
    if self.events.stopped then
        self.events:start()
    end
end

function RemoteChatScene:leave()
    self.events:stop()
end

-- Pull the next poll earlier (never later).
function RemoteChatScene:schedulePoll(delayMs)
    local due = now() + (delayMs or 0)
    if due < self.pollDue then self.pollDue = due end
end

function RemoteChatScene:onEvent(etype, props)
    local sid = props.sessionID or (props.info and props.info.sessionID)
        or (props.part and props.part.sessionID)
    if etype == "permission.updated" then
        if props.sessionID == self.session.id then
            for _, p in ipairs(self.permQueue) do
                if p.id == props.id then return end
            end
            self.permQueue[#self.permQueue + 1] = props
        end
    elseif etype == "permission.replied" then
        for i, p in ipairs(self.permQueue) do
            if p.id == props.permissionID then
                table.remove(self.permQueue, i)
                break
            end
        end
        if self.currentPerm ~= nil and self.currentPerm.id == props.permissionID then
            -- someone else answered; drop the dialog
            self.currentPerm = nil
            self.modal = nil
        end
    elseif etype == "session.status" then
        if props.sessionID == self.session.id and props.status ~= nil then
            self.statusType = props.status.type or "idle"
            self:schedulePoll(300)
        end
    elseif etype == "message.updated" or etype == "message.part.updated" then
        if sid == self.session.id then
            self:schedulePoll(600)
        end
    end
end

function RemoteChatScene:refresh()
    if self.fetching then return end
    self.fetching = true
    self.client:messages(self.session.id, 30, function(list, err)
        self.fetching = false
        -- next periodic poll: fast while busy, slow when idle/live
        local interval
        if self.statusType == "busy" or self.statusType == "retry" then
            interval = self.events.connected and 3000 or 2500
        else
            interval = self.events.connected and 15000 or 6000
        end
        self.pollDue = now() + interval

        if err ~= nil then
            self:flash("Error: " .. err)
            return
        end

        local entries = {}
        local sigParts = { tostring(#list) }
        for _, m in ipairs(list) do
            local info = m.info or {}
            local text = partsToText(m.parts)
            if #text > 0 then
                entries[#entries + 1] = {
                    role = (info.role == "user") and "user" or "assistant",
                    content = text,
                }
                sigParts[#sigParts + 1] = tostring(#text)
            end
        end
        local signature = table.concat(sigParts, ",")
        if signature ~= self.signature then
            self.signature = signature
            self.vsession.messages = entries
            self.view:invalidate()
            self.view:scrollToBottom()
        end
    end)
end

function RemoteChatScene:flash(text)
    self.flashText = text
    self.flashUntil = now() + 5000
end

function RemoteChatScene:sendPrompt(text)
    self.client:promptAsync(self.session.id, text, self.agentName, function(_, err)
        if err ~= nil then
            self:flash("Error: " .. err)
        else
            self.statusType = "busy"
            self:schedulePoll(500)
        end
    end)
    -- show it immediately
    table.insert(self.vsession.messages, { role = "user", content = text })
    self.view:invalidate()
    self.view:scrollToBottom()
end

function RemoteChatScene:openActionMenu()
    local options = { "Type prompt", "Speak (mic)", "Commands", "Agent", "Todos", "Abort" }
    self.modal = ChoiceDialog.new("Session: " .. truncate(self.session.title or self.session.id, 40),
        options,
        function(_, label)
            self.modal = nil
            if label == "Type prompt" then
                TextInput.show("Prompt:", "", function(text)
                    if text ~= nil and #text > 0 then self:sendPrompt(text) end
                end)
            elseif label == "Speak (mic)" then
                self.modal = MicRecorder.new(function(wavPath, err)
                    self.modal = nil
                    if err ~= nil then
                        self:flash("Mic: " .. err)
                    elseif wavPath ~= nil then
                        self.transcribing = true
                        STT.transcribe(wavPath, function(text, terr)
                            self.transcribing = false
                            if terr ~= nil then
                                self:flash("STT: " .. terr)
                            elseif text ~= nil and #text > 0 then
                                self:sendPrompt(text)
                            end
                        end)
                    end
                end)
            elseif label == "Commands" then
                self:openCommands()
            elseif label == "Agent" then
                self:openAgentPicker()
            elseif label == "Todos" then
                self:openTodos()
            elseif label == "Abort" then
                self.client:abort(self.session.id, function(_, err)
                    self:flash(err and ("Error: " .. err) or "Aborted.")
                end)
            end
        end, true)
end

function RemoteChatScene:openCommands()
    self.client:commands(function(cmds, err)
        if err ~= nil then self:flash("Error: " .. err) return end
        if cmds == nil or #cmds == 0 then self:flash("No commands.") return end
        local labels = {}
        for _, c in ipairs(cmds) do labels[#labels + 1] = "/" .. c.name end
        self.modal = ChoiceDialog.new("Run command", labels, function(idx)
            self.modal = nil
            if idx == nil then return end
            local cmd = cmds[idx]
            TextInput.show("/" .. cmd.name .. " arguments:", "", function(args)
                if args == nil then return end
                self.client:runCommand(self.session.id, cmd.name, args, function(_, cerr)
                    if cerr ~= nil then self:flash("Error: " .. cerr) end
                    self:schedulePoll(500)
                end)
                self.statusType = "busy"
            end)
        end, true)
    end)
end

function RemoteChatScene:openAgentPicker()
    self.client:agents(function(agents, err)
        if err ~= nil then self:flash("Error: " .. err) return end
        local names = {}
        for _, a in ipairs(agents or {}) do
            if a.mode ~= "subagent" then names[#names + 1] = a.name end
        end
        if #names == 0 then self:flash("No agents.") return end
        self.modal = ChoiceDialog.new("Agent for prompts", names, function(_, label)
            self.modal = nil
            if label ~= nil then
                self.agentName = label
                self:flash("Agent: " .. label)
            end
        end, true)
    end)
end

function RemoteChatScene:openTodos()
    self.client:todo(self.session.id, function(todos, err)
        if err ~= nil then self:flash("Error: " .. err) return end
        if todos == nil or #todos == 0 then self:flash("No todos.") return end
        local lines = {}
        for _, t in ipairs(todos) do
            local mark = (t.status == "completed") and "[x] "
                or (t.status == "in_progress") and "[>] " or "[ ] "
            lines[#lines + 1] = mark .. truncate(t.content, 40)
        end
        self.modal = ChoiceDialog.new("Todos", lines, function()
            self.modal = nil
        end, true)
    end)
end

function RemoteChatScene:maybeShowPermission()
    if self.modal ~= nil or #self.permQueue == 0 then return end
    local perm = table.remove(self.permQueue, 1)
    self.currentPerm = perm
    local title = perm.title or (perm.type .. " permission")
    self.modal = ChoiceDialog.new("PERMISSION: " .. title,
        { "Allow once", "Always allow", "Reject" },
        function(idx)
            self.modal = nil
            self.currentPerm = nil
            local response = ({ "once", "always", "reject" })[idx]
            self.client:respondPermission(perm.sessionID, perm.id, response,
                function(_, err)
                    if err ~= nil then self:flash("Error: " .. err) end
                    self:schedulePoll(500)
                end)
        end, false)
end

function RemoteChatScene:statusLine()
    local live = self.events.connected and "LIVE" or "POLL"
    if self.transcribing then return "Transcribing..." end
    if self.flashText ~= nil then
        if now() < self.flashUntil then
            return self.flashText
        end
        self.flashText = nil
    end
    if #self.permQueue > 0 then
        return live .. "  |  permission request pending..."
    end
    if self.statusType == "busy" then
        local dots = ({ ".", "..", "..." })[math.floor(now() / 400) % 3 + 1]
        return live .. "  |  working" .. dots
    end
    if self.statusType == "retry" then
        return live .. "  |  retrying..."
    end
    return live .. "  |  A: menu   B: back   crank: scroll"
end

function RemoteChatScene:update()
    self.events:update()

    if now() >= self.pollDue then
        self:refresh()
    end

    if TextInput.active then
        TextInput.draw()
        return
    end

    self:maybeShowPermission()

    if self.modal ~= nil then
        self.view:update(self:statusLine(), false)
        local m = self.modal
        if not m:update() and self.modal == m then self.modal = nil end
        return
    end

    self.view:update(self:statusLine())

    if playdate.buttonJustPressed(playdate.kButtonA) then
        self:openActionMenu()
    elseif playdate.buttonJustPressed(playdate.kButtonB) then
        Scenes.pop()
    end
end
