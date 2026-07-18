-- PlayAgent: an LLM agent for Playdate
-- OpenAI-compatible chat, remote MCP tools & prompts, speech-to-text.

import "CoreLibs/object"
import "CoreLibs/graphics"
import "CoreLibs/timer"
import "CoreLibs/crank"
import "CoreLibs/keyboard"

import "app/config"
import "app/ui/emoji"
import "app/ui/wrap"
import "app/ui/markdown"
import "app/ui/list"
import "app/ui/choice"
import "app/ui/textinput"
import "app/ui/mic"
import "app/ui/livemic"
import "app/ui/chatview"
import "app/net/http"
import "app/net/base64"
import "app/net/openai"
import "app/net/stt"
import "app/net/mcp"
import "app/net/opencode"
import "app/net/ocevents"
import "app/agent/personas"
import "app/agent/session"
import "app/agent/tools"
import "app/agent/agent"
import "app/scenes"
import "app/scenes_remote"

local gfx <const> = playdate.graphics

AppFont = gfx.font.new("fonts/PlayAgent-Regular")
AppFontBold = gfx.font.new("fonts/PlayAgent-Bold")
gfx.setFont(AppFont)

Config.load()

playdate.display.setRefreshRate(30)
gfx.setBackgroundColor(gfx.kColorWhite)

Scenes.push(HomeScene.new())

function playdate.update()
    Http.ensureAccess() -- one-time permission dialog, must run from update()
    gfx.clear(gfx.kColorWhite)
    Scenes.update()
    playdate.timer.updateTimers()
end

function playdate.gameWillTerminate()
    Config.save()
    Scenes.saveAll()
end

function playdate.gameWillSleep()
    Config.save()
    Scenes.saveAll()
end
