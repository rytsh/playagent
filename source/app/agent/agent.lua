-- The agent loop: send conversation to the LLM, execute tool calls
-- (built-in or MCP), feed results back, repeat until a plain reply.

Agent = {}
Agent.__index = Agent

local MAX_STEPS <const> = 8

-- session: table from Sessions.create()/Sessions.load()
-- hooks:
--   onStatus(text)                     -- progress ("Thinking...", "Tool: x")
--   onAskUser(question, options, cb)   -- show choice UI, cb(answerText)
--   onDone(err)                        -- loop finished (err may be nil)
function Agent.new(session, hooks)
    local self = setmetatable({}, Agent)
    self.session = session
    self.hooks = hooks
    self.busy = false
    return self
end

function Agent:_status(text)
    if self.hooks.onStatus then self.hooks.onStatus(text) end
end

-- Append a user message and run the loop.
function Agent:sendUser(text)
    table.insert(self.session.messages, { role = "user", content = text })
    self:run()
end

-- Append MCP prompt messages (converted) and run the loop.
function Agent:sendPromptMessages(mcpMessages)
    for _, m in ipairs(mcpMessages) do
        local content = m.content
        local text
        if type(content) == "table" then
            text = content.text or "[non-text content]"
        else
            text = tostring(content)
        end
        table.insert(self.session.messages, {
            role = m.role or "user",
            content = text,
        })
    end
    self:run()
end

function Agent:run()
    if self.busy then return end
    self.busy = true
    self.steps = 0
    self:_step()
end

function Agent:_finish(err)
    self.busy = false
    Sessions.save(self.session)
    if self.hooks.onDone then self.hooks.onDone(err) end
end

function Agent:_step()
    self.steps += 1
    if self.steps > MAX_STEPS then
        table.insert(self.session.messages, {
            role = "assistant",
            content = "(stopped: too many tool steps)",
        })
        self:_finish(nil)
        return
    end

    self:_status("Thinking...")

    local tools = BuiltinTools.defs()
    local mcpDefs, routing = Mcp.openaiToolDefs()
    for _, d in ipairs(mcpDefs) do tools[#tools + 1] = d end
    self.routing = routing

    OpenAI.chat(self.session.messages, tools, function(message, err)
        if err ~= nil then
            self:_finish(err)
            return
        end

        -- Record the assistant turn exactly as the API expects it back.
        local assistantMsg = { role = "assistant", content = message.content }
        if message.tool_calls ~= nil then
            assistantMsg.tool_calls = message.tool_calls
        end
        table.insert(self.session.messages, assistantMsg)

        if message.tool_calls ~= nil and #message.tool_calls > 0 then
            self:_runToolCalls(message.tool_calls, 1)
        else
            self:_finish(nil)
        end
    end)
end

function Agent:_runToolCalls(calls, i)
    if i > #calls then
        self:_step() -- all tool results collected; ask the LLM again
        return
    end
    local call = calls[i]
    local fn = call["function"] or {}
    local name = fn.name or "?"
    local args = {}
    if fn.arguments ~= nil and #fn.arguments > 0 then
        args = json.decode(fn.arguments) or {}
    end

    local function record(resultText)
        table.insert(self.session.messages, {
            role = "tool",
            tool_call_id = call.id,
            content = resultText,
        })
        self:_runToolCalls(calls, i + 1)
    end

    if name == "ask_user" then
        local question = args.question or "?"
        local options = args.options or { "Yes", "No" }
        self:_status("Question for you")
        self.hooks.onAskUser(question, options, function(answer)
            record("The user chose: " .. answer)
        end)
        return
    end

    local builtin = BuiltinTools.run(name, args)
    if builtin ~= nil then
        record(builtin)
        return
    end

    local route = self.routing[name]
    if route ~= nil then
        self:_status("Tool: " .. route.tool)
        route.client:callTool(route.tool, args, function(text, isError)
            record(text)
        end)
        return
    end

    record("Error: unknown tool " .. name)
end
