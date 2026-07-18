-- Sound effects: preset effects + a tiny note sequencer, built on
-- playdate.sound.synth. Used by the play_sound builtin tool and Buddy mode.
--
-- A "step" is { wave, pitch, dur, vol, gap, adsr }:
--   wave  "sine"|"square"|"triangle"|"saw"|"noise"  (default "square")
--   pitch frequency in Hz, or nil for a rest
--   dur   note length in ms (default 150)
--   vol   0..1 (default 0.6)
--   gap   extra silence after the note in ms (default 0)
--   adsr  optional { a, d, s, r } envelope override (seconds)

local snd <const> = playdate.sound

Sfx = { seq = 0 }

local WAVES <const> = {
    sine = snd.kWaveSine,
    square = snd.kWaveSquare,
    triangle = snd.kWaveTriangle,
    saw = snd.kWaveSawtooth,
    noise = snd.kWaveNoise,
}

local synths = {} -- wave name -> synth (monophonic, reused)

local function getSynth(wave)
    local w = WAVES[wave] and wave or "square"
    if synths[w] == nil then
        synths[w] = snd.synth.new(WAVES[w])
    end
    return synths[w]
end

-- Play a list of steps sequentially. A later call cancels the tail of any
-- sequence still playing.
function Sfx.play(steps)
    Sfx.seq += 1
    local id = Sfx.seq
    local i = 1
    local function nextStep()
        if id ~= Sfx.seq then return end
        local s = steps[i]
        if s == nil then return end
        i += 1
        local dur = s.dur or 150
        if s.pitch ~= nil then
            local synth = getSynth(s.wave)
            local a = s.adsr or { 0.005, 0.05, 0.5, 0.05 }
            synth:setADSR(a[1], a[2], a[3], a[4])
            synth:playNote(s.pitch, s.vol or 0.6, dur / 1000)
        end
        playdate.timer.performAfterDelay(dur + (s.gap or 0), nextStep)
    end
    nextStep()
end

function Sfx.stop()
    Sfx.seq += 1
    for _, synth in pairs(synths) do
        synth:noteOff()
    end
end

------------------------------------------------------------------------
-- Note parsing:  "C4:120, E4:120, G#4:240, R:100, Bb3:300"
------------------------------------------------------------------------

local SEMITONE <const> = {
    C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11,
}

-- "C#4" / "Db3" / "A5" -> frequency in Hz, or nil.
local function noteFreq(name)
    local letter, accidental, octave =
        name:match("^([A-Ga-g])([#b]?)(%-?%d)$")
    if letter == nil then return nil end
    local semi = SEMITONE[letter:upper()]
    if accidental == "#" then semi += 1
    elseif accidental == "b" then semi -= 1 end
    local midi = (tonumber(octave) + 1) * 12 + semi
    return 440 * 2 ^ ((midi - 69) / 12)
end

local MAX_STEPS <const> = 48
local MAX_NOTE_MS <const> = 2000

-- Parse "NOTE:ms" pairs into steps. Returns steps, err.
function Sfx.parseNotes(text, wave, vol)
    local steps = {}
    for token in tostring(text):gmatch("[^,%s]+") do
        if #steps >= MAX_STEPS then break end
        local name, ms = token:match("^([^:]+):?(%d*)$")
        if name == nil then
            return nil, "bad token: " .. token
        end
        local dur = math.min(tonumber(ms) or 150, MAX_NOTE_MS)
        if name:upper() == "R" then
            steps[#steps + 1] = { dur = dur } -- rest
        else
            local freq = noteFreq(name)
            if freq == nil then
                return nil, "bad note: " .. token
                    .. " (use e.g. C4:120, G#3:200, R:100)"
            end
            steps[#steps + 1] = {
                wave = wave, pitch = freq, dur = dur, vol = vol, gap = 10,
            }
        end
    end
    if #steps == 0 then return nil, "no notes found" end
    return steps, nil
end

function Sfx.playNotes(text, wave, vol)
    local steps, err = Sfx.parseNotes(text, wave, vol)
    if steps == nil then return err end
    Sfx.play(steps)
    return nil
end

------------------------------------------------------------------------
-- Presets
------------------------------------------------------------------------

local BARK_ADSR <const> = { 0, 0.06, 0, 0.03 }

local PRESETS <const> = {
    beep = {
        { wave = "square", pitch = 880, dur = 120 },
    },
    happy = {
        { wave = "square", pitch = 523, dur = 90 },
        { wave = "square", pitch = 659, dur = 90 },
        { wave = "square", pitch = 784, dur = 180 },
    },
    sad = {
        { wave = "triangle", pitch = 330, dur = 220 },
        { wave = "triangle", pitch = 262, dur = 220 },
        { wave = "triangle", pitch = 220, dur = 380,
            adsr = { 0.01, 0.1, 0.4, 0.3 } },
    },
    alarm = {
        { wave = "square", pitch = 880, dur = 130 },
        { wave = "square", pitch = 660, dur = 130 },
        { wave = "square", pitch = 880, dur = 130 },
        { wave = "square", pitch = 660, dur = 130 },
    },
    coin = {
        { wave = "square", pitch = 988, dur = 80 },
        { wave = "square", pitch = 1319, dur = 240,
            adsr = { 0, 0.05, 0.5, 0.15 } },
    },
    laser = {
        { wave = "saw", pitch = 2093, dur = 30 },
        { wave = "saw", pitch = 1568, dur = 30 },
        { wave = "saw", pitch = 1047, dur = 30 },
        { wave = "saw", pitch = 784, dur = 50 },
    },
    error = {
        { wave = "square", pitch = 110, dur = 160, gap = 40 },
        { wave = "square", pitch = 110, dur = 220 },
    },
    -- Animal sounds (also used by Buddy mode)
    bark = {
        { wave = "noise", pitch = 110, dur = 90, vol = 1, gap = 70,
            adsr = BARK_ADSR },
        { wave = "noise", pitch = 90, dur = 110, vol = 1,
            adsr = BARK_ADSR },
    },
    meow = {
        { wave = "triangle", pitch = 440, dur = 140, vol = 0.7 },
        { wave = "triangle", pitch = 659, dur = 220, vol = 0.7 },
        { wave = "triangle", pitch = 523, dur = 320, vol = 0.6,
            adsr = { 0.02, 0.1, 0.5, 0.25 } },
    },
    purr = {
        { wave = "noise", pitch = 36, dur = 90, vol = 0.5, gap = 50 },
        { wave = "noise", pitch = 36, dur = 90, vol = 0.5, gap = 50 },
        { wave = "noise", pitch = 36, dur = 90, vol = 0.5, gap = 50 },
        { wave = "noise", pitch = 36, dur = 90, vol = 0.5 },
    },
    chirp = {
        { wave = "sine", pitch = 2637, dur = 45, gap = 30 },
        { wave = "sine", pitch = 3136, dur = 45, gap = 70 },
        { wave = "sine", pitch = 2093, dur = 55 },
    },
    thwip = {
        { wave = "saw", pitch = 1568, dur = 30 },
        { wave = "saw", pitch = 1047, dur = 30 },
        { wave = "saw", pitch = 698, dur = 45, gap = 60 },
        { wave = "square", pitch = 262, dur = 60, vol = 0.8,
            adsr = BARK_ADSR },
    },
}

function Sfx.preset(name)
    local steps = PRESETS[name]
    if steps == nil then return false end
    Sfx.play(steps)
    return true
end

function Sfx.presetNames()
    local names = {}
    for name in pairs(PRESETS) do names[#names + 1] = name end
    table.sort(names)
    return names
end
