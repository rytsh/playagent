-- Microphone recording UI: records up to N seconds of 16-bit mono audio,
-- saves it as rec.wav and hands the path to a callback.

local gfx <const> = playdate.graphics
local snd <const> = playdate.sound

MicRecorder = {}
MicRecorder.__index = MicRecorder

local WAV_PATH <const> = "rec.wav"

-- callback(wavPath or nil, err)
function MicRecorder.new(callback)
    local self = setmetatable({}, MicRecorder)
    self.callback = callback
    self.state = "starting"
    self.startedAt = nil
    return self
end

function MicRecorder:start()
    local seconds = Config.data.stt.maxSeconds or 15
    self.buffer = snd.sample.new(seconds, snd.kFormat16bitMono)
    snd.micinput.startListening()
    local ok = snd.micinput.recordToSample(self.buffer, function(sample)
        snd.micinput.stopListening()
        if self.state == "cancelled" then
            self.callback(nil, nil)
            return
        end
        self.state = "saving"
        sample:save(WAV_PATH)
        self.callback(WAV_PATH, nil)
    end, "PlayAgent records your voice to convert it to text.")
    if not ok then
        self.state = "error"
        self.callback(nil, "could not start recording")
        return
    end
    self.state = "recording"
    self.startedAt = playdate.getCurrentTimeMilliseconds()
end

-- Returns true while still active.
function MicRecorder:update()
    if self.state == "starting" then
        -- recordToSample may show a permission dialog (yields), so start from
        -- the update loop, once.
        self:start()
        return true
    end
    if self.state ~= "recording" then
        return self.state == "saving"
    end

    local font = AppFont
    local elapsed = (playdate.getCurrentTimeMilliseconds() - self.startedAt) / 1000
    local level = snd.micinput.getLevel()

    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(60, 70, 280, 100, 6)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRoundRect(60, 70, 280, 100, 6)
    font:drawText("Recording...  " .. string.format("%.1fs", elapsed), 76, 82)
    -- level meter
    gfx.drawRect(76, 110, 248, 14)
    gfx.fillRect(78, 112, math.floor(244 * math.min(level * 3, 1)), 10)
    font:drawText("A: send   B: cancel", 76, 138)

    if playdate.buttonJustPressed(playdate.kButtonA) then
        snd.micinput.stopRecording() -- completion callback fires immediately
        return true
    end
    if playdate.buttonJustPressed(playdate.kButtonB) then
        self.state = "cancelled"
        snd.micinput.stopRecording()
        return false
    end
    return true
end
