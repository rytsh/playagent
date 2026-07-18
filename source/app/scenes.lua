-- Scene stack + all app scenes:
--   HomeScene, ChatScene, SessionsScene, McpScene, PersonaScene,
--   SettingsScene, AboutScene

local gfx <const> = playdate.graphics

------------------------------------------------------------------------
-- Scene stack
------------------------------------------------------------------------

Scenes = { stack = {} }

function Scenes.push(scene)
    table.insert(Scenes.stack, scene)
    if scene.enter then scene:enter() end
end

function Scenes.pop()
    local scene = table.remove(Scenes.stack)
    if scene and scene.leave then scene:leave() end
    -- refresh the scene we return to (e.g. Home shows persona/MCP counts)
    local top = Scenes.top()
    if top and top.enter then top:enter() end
end

function Scenes.top()
    return Scenes.stack[#Scenes.stack]
end

function Scenes.update()
    TextInput.poll()
    local scene = Scenes.top()
    if scene then scene:update() end
end

function Scenes.saveAll()
    for _, scene in ipairs(Scenes.stack) do
        if scene.persist then scene:persist() end
    end
end

local function drawTitle(text)
    AppFontBold:drawText(text, 8, 6)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawLine(0, 26, 400, 26)
end

local function drawHint(text)
    local font = AppFont
    font:drawText(text, 8, 222)
end

------------------------------------------------------------------------
-- HomeScene
------------------------------------------------------------------------

HomeScene = {}
HomeScene.__index = HomeScene

function HomeScene.new()
    local self = setmetatable({}, HomeScene)
    self.list = ListView.new({
        { text = "New session" },
        { text = "Sessions" },
        { text = "Remote: opencode" },
        { text = "MCP servers" },
        { text = "Persona" },
        { text = "Settings" },
        { text = "About" },
    })
    return self
end

function HomeScene:enter()
    local persona = Personas.byId(Config.data.personaId)
    self.list.items[3].detail = tostring(#Config.data.remotes)
    self.list.items[4].detail = tostring(#Config.data.mcpServers)
    self.list.items[5].detail = persona.name
end

function HomeScene:update()
    drawTitle("PlayAgent")
    local font = AppFont
    font:drawText(Config.data.api.host .. "  /  " .. Config.data.api.model, 8, 200)

    if self.list:handleInput() then
        local _, idx = self.list:current()
        if idx == 1 then
            local session = Sessions.create(Config.data.personaId)
            Scenes.push(ChatScene.new(session))
        elseif idx == 2 then
            Scenes.push(SessionsScene.new())
        elseif idx == 3 then
            Scenes.push(RemoteListScene.new())
        elseif idx == 4 then
            Scenes.push(McpScene.new())
        elseif idx == 5 then
            Scenes.push(PersonaScene.new())
        elseif idx == 6 then
            Scenes.push(SettingsScene.new())
        elseif idx == 7 then
            Scenes.push(AboutScene.new())
        end
        return
    end
    self.list:draw(10, 36, 370, 160)
    drawHint("A: select")
end

------------------------------------------------------------------------
-- ChatScene
------------------------------------------------------------------------

ChatScene = {}
ChatScene.__index = ChatScene

function ChatScene.new(session)
    local self = setmetatable({}, ChatScene)
    self.session = session
    self.view = ChatView.new(session)
    self.modal = nil
    self.status = nil
    self.mcpConnected = false
    self.agent = Agent.new(session, {
        onStatus = function(text) self.status = text end,
        onAskUser = function(question, options, cb)
            self.modal = ChoiceDialog.new(question, options, function(_, label)
                cb(label or "(no answer)")
            end, false)
        end,
        onConfirm = function(question, cb)
            self.modal = ChoiceDialog.new(question, { "Allow", "Reject" },
                function(idx)
                    self.modal = nil
                    cb(idx == 1)
                end, false)
        end,
        onDone = function(err)
            self.status = nil
            if err ~= nil then
                self:flash("Error: " .. tostring(err))
            end
            self.view:invalidate()
            self.view:scrollToBottom()
        end,
    })
    return self
end

function ChatScene:flash(text)
    self.flashText = text
    self.flashUntil = playdate.getCurrentTimeMilliseconds() + 5000
end

function ChatScene:persist()
    Sessions.save(self.session)
end

function ChatScene:enter()
    if not self.mcpConnected then
        local servers = Config.enabledMcpServers()
        if #servers > 0 then
            self.status = "Connecting MCP..."
            Mcp.connectAll(function(name, err)
                if err ~= nil then
                    self:flash("MCP " .. name .. ": " .. err)
                end
            end, function()
                self.status = nil
                self.mcpConnected = true
                self:maybeIntro()
            end)
        else
            self.mcpConnected = true
            self:maybeIntro()
        end
    end
end

-- With a self-determined persona, let the agent introduce itself when the
-- session is brand new.
function ChatScene:maybeIntro()
    if self.session.personaId == "self" and #self.session.messages == 1
        and not self.agent.busy then
        self.agent:run()
    end
end

function ChatScene:statsText()
    local frac, tokens = Agent.contextFraction(self.session)
    local exact = self.session.lastUsage ~= nil
    local ctx = (exact and "" or "~") .. tostring(tokens) .. " tokens"
    if frac ~= nil then
        ctx = ctx .. string.format(" (%d%% of %d)",
            math.floor(frac * 100 + 0.5), Config.data.api.contextTokens)
    end
    return "Session stats\n"
        .. "Messages: " .. #self.session.messages .. "\n"
        .. "Context: " .. ctx .. "\n"
        .. "Total used: " .. tostring(self.session.totalTokens or 0)
        .. " tokens\n"
        .. "Model: " .. Config.data.api.model .. "\n"
        .. "Persona: " .. Personas.byId(self.session.personaId).name
end

function ChatScene:openActionMenu()
    local options = { "Type message", "Speak (mic)", "Dictate (live)" }
    local hasPrompts = false
    for _, client in pairs(Mcp.clients) do
        if #client.prompts > 0 then hasPrompts = true end
    end
    if hasPrompts then options[#options + 1] = "MCP prompts" end
    if self.agent:lastUserIndex() ~= nil then
        options[#options + 1] = "Retry last message"
        options[#options + 1] = "Delete last message"
    end
    options[#options + 1] = "Stats"
    options[#options + 1] = "Compact session"

    self.modal = ChoiceDialog.new("What do you want to do?", options,
        function(idx, label)
            self.modal = nil
            if label == "Stats" then
                self.modal = ChoiceDialog.new(self:statsText(), { "OK" },
                    function() self.modal = nil end, true)
            elseif label == "Compact session" then
                if #self.session.messages <= 3 then
                    self:flash("Nothing to compact yet.")
                    return
                end
                self.agent:compact(function(err)
                    self.status = nil
                    if err ~= nil then
                        self:flash("Compact: " .. tostring(err))
                    else
                        self:flash("Session compacted.")
                    end
                    self.view:invalidate()
                    self.view:scrollToBottom()
                end)
            elseif label == "Type message" then
                TextInput.show("Message:", "", function(text)
                    if text ~= nil and #text > 0 then
                        self:send(text)
                    end
                end)
            elseif label == "Speak (mic)" then
                self.modal = MicRecorder.new(function(wavPath, err)
                    self.modal = nil
                    if err ~= nil then
                        self:flash("Mic: " .. err)
                    elseif wavPath ~= nil then
                        self.status = "Transcribing..."
                        STT.transcribe(wavPath, function(text, terr)
                            self.status = nil
                            if terr ~= nil then
                                self:flash("STT: " .. terr)
                            elseif text ~= nil and #text > 0 then
                                self:send(text)
                            end
                        end)
                    end
                end)
            elseif label == "Dictate (live)" then
                self.modal = LiveMic.new(function(text, err)
                    self.modal = nil
                    if err ~= nil then
                        self:flash("Mic: " .. err)
                    elseif text ~= nil and #text > 0 then
                        self:send(text)
                    end
                end)
            elseif label == "Retry last message" then
                -- Drop replies after the last user message and ask again.
                if self.agent:rollbackLastUser(false) then
                    self.view:invalidate()
                    self.view:scrollToBottom()
                    self.agent:run()
                end
            elseif label == "Delete last message" then
                -- Remove the last user message and everything after it.
                if self.agent:rollbackLastUser(true) then
                    self:flash("Last message deleted.")
                    self.view:invalidate()
                    self.view:scrollToBottom()
                end
            elseif label == "MCP prompts" then
                self:openPromptPicker()
            end
        end, true)
end

function ChatScene:openPromptPicker()
    local entries = {} -- { label, client, prompt }
    for sname, client in pairs(Mcp.clients) do
        for _, prompt in ipairs(client.prompts) do
            entries[#entries + 1] = {
                label = sname .. ": " .. prompt.name,
                client = client,
                prompt = prompt,
            }
        end
    end
    if #entries == 0 then return end
    local labels = {}
    for _, e in ipairs(entries) do labels[#labels + 1] = e.label end

    self.modal = ChoiceDialog.new("Pick a prompt", labels, function(idx)
        self.modal = nil
        if idx == nil then return end
        local entry = entries[idx]
        self:collectPromptArgs(entry.client, entry.prompt, {}, 1)
    end, true)
end

-- Ask (via keyboard) for each prompt argument, then fetch & run the prompt.
function ChatScene:collectPromptArgs(client, prompt, args, i)
    local argDefs = prompt.arguments or {}
    if i > #argDefs then
        self.status = "Loading prompt..."
        client:getPrompt(prompt.name, args, function(messages, err)
            self.status = nil
            if err ~= nil then
                self:flash("Prompt: " .. err)
                return
            end
            self.agent:sendPromptMessages(messages)
            self.view:invalidate()
            self.view:scrollToBottom()
        end)
        return
    end
    local def = argDefs[i]
    TextInput.show(prompt.name .. " / " .. def.name .. ":", "", function(text)
        if text == nil then return end -- cancelled
        if #text > 0 then args[def.name] = text end
        self:collectPromptArgs(client, prompt, args, i + 1)
    end)
end

function ChatScene:send(text)
    self.view:invalidate()
    self.view:scrollToBottom()
    self.agent:sendUser(text)
    self.view:invalidate()
end

function ChatScene:update()
    if TextInput.active then
        TextInput.draw()
        return
    end

    if self.modal ~= nil then
        self.view:update(self.status, false)
        -- NOTE: a modal callback may replace self.modal with a new modal
        -- (e.g. choice menu -> mic recorder); only clear it if unchanged.
        local m = self.modal
        if not m:update() and self.modal == m then
            self.modal = nil
        end
        return
    end

    local statusLine = self.status
    if statusLine == nil and self.flashText ~= nil then
        if playdate.getCurrentTimeMilliseconds() < self.flashUntil then
            statusLine = self.flashText
        else
            self.flashText = nil
        end
    end
    if self.agent.busy and statusLine ~= nil then
        statusLine = statusLine .. "   B: cancel"
    end
    if statusLine == nil and not self.agent.busy then
        statusLine = "A: talk    B: back    crank: scroll"
        local frac = Agent.contextFraction(self.session)
        if frac ~= nil and #self.session.messages > 1 then
            local pct = math.floor(frac * 100 + 0.5)
            if frac >= 0.7 then
                statusLine = "A: talk  B: back  ctx " .. pct .. "% - compact?"
            else
                statusLine = "A: talk  B: back  ctx " .. pct .. "%"
            end
        end
    end

    self.view:update(statusLine)

    if self.agent.busy then
        if playdate.buttonJustPressed(playdate.kButtonB) then
            self.agent:cancel()
            self:flash("Cancelled.")
            self.view:invalidate()
            self.view:scrollToBottom()
        end
    elseif playdate.buttonJustPressed(playdate.kButtonA) then
        self:openActionMenu()
    elseif playdate.buttonJustPressed(playdate.kButtonB) then
        Sessions.save(self.session)
        Scenes.pop()
    end
end

------------------------------------------------------------------------
-- SessionsScene
------------------------------------------------------------------------

SessionsScene = {}
SessionsScene.__index = SessionsScene

function SessionsScene.new()
    local self = setmetatable({}, SessionsScene)
    self.list = ListView.new({})
    self.modal = nil
    return self
end

function SessionsScene:enter()
    self.index = Sessions.loadIndex()
    local items = {}
    for _, meta in ipairs(self.index.list) do
        items[#items + 1] = { text = meta.title, id = meta.id }
    end
    self.list:setItems(items)
end

function SessionsScene:update()
    drawTitle("Sessions")

    if self.modal ~= nil then
        if not self.modal:update() then self.modal = nil end
        return
    end

    if #self.list.items == 0 then
        AppFont:drawText("No sessions yet.", 12, 40)
        if playdate.buttonJustPressed(playdate.kButtonB) then Scenes.pop() end
        drawHint("B: back")
        return
    end

    if self.list:handleInput() then
        local item = self.list:current()
        if item ~= nil then
            self.modal = ChoiceDialog.new(item.text, { "Open", "Delete" },
                function(_, label)
                    self.modal = nil
                    if label == "Open" then
                        local session = Sessions.load(item.id)
                        if session ~= nil then
                            Scenes.push(ChatScene.new(session))
                        end
                    elseif label == "Delete" then
                        Sessions.delete(item.id)
                        self:enter()
                    end
                end, true)
        end
        return
    end
    if playdate.buttonJustPressed(playdate.kButtonB) then
        Scenes.pop()
        return
    end
    self.list:draw(10, 36, 370, 180)
    drawHint("A: open/delete   B: back")
end

------------------------------------------------------------------------
-- McpScene: manage remote MCP servers
------------------------------------------------------------------------

McpScene = {}
McpScene.__index = McpScene

function McpScene.new()
    local self = setmetatable({}, McpScene)
    self.list = ListView.new({})
    self.modal = nil
    return self
end

function McpScene:refresh()
    local items = {}
    for i, s in ipairs(Config.data.mcpServers) do
        items[#items + 1] = {
            text = s.name,
            detail = (s.enabled and "on" or "off"),
            index = i,
        }
    end
    items[#items + 1] = { text = "+ Add server", add = true }
    self.list:setItems(items)
end

function McpScene:enter()
    self:refresh()
end

function McpScene:addServerFlow()
    local server = { ssl = true, port = 443, path = "/mcp", enabled = true }
    TextInput.show("Server name:", "", function(name)
        if name == nil or #name == 0 then return end
        server.name = name
        TextInput.show("Host (e.g. mcp.example.com):", "", function(host)
            if host == nil or #host == 0 then return end
            server.host = host
            TextInput.show("Path:", "/mcp", function(path)
                if path == nil then return end
                if #path > 0 then server.path = path end
                TextInput.show("Port:", "443", function(port)
                    if port == nil then return end
                    local n = tonumber(port)
                    if n ~= nil then server.port = n end
                    self.modal = ChoiceDialog.new("Use HTTPS?", { "Yes (https)", "No (http)" },
                        function(idx)
                            self.modal = nil
                            server.ssl = (idx == 1)
                            if not server.ssl and server.port == 443 then
                                server.port = 80
                            end
                            Config.addMcpServer(server)
                            self:refresh()
                        end, false)
                end)
            end)
        end)
    end)
end

function McpScene:serverMenu(item)
    local s = Config.data.mcpServers[item.index]
    if s == nil then return end
    self.modal = ChoiceDialog.new(s.name .. " (" .. s.host .. s.path .. ")",
        { s.enabled and "Disable" or "Enable", "Test connection", "Delete" },
        function(_, label)
            self.modal = nil
            if label == "Enable" or label == "Disable" then
                s.enabled = not s.enabled
                Config.save()
                self:refresh()
            elseif label == "Test connection" then
                self.testing = "Testing " .. s.name .. "..."
                local client = McpClient.new(s)
                client:connect(function(_, err)
                    if err ~= nil then
                        self.testing = s.name .. ": FAILED - " .. err
                    else
                        self.testing = s.name .. ": OK - " .. #client.tools
                            .. " tools, " .. #client.prompts .. " prompts"
                    end
                end)
            elseif label == "Delete" then
                Config.removeMcpServer(item.index)
                self:refresh()
            end
        end, true)
end

function McpScene:update()
    if TextInput.active then
        TextInput.draw()
        return
    end
    drawTitle("MCP servers")
    if self.modal ~= nil then
        if not self.modal:update() then self.modal = nil end
        return
    end

    if self.list:handleInput() then
        local item = self.list:current()
        if item ~= nil then
            if item.add then
                self:addServerFlow()
            else
                self:serverMenu(item)
            end
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
-- PersonaScene: pick who the agent is
------------------------------------------------------------------------

PersonaScene = {}
PersonaScene.__index = PersonaScene

function PersonaScene.new()
    local self = setmetatable({}, PersonaScene)
    self.list = ListView.new({})
    self.modal = nil
    return self
end

function PersonaScene:refresh()
    local items = {}
    for _, p in ipairs(Personas.all()) do
        items[#items + 1] = { text = p.name, id = p.id, user = p.user }
    end
    items[#items + 1] = { text = "+ Add persona", add = true }
    self.list:setItems(items)
end

function PersonaScene:enter()
    self:refresh()
end

function PersonaScene:addPersonaFlow(name)
    TextInput.show("Persona name:", name or "", function(pname)
        if pname == nil or #pname == 0 then return end
        TextInput.show("Persona prompt:", Config.data.personas[pname] or "",
            function(prompt)
                if prompt == nil or #prompt == 0 then return end
                Config.setPersona(pname, prompt)
                self:refresh()
            end)
    end)
end

function PersonaScene:userPersonaMenu(item)
    local name = item.text
    self.modal = ChoiceDialog.new(name, { "Use", "Edit prompt", "Delete" },
        function(_, label)
            self.modal = nil
            if label == "Use" then
                Config.data.personaId = item.id
                Config.save()
            elseif label == "Edit prompt" then
                TextInput.show("Prompt for " .. name .. ":",
                    Config.data.personas[name] or "", function(prompt)
                        if prompt ~= nil and #prompt > 0 then
                            Config.setPersona(name, prompt)
                        end
                    end)
            elseif label == "Delete" then
                self.modal = ChoiceDialog.new('Delete persona "' .. name .. '"?',
                    { "Delete", "Cancel" }, function(_, l2)
                        self.modal = nil
                        if l2 == "Delete" then
                            Config.removePersona(name)
                            self:refresh()
                        end
                    end, true)
            end
        end, true)
end

function PersonaScene:update()
    if TextInput.active then
        TextInput.draw()
        return
    end
    drawTitle("Persona")

    if self.modal ~= nil then
        if not self.modal:update() then self.modal = nil end
        return
    end

    for i, item in ipairs(self.list.items) do
        if not item.add then
            item.detail = (item.id == Config.data.personaId) and "*" or nil
        end
    end

    if self.list:handleInput() then
        local item = self.list:current()
        if item ~= nil then
            if item.add then
                self:addPersonaFlow()
            elseif item.user then
                self:userPersonaMenu(item)
            elseif item.id == "custom" then
                TextInput.show("Describe the agent:", Config.data.customPersona or "",
                    function(text)
                        if text ~= nil and #text > 0 then
                            Config.data.customPersona = text
                            Config.data.personaId = "custom"
                            Config.save()
                        end
                    end)
            else
                Config.data.personaId = item.id
                Config.save()
            end
        end
        return
    end
    if playdate.buttonJustPressed(playdate.kButtonB) then
        Scenes.pop()
        return
    end
    self.list:draw(10, 36, 370, 160)
    drawHint("Applies to new sessions.  A: choose   B: back")
end

------------------------------------------------------------------------
-- SettingsScene: LLM / STT endpoint configuration
------------------------------------------------------------------------

SettingsScene = {}
SettingsScene.__index = SettingsScene

function SettingsScene.new()
    local self = setmetatable({}, SettingsScene)
    self.list = ListView.new({})
    self.list.rowHeight = 22
    return self
end

local function maskKey(key)
    if key == nil or #key == 0 then return "(not set)" end
    if #key <= 8 then return "****" end
    return key:sub(1, 4) .. "..." .. key:sub(-4)
end

------------------------------------------------------------------------
-- SttSettingsScene: speech-to-text and optional dedicated endpoint
------------------------------------------------------------------------

SttSettingsScene = {}
SttSettingsScene.__index = SttSettingsScene

function SttSettingsScene.new()
    local self = setmetatable({}, SttSettingsScene)
    self.list = ListView.new({})
    self.list.rowHeight = 22
    return self
end

function SttSettingsScene:refresh()
    local s = Config.data.stt
    local items = {
        {
            text = "External endpoint",
            detail = s.useExternal and "on" or "off",
            key = "external",
        },
        {
            text = "Model",
            detail = s.useExternal and s.externalModel or s.model,
            key = "model",
        },
        {
            text = "Language",
            detail = (#(s.language or "") > 0) and s.language or "auto",
            key = "language",
        },
        { text = "Max record sec", detail = tostring(s.maxSeconds), key = "seconds" },
    }
    if s.useExternal then
        items[#items + 1] = {
            text = "Host",
            detail = (#(s.host or "") > 0) and s.host or "(required)",
            key = "host",
        }
        items[#items + 1] = { text = "Port", detail = tostring(s.port or 8000), key = "port" }
        items[#items + 1] = { text = "HTTPS", detail = s.ssl and "on" or "off", key = "ssl" }
        items[#items + 1] = { text = "Base path", detail = s.basePath or "/v1", key = "basePath" }
        items[#items + 1] = { text = "API key", detail = maskKey(s.key), key = "key" }
    end
    self.list:setItems(items)
end

function SttSettingsScene:enter()
    self:refresh()
end

function SttSettingsScene:edit(item)
    local s = Config.data.stt
    local function done()
        Config.save()
        self:refresh()
    end

    if item.key == "external" then
        if s.useExternal then
            s.useExternal = false
            done()
        elseif s.host ~= nil and #s.host > 0 then
            s.useExternal = true
            done()
        else
            TextInput.show("External STT host:", "", function(host)
                if host == nil or #host == 0 then return end
                s.host = host
                s.useExternal = true
                done()
            end)
        end
        return
    end
    if item.key == "ssl" then
        s.ssl = not s.ssl
        done()
        return
    end

    local prompts = {
        model = {
            s.useExternal and "External STT model:" or "Main API STT model:",
            s.useExternal and s.externalModel or s.model,
            function(v)
                if s.useExternal then s.externalModel = v else s.model = v end
            end,
        },
        language = { "Language (ISO or empty):", s.language or "", function(v) s.language = v end, true },
        seconds = { "Max record seconds:", tostring(s.maxSeconds), function(v)
            s.maxSeconds = math.max(2, math.min(30, tonumber(v) or s.maxSeconds))
        end },
        host = { "External STT host:", s.host or "", function(v) s.host = v end },
        port = { "External STT port:", tostring(s.port or 8000), function(v)
            s.port = tonumber(v) or s.port
        end },
        basePath = { "STT base path:", s.basePath or "/v1", function(v) s.basePath = v end },
        key = { "STT key (empty = no auth):", s.key or "", function(v) s.key = v end, true },
    }
    local p = prompts[item.key]
    if p == nil then return end
    TextInput.show(p[1], p[2], function(text)
        if text == nil then return end
        if #text > 0 or p[4] then p[3](text) end
        done()
    end)
end

function SttSettingsScene:update()
    if TextInput.active then
        TextInput.draw()
        return
    end
    drawTitle("Speech-to-text")
    if self.list:handleInput() then
        local item = self.list:current()
        if item ~= nil then self:edit(item) end
        return
    end
    if playdate.buttonJustPressed(playdate.kButtonB) then
        Config.save()
        Scenes.pop()
        return
    end
    self.list:draw(10, 34, 376, 166)
    local endpoint
    if Config.data.stt.useExternal then
        endpoint = "Endpoint: " .. Config.data.stt.host .. ":"
            .. tostring(Config.data.stt.port or 8000)
    else
        endpoint = "Endpoint: main API (" .. Config.data.api.host .. ")"
    end
    AppFont:drawText(TextWrap.truncate(AppFont, endpoint, 384), 8, 204)
    drawHint("A: edit   B: back")
end

function SettingsScene:refresh()
    local a = Config.data.api
    local s = Config.data.stt
    self.list:setItems({
        { text = "Import config (Wi-Fi)", detail = ">", key = "import" },
        { text = "Export config (Wi-Fi)", detail = ">", key = "export" },
        { text = "API host", detail = a.host, key = "host" },
        { text = "API port", detail = tostring(a.port), key = "port" },
        { text = "HTTPS", detail = a.ssl and "on" or "off", key = "ssl" },
        { text = "Base path", detail = a.basePath, key = "basePath" },
        { text = "API key", detail = maskKey(a.key), key = "key" },
        { text = "Model", detail = a.model, key = "model" },
        {
            text = "Speech-to-text",
            detail = s.useExternal and "external >" or "main API >",
            key = "stt",
        },
    })
end

function SettingsScene:enter()
    self:refresh()
end

function SettingsScene:edit(item)
    local a = Config.data.api
    local s = Config.data.stt
    local function done()
        Config.save()
        self:refresh()
    end
    if item.key == "ssl" then
        a.ssl = not a.ssl
        done()
        return
    end
    if item.key == "import" then
        self:importConfig()
        return
    end
    if item.key == "export" then
        self:exportConfig()
        return
    end
    if item.key == "stt" then
        Scenes.push(SttSettingsScene.new())
        return
    end
    local prompts = {
        host = { "API host:", a.host, function(v) a.host = v end },
        port = { "API port:", tostring(a.port), function(v) a.port = tonumber(v) or a.port end },
        basePath = { "Base path:", a.basePath, function(v) a.basePath = v end },
        key = { "API key:", a.key, function(v) a.key = v end },
        model = { "Model:", a.model, function(v) a.model = v end },
    }
    local p = prompts[item.key]
    if p == nil then return end
    TextInput.show(p[1], p[2], function(text)
        if text == nil then return end
        if #text > 0 or p[4] then p[3](text) end
        done()
    end)
end

-- Fetch the full configuration from tools/provision.py running on the PC.
-- Only the PC's IP has to be typed; keys/passwords never touch the crank
-- keyboard.
function SettingsScene:importConfig()
    TextInput.show("PC address (ip or ip:port):", Config.data.provisionHost or "",
        function(text)
            if text == nil or #text == 0 then return end
            Config.data.provisionHost = text
            Config.save()
            TextInput.show("PIN (shown by provision.py):", "", function(pin)
                if pin == nil then return end
                self:fetchConfig(text, pin)
            end)
        end)
end

function SettingsScene:fetchConfig(address, pin)
    local host, port = address:match("^([^:]+):(%d+)$")
    if host == nil then
        host = address
        port = "9393"
    end
    local headers = nil
    if pin ~= nil and #pin > 0 then
        headers = {
            ["Authorization"] = "Basic " .. Base64.encode("playagent:" .. pin),
        }
    end
    self.info = "Fetching from " .. host .. ":" .. port .. "..."
    Http.request({
        host = host,
        port = tonumber(port),
        ssl = false,
        method = "GET",
        path = "/config",
        headers = headers,
        callback = function(resp)
            if resp.status == 401 then
                self.info = "Failed: wrong PIN"
                return
            end
            if not resp.ok or resp.status ~= 200 then
                self.info = "Failed: " .. (resp.error or ("HTTP " .. tostring(resp.status)))
                return
            end
            local data = json.decode(resp.body)
            if data == nil then
                self.info = "Failed: invalid JSON"
                return
            end
            local summary = Config.applyImport(data)
            if summary == nil then
                self.info = "Nothing to import."
            else
                self.info = "Imported: " .. summary
                self:refresh()
            end
        end,
    })
end

-- Push the device configuration to tools/provision.py --receive on the PC.
-- The mirror image of importConfig: the Playdate can only make outgoing
-- requests, so the device POSTs and the PC listens.
function SettingsScene:exportConfig()
    TextInput.show("PC address (ip or ip:port):", Config.data.provisionHost or "",
        function(text)
            if text == nil or #text == 0 then return end
            Config.data.provisionHost = text
            Config.save()
            TextInput.show("PIN (shown by provision.py):", "", function(pin)
                if pin == nil then return end
                self:pushConfig(text, pin)
            end)
        end)
end

function SettingsScene:pushConfig(address, pin)
    local host, port = address:match("^([^:]+):(%d+)$")
    if host == nil then
        host = address
        port = "9393"
    end
    local headers = { ["Content-Type"] = "application/json" }
    if pin ~= nil and #pin > 0 then
        headers["Authorization"] = "Basic " .. Base64.encode("playagent:" .. pin)
    end
    self.info = "Sending to " .. host .. ":" .. port .. "..."
    Http.request({
        host = host,
        port = tonumber(port),
        ssl = false,
        method = "POST",
        path = "/config",
        headers = headers,
        body = json.encode(Config.data),
        callback = function(resp)
            if resp.status == 401 then
                self.info = "Failed: wrong PIN"
            elseif not resp.ok or resp.status ~= 200 then
                self.info = "Failed: " .. (resp.error or ("HTTP " .. tostring(resp.status)))
            else
                self.info = "Config exported."
            end
        end,
    })
end

function SettingsScene:update()
    if TextInput.active then
        TextInput.draw()
        return
    end
    drawTitle("Settings")

    if self.list:handleInput() then
        local item = self.list:current()
        if item ~= nil then self:edit(item) end
        return
    end
    if playdate.buttonJustPressed(playdate.kButtonB) then
        Config.save()
        Scenes.pop()
        return
    end
    self.list:draw(10, 34, 376, 160)
    if self.info ~= nil then
        AppFont:drawText(TextWrap.truncate(AppFont, self.info, 384), 8, 200)
    end
    drawHint("A: edit   B: back")
end

------------------------------------------------------------------------
-- AboutScene: version, project link and contact info
------------------------------------------------------------------------

local ABOUT_GITHUB <const> = "github.com/rytsh/playagent"
local ABOUT_EMAIL <const> = "eates23@gmail.com"

AboutScene = {}
AboutScene.__index = AboutScene

function AboutScene.new()
    return setmetatable({}, AboutScene)
end

function AboutScene:update()
    drawTitle("About")

    local meta = playdate.metadata or {}
    local version = meta.version or "?"
    local y = 42

    AppFontBold:drawText("PlayAgent v" .. version, 8, y)
    y += 22
    AppFont:drawText("An LLM agent for the Playdate.", 8, y)
    y += 34

    AppFontBold:drawText("Project", 8, y)
    y += 20
    AppFont:drawText(ABOUT_GITHUB, 8, y)
    y += 34

    AppFontBold:drawText("Contact", 8, y)
    y += 20
    AppFont:drawText(ABOUT_EMAIL, 8, y)

    if playdate.buttonJustPressed(playdate.kButtonB) then
        Scenes.pop()
        return
    end
    drawHint("B: back")
end
