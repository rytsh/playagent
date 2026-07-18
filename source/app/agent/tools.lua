-- Built-in tools exposed to the LLM (in addition to MCP tools).
--
-- ask_user is the Playdate equivalent of opencode's "asking": the model can
-- pose a question with a small set of options and the user answers with the
-- d-pad + A button.

BuiltinTools = {}

function BuiltinTools.defs()
    return {
        {
            type = "function",
            ["function"] = {
                name = "ask_user",
                description = "Ask the user a question with a small set of "
                    .. "choices. The user picks one with the d-pad. Use this "
                    .. "whenever you need a decision or preference from the "
                    .. "user. Keep the question and options short (they are "
                    .. "shown on a 400x240 screen).",
                parameters = {
                    type = "object",
                    properties = {
                        question = {
                            type = "string",
                            description = "The question to show the user.",
                        },
                        options = {
                            type = "array",
                            items = { type = "string" },
                            description = "2 to 5 short answer options.",
                        },
                    },
                    required = { "question", "options" },
                },
            },
        },
        {
            type = "function",
            ["function"] = {
                name = "device_status",
                description = "Get the Playdate device status: battery level, "
                    .. "local time and current crank position.",
                parameters = { type = "object", properties = {} },
            },
        },
        {
            type = "function",
            ["function"] = {
                name = "play_sound",
                description = "Play a sound on the Playdate speaker. Either "
                    .. "pick a preset effect OR compose a short melody with "
                    .. "notes. Use it for fun, feedback or emphasis; at most "
                    .. "one sound per reply.",
                parameters = {
                    type = "object",
                    properties = {
                        preset = {
                            type = "string",
                            enum = Sfx.presetNames(),
                            description = "A preset effect to play.",
                        },
                        notes = {
                            type = "string",
                            description = "Melody as comma-separated "
                                .. "NOTE:milliseconds pairs, e.g. "
                                .. "\"C4:120,E4:120,G#4:240,R:100,C5:400\". "
                                .. "R is a rest. Octaves 2-7 sound best. "
                                .. "Ignored if preset is given.",
                        },
                        wave = {
                            type = "string",
                            enum = { "sine", "square", "triangle", "saw",
                                "noise" },
                            description = "Waveform for notes "
                                .. "(default square).",
                        },
                        volume = {
                            type = "number",
                            description = "0.0 to 1.0 (default 0.6).",
                        },
                    },
                },
            },
        },
        {
            type = "function",
            ["function"] = {
                name = "list_personas",
                description = "List the personas the agent can play: the "
                    .. "built-in ones and the user-defined ones stored on "
                    .. "this device.",
                parameters = { type = "object", properties = {} },
            },
        },
        {
            type = "function",
            ["function"] = {
                name = "add_persona",
                description = "Create or update a user-defined persona on "
                    .. "this device. The user must confirm the change on "
                    .. "screen before it is saved. Keep the prompt short "
                    .. "(a few sentences).",
                parameters = {
                    type = "object",
                    properties = {
                        name = {
                            type = "string",
                            description = "Short persona name (shown in menus).",
                        },
                        prompt = {
                            type = "string",
                            description = "The persona's system prompt.",
                        },
                    },
                    required = { "name", "prompt" },
                },
            },
        },
        {
            type = "function",
            ["function"] = {
                name = "remove_persona",
                description = "Delete a user-defined persona from this "
                    .. "device. Built-in personas cannot be removed. The "
                    .. "user must confirm the deletion on screen.",
                parameters = {
                    type = "object",
                    properties = {
                        name = {
                            type = "string",
                            description = "Name of the persona to delete.",
                        },
                    },
                    required = { "name" },
                },
            },
        },
    }
end

-- Synchronous builtin tools. ask_user, add_persona and remove_persona are
-- handled by the Agent (they need UI).
function BuiltinTools.run(name, args)
    if name == "device_status" then
        local t = playdate.getTime()
        return json.encode({
            battery_percent = playdate.getBatteryPercentage(),
            time = string.format("%04d-%02d-%02d %02d:%02d:%02d",
                t.year, t.month, t.day, t.hour, t.minute, t.second),
            crank_position_degrees = playdate.getCrankPosition(),
            crank_docked = playdate.isCrankDocked(),
        })
    end
    if name == "play_sound" then
        local vol = tonumber(args.volume)
        if vol ~= nil then vol = math.max(0, math.min(1, vol)) end
        if args.preset ~= nil and #tostring(args.preset) > 0 then
            if Sfx.preset(args.preset) then
                return json.encode({ played = args.preset })
            end
            return "Error: unknown preset \"" .. tostring(args.preset)
                .. "\". Available: "
                .. table.concat(Sfx.presetNames(), ", ")
        end
        if args.notes ~= nil and #tostring(args.notes) > 0 then
            local err = Sfx.playNotes(args.notes, args.wave, vol)
            if err ~= nil then return "Error: " .. err end
            return json.encode({ played = "notes" })
        end
        return "Error: give either preset or notes."
    end
    if name == "list_personas" then
        local builtin = {}
        for _, p in ipairs(Personas.list) do
            builtin[#builtin + 1] = p.name
        end
        return json.encode({
            builtin = builtin,
            user_defined = Personas.userNames(),
            active = Personas.byId(Config.data.personaId).name,
        })
    end
    return nil
end
