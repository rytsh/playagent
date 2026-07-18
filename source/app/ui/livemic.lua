-- Live dictation: near-real-time speech-to-text.
--
-- The Playdate Lua mic API can only record into a fixed sample buffer, and
-- HTTP requests need the whole body up front, so true word-level streaming
-- is impossible. Instead speech is cut into small chunks (at pauses, or at
-- a hard limit when the buffer fills), each chunk is uploaded to the
-- Whisper endpoint in the background while recording continues, and the
-- transcript accumulates on screen while you talk.
--
-- Contract (modal, like MicRecorder):
--   LiveMic.new(function(text, err) ... end)
--   :update() -> true while active
--   text is the full accumulated transcript (nil if cancelled/empty).

local gfx <const> = playdate.graphics
local snd <const> = playdate.sound

LiveMic = {}
LiveMic.__index = LiveMic

local SLOTS <const> = 8               -- rotating temp wav files
local MAX_TOTAL_MS <const> = 5 * 60 * 1000
local MIC_REASON <const> = "PlayAgent records your voice to convert it to text."

local function now()
    return playdate.getCurrentTimeMilliseconds()
end

function LiveMic.new(callback)
    local self = setmetatable({}, LiveMic)
    self.callback = callback
    self.state = "starting" -- starting/recording/finishing/done/cancelled/error
    self.text = ""
    self.queue = {}         -- { path, tries }, FIFO
    self.inFlight = false
    self.recording = false
    self.wantRestart = false
    self.finished = false   -- callback fired
    self.slot = 0
    self.bufIndex = 2
    self.buffers = nil
    self.notice = nil       -- transient error line
    return self
end

function LiveMic:_fire(text, err)
    if self.finished then return end
    self.finished = true
    self.callback(text, err)
end

------------------------------------------------------------------------
-- Recording chunks
------------------------------------------------------------------------

function LiveMic:_startChunk()
    local cfg = Config.data.stt
    if self.buffers == nil then
        local secs = cfg.chunkSeconds or 3
        self.buffers = {
            snd.sample.new(secs, snd.kFormat16bitMono),
            snd.sample.new(secs, snd.kFormat16bitMono),
        }
    end
    self.bufIndex = (self.bufIndex == 1) and 2 or 1
    self.chunkStart = now()
    self.silenceSince = nil
    self.hadSpeech = false
    local ok = snd.micinput.recordToSample(self.buffers[self.bufIndex],
        function(sample)
            self:_chunkDone(sample)
        end, MIC_REASON)
    if not ok then
        self.state = "error"
        snd.micinput.stopListening()
        self:_fire(nil, "could not start recording")
        return
    end
    self.recording = true
end

-- Completion of one chunk: fires on silence cut (stopRecording), on a full
-- buffer (hard limit) and on finish/cancel.
function LiveMic:_chunkDone(sample)
    self.recording = false
    local had = self.hadSpeech

    if self.state == "cancelled" then
        snd.micinput.stopListening()
        self:_fire(nil, nil)
        return
    end

    if self.state == "recording" then
        -- restart from the next update() frame (keeps the mic callback slim)
        self.wantRestart = true
    end

    if had and sample ~= nil and (sample:getLength() or 0) > 0.3 then
        self.slot = (self.slot % SLOTS) + 1
        local path = "live_" .. self.slot .. ".wav"
        -- paranoid: drop a stale queue entry that still points at this slot
        for i, q in ipairs(self.queue) do
            if q.path == path then
                table.remove(self.queue, i)
                break
            end
        end
        sample:save(path)
        self.queue[#self.queue + 1] = { path = path, tries = 0 }
        self:_pump()
    end

    if self.state == "finishing" then
        snd.micinput.stopListening()
        self:_maybeFinish()
    end
end

------------------------------------------------------------------------
-- Upload queue (one request in flight, strict order)
------------------------------------------------------------------------

function LiveMic:_pump()
    if self.inFlight or self.state == "cancelled" then return end
    local item = self.queue[1]
    if item == nil then
        self:_maybeFinish()
        return
    end
    self.inFlight = true
    -- pass the transcript tail as context so chunks join up cleanly
    local ctx = self.text
    if #ctx > 200 then ctx = ctx:sub(-200) end
    STT.transcribe(item.path, function(text, err)
        self.inFlight = false
        if self.state == "cancelled" then return end
        if err ~= nil then
            item.tries += 1
            if item.tries < 2 then
                self:_pump() -- one retry
                return
            end
            table.remove(self.queue, 1)
            playdate.file.delete(item.path)
            self.notice = "STT: " .. tostring(err)
        else
            table.remove(self.queue, 1)
            playdate.file.delete(item.path)
            if text ~= nil then
                text = text:gsub("^%s+", ""):gsub("%s+$", "")
                if #text > 0 then
                    self.text = (#self.text > 0)
                        and (self.text .. " " .. text) or text
                end
            end
        end
        self:_pump()
    end, ctx)
end

function LiveMic:_maybeFinish()
    if self.state ~= "finishing" then return end
    if self.recording or self.inFlight or #self.queue > 0 then return end
    self.state = "done"
    if #self.text > 0 then
        self:_fire(self.text, nil)
    else
        self:_fire(nil, nil)
    end
end

------------------------------------------------------------------------
-- User actions
------------------------------------------------------------------------

function LiveMic:_finishRequested()
    if self.state ~= "recording" then return end
    self.state = "finishing"
    if self.recording then
        snd.micinput.stopRecording() -- _chunkDone flushes + finishes
    else
        snd.micinput.stopListening()
        self:_maybeFinish()
    end
end

function LiveMic:_cancel()
    if self.state ~= "recording" and self.state ~= "finishing" then return end
    local wasRecording = self.recording
    self.state = "cancelled"
    self.queue = {}
    if wasRecording then
        snd.micinput.stopRecording() -- _chunkDone fires the callback
    else
        snd.micinput.stopListening()
        self:_fire(nil, nil)
    end
end

------------------------------------------------------------------------
-- Modal update / drawing
------------------------------------------------------------------------

local BOX_X <const> = 28
local BOX_Y <const> = 36
local BOX_W <const> = 344
local BOX_H <const> = 168
local PAD <const> = 12
local MAX_LINES <const> = 5

function LiveMic:update()
    if self.state == "starting" then
        -- may show the mic permission dialog -> must run from update()
        snd.micinput.startListening()
        self.state = "recording"
        self.startedAt = now()
        self:_startChunk()
        return true
    end
    if self.state == "done" or self.state == "cancelled"
        or self.state == "error" then
        return false
    end

    if self.wantRestart and self.state == "recording" then
        self.wantRestart = false
        self:_startChunk()
    end

    local cfg = Config.data.stt
    local t = now()

    -- silence-boundary chunk cutting
    if self.recording and self.state == "recording" then
        local level = snd.micinput.getLevel()
        if level >= (cfg.levelThreshold or 0.02) then
            self.hadSpeech = true
            self.silenceSince = nil
        elseif self.silenceSince == nil then
            self.silenceSince = t
        end
        if self.hadSpeech
            and (t - self.chunkStart) >= (cfg.minChunkSeconds or 1.2) * 1000
            and self.silenceSince ~= nil
            and (t - self.silenceSince) >= (cfg.silenceMs or 350) then
            snd.micinput.stopRecording() -- flush chunk; restart next frame
        end
        if (t - self.startedAt) > MAX_TOTAL_MS then
            self:_finishRequested()
        end
    end

    -- drawing
    local font = AppFont
    local lineH = font:getHeight() + 2
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(BOX_X, BOX_Y, BOX_W, BOX_H, 6)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRoundRect(BOX_X, BOX_Y, BOX_W, BOX_H, 6)

    local elapsed = (t - (self.startedAt or t)) / 1000
    local title = (self.state == "finishing") and "Finishing..."
        or string.format("Dictating...  %.0fs", elapsed)
    AppFontBold:drawText(title, BOX_X + PAD, BOX_Y + 8)

    -- level meter
    local meterY = BOX_Y + 28
    local level = self.recording and snd.micinput.getLevel() or 0
    gfx.drawRect(BOX_X + PAD, meterY, BOX_W - PAD * 2, 10)
    gfx.fillRect(BOX_X + PAD + 2, meterY + 2,
        math.floor((BOX_W - PAD * 2 - 4) * math.min(level * 3, 1)), 6)

    -- accumulated transcript (last few lines), "..." while chunks pending
    local shown = self.text
    local pending = #self.queue + (self.inFlight and 1 or 0)
    if pending > 0 then
        shown = (#shown > 0) and (shown .. " ...") or "..."
    elseif #shown == 0 then
        shown = "(speak; pause briefly to flush a chunk)"
    end
    local lines = TextWrap.wrap(font, shown, BOX_W - PAD * 2)
    local first = math.max(1, #lines - MAX_LINES + 1)
    local ty = meterY + 16
    for i = first, #lines do
        font:drawText(lines[i], BOX_X + PAD, ty)
        ty += lineH
    end

    if self.notice ~= nil then
        font:drawText(TextWrap.truncate(font, self.notice, BOX_W - PAD * 2),
            BOX_X + PAD, BOX_Y + BOX_H - 34)
    end
    local hint = (self.state == "finishing")
        and "B: cancel" or "A: send   B: cancel"
    font:drawText(hint, BOX_X + PAD, BOX_Y + BOX_H - 18)

    -- input
    if playdate.buttonJustPressed(playdate.kButtonA) then
        self:_finishRequested()
    elseif playdate.buttonJustPressed(playdate.kButtonB) then
        self:_cancel()
        return false
    end
    return true
end
