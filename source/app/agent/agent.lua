-- The agent loop: send conversation to the LLM, execute tool calls
-- (built-in or MCP), feed results back, repeat until a plain reply.

Agent = {}
Agent.__index = Agent

local MAX_STEPS <const> = 8

-- session: table from Sessions.create()/Sessions.load()
-- hooks:
--   onStatus(text)                     -- progress ("Thinking...", "Tool: x")
--   onAskUser(question, options, cb)   -- show choice UI, cb(answerText)
--   onConfirm(question, cb)            -- Allow/Reject dialog, cb(true/false)
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

    OpenAI.chat(self.session.messages, tools, function(message, err, usage)
        if err ~= nil then
            self:_finish(err)
            return
        end

        if usage ~= nil then
            self.session.lastUsage = {
                prompt = usage.prompt_tokens,
                completion = usage.completion_tokens,
                total = usage.total_tokens,
            }
            self.session.totalTokens = (self.session.totalTokens or 0)
                + (usage.total_tokens or 0)
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

    if name == "add_persona" then
        local pname = args.name
        local prompt = args.prompt
        if type(pname) ~= "string" or #pname == 0
            or type(prompt) ~= "string" or #prompt == 0 then
            record("Error: add_persona needs a non-empty name and prompt.")
            return
        end
        local verb = (Config.data.personas[pname] ~= nil) and "Update" or "Add"
        local preview = prompt
        if #preview > 160 then preview = preview:sub(1, 160) .. "..." end
        self:_status("Confirm persona")
        self.hooks.onConfirm(verb .. ' persona "' .. pname .. '"?\n' .. preview,
            function(allowed)
                if allowed then
                    Config.setPersona(pname, prompt)
                    record('Persona "' .. pname .. '" saved. The user can pick '
                        .. 'it from the Persona menu; it applies to new sessions.')
                else
                    record("The user rejected the persona change.")
                end
            end)
        return
    end

    if name == "remove_persona" then
        local pname = args.name
        if type(pname) ~= "string" or Config.data.personas[pname] == nil then
            record('Error: no user-defined persona named "'
                .. tostring(pname) .. '". Use list_personas to see them.')
            return
        end
        self:_status("Confirm persona")
        self.hooks.onConfirm('Delete persona "' .. pname .. '"?',
            function(allowed)
                if allowed then
                    Config.removePersona(pname)
                    record('Persona "' .. pname .. '" deleted.')
                else
                    record("The user rejected the deletion.")
                end
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

------------------------------------------------------------------------
-- Context size tracking & compaction
------------------------------------------------------------------------

-- Fraction (0..1) of the model context used by this session, plus the token
-- count it is based on. Uses the real prompt_tokens from the last response
-- when available, otherwise a rough chars/4 estimate.
function Agent.contextFraction(session)
    local limit = Config.data.api.contextTokens or 0
    local tokens
    if session.lastUsage ~= nil and session.lastUsage.prompt ~= nil then
        tokens = session.lastUsage.prompt + (session.lastUsage.completion or 0)
    else
        local chars = 0
        for _, m in ipairs(session.messages) do
            chars += #tostring(m.content or "")
        end
        tokens = math.floor(chars / 4)
    end
    if limit <= 0 then return nil, tokens end
    return tokens / limit, tokens
end

local COMPACT_REQUEST <const> = [[
Summarize this whole conversation so far for your own future reference.
Include: what the user wanted, decisions made, important facts, names and
preferences, and anything still open. Be dense but complete; plain text.
Reply with the summary only.]]

-- Replace the transcript with { system prompt, summary, marker }.
-- cb(err) is called when done; the summary costs one extra LLM call.
function Agent:compact(cb)
    if self.busy then return end
    self.busy = true
    self:_status("Compacting session...")

    local msgs = {}
    for _, m in ipairs(self.session.messages) do msgs[#msgs + 1] = m end
    msgs[#msgs + 1] = { role = "user", content = COMPACT_REQUEST }

    OpenAI.chat(msgs, nil, function(message, err)
        self.busy = false
        if err ~= nil or message == nil or message.content == nil
            or #message.content == 0 then
            if cb then cb(err or "no summary returned") end
            return
        end
        local old = #self.session.messages
        self.session.messages = {
            self.session.messages[1], -- persona system prompt
            {
                role = "system",
                content = "Summary of the conversation so far (older "
                    .. "messages were compacted):\n" .. message.content,
            },
            {
                role = "assistant",
                content = "(session compacted: " .. old
                    .. " messages summarized)",
            },
        }
        self.session.lastUsage = nil
        Sessions.save(self.session)
        if cb then cb(nil) end
    end)
end
