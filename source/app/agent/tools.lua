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
    }
end

-- Synchronous builtin tools. ask_user is handled by the Agent (it needs UI).
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
    return nil
end
