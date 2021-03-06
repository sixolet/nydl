-- nydl
-- unversioned; @sixolet
--
-- Clocked looper, beat slicer, and sequencer
--
-- E1: Select track
-- K2: Monitor/Record
-- E2: Select function for K3/E3
--

tab = require 'tabutil'


engine.name = 'NotYourDreamLooper'

g = grid.connect()

-- Brightnesses
OFF = 0
BACKGROUND = 1
IN_LOOP = 3
IN_LOOP_SECTION = 2
INACTIVE = 6
INTERESTING = 12
SELECTED = 11
ACTIVE = 15

-- Modes
-- MODE_SOUND = 1
MODE_SEQUENCE = 1
MODE_CUE = 2

-- Record states
RECORD_PLAYING = 1
RECORD_MONITORING = 2
RECORD_ARMED = 3
RECORD_RECORDING = 4
RECORD_SOS = 5
RECORD_RESAMPLING = 6

-- Cue-mode time selection
TIME_QTR = 1
TIME_8TH = 2
TIME_16TH = 3

-- Loop length/division paramters

DIV_16TH = 1
DIV_8TH = 2
DIV_QTR = 3

DIV_OPTIONS = { "4 bars of 16th", "8 bars of 8th", "16 bars of quarter"}
DIV_VALUES = { 0.25, 0.5, 1 }

-- Crow output modes
CROW_MODES = {"unassigned", "track 1 loop", "track 2 loop", "track 3 loop", "track 4 loop", 
  "beat", "eighth note", "eighth triplet", "sixteenth note"}
CROW_BEAT_DIVISIONS = {nil, nil, nil, nil, nil, 1, 2, 3, 4}
CROW_LOOP_TRACKS = {nil, 1, 2, 3, 4}

CROW_UNASSIGNED = 1
CROW_TRACK1_LOOP = 2
CROW_TRACK2_LOOP = 3
CROW_TRACK3_LOOP = 4
CROW_TRACK4_LOOP = 5
CROW_BEAT = 6
CROW_EIGHTH = 7
CROW_TRIPLET = 8
CROW_SIXTEENTH = 9
--CROW_12PPQN = 10
--CROW_24PPQN = 11
--CROW_48PPQN = 12

EK3_LEVEL = 1 -- mute, level
EK3_LOOP = 2 -- {64 steps, 32 steps, 16 steps, 8 steps, 4 steps, 2 steps, 1 step} when pressed {left/right} when not pressed
EK3_RESET = 3 -- reset all, no enc meaning
EK3_FX1 = 4
EK3_FX2 = 5
EK3_FX3 = 6
EK3_CLEAR = 7

EK3_OPTIONS = {"level", "loop", "reset", "fx1", "fx2", "fx3", "clear"}

k3_pressed = false

-- Global script data
transport = true
sequence = { {}, {}, {}, {} }
amplitudes = { {}, {}, {}, {} }
pattern_buffer = nil
playheads = {}

seq_step_selections = {nil, nil, nil, nil}
seq_section_selections = {nil, nil, nil, nil}
cue_step_selections = {nil, nil, nil, nil}
cue_section_selections = {nil, nil, nil, nil}
step_selections = seq_step_selections
section_selections = seq_section_selections

seq_record_states = {1, 1, 1, 1}
cue_record_states = {1, 1, 1, 1}
record_states = seq_record_states
record_timers = {nil, nil, nil, nil} -- for judging longpress

was_cued = {false, false, false, false}
select_held = false
froze = false
cue_mode_time = TIME_QTR
mode = MODE_SEQUENCE

cached_tempo = nil
pressed_loop_len = 0

tracks_written = 0

-- Screen interface globals
screen_track = 1
drain = 0

function apply_rate(rate, track, sel)
  if sel == nil then return end
  local seq = sequence[track]
  local landmark = seq[sel.first].buf_pos
  local distance = 0
  for i=sel.first,sel.last,1 do
    seq[i].rate = rate
    seq[i].lock_rate = false
    if seq[i].lock_pos then
      landmark = seq[i].buf_pos
      distance = 0
    else
      seq[i].buf_pos = landmark + (rate * distance)
      distance = distance + 1
    end
  end
  seq[sel.first].lock_rate = true
  
  if sel.last < 64 then
    seq[sel.last + 1].lock_rate = true
    seq[sel.last + 1].lock_pos = true
  end 
  
end

function apply_stutter(div, track, sel)
  if sel == nil then return end
  local seq = sequence[track]
  local pos = seq[sel.first].buf_pos
  local rate = seq[sel.first].rate
  local numerator = sel.last - sel.first + 1
  for i=sel.first,sel.last,1 do
    seq[i].buf_pos = pos
    seq[i].rate = rate
    seq[i].subdivision = numerator/div
    seq[i].lock_pos = false
    seq[i].lock_rate = false
    seq[i].lock_subdivision = false
  end
  seq[sel.first].lock_pos = true
  seq[sel.first].lock_rate = true
  seq[sel.first].lock_subdivision = true
  if sel.last < 64 then
    seq[sel.last + 1].lock_subdivision = true
  end
end

function apply_fx(idx, track, sel)
  if sel == nil then return end
  -- print("track", track)
  -- tab.print(sel)
  local seq = sequence[track]
  local attr = "fx_"..idx.."_level"
  local global_level = params:get(pn("fx"..idx.."_level", track))
  local global_on = params:get(pn("fx"..idx.."_on", track)) > 0
  for i=sel.first,sel.last,1 do
    seq[i][attr] = (global_on and 0 or global_level)
  end
end

function cue_fx(idx, track, z)
  local global_level = params:get(pn("fx"..idx.."_level", track))
  local global_on = params:get(pn("fx"..idx.."_on", track)) > 0
  local pos = rounded_seq_pos(track)
  local attr = "fx_"..idx.."_level"
  local level
  if (z == 1) == global_on then
    engine.setFx(track, idx, "level", 0)
    level = 0
  else
    engine.setFx(track, idx, "level", global_level)
    level = global_level
  end
  if z == 1 and cue_record_states[track] == RECORD_RECORDING then
    -- print('pos', pos)
    -- print(sequence)
    -- print(sequence[track])
    -- print(sequence[track][pos])
    sequence[track][pos][attr] = level
  end
end

function cue_rate(rate, track)
  -- print("cue rate", rate, track)
  engine.setSynth(track, "rate", rate)
  
  if cue_record_states[track] == RECORD_RECORDING then
    local seq_pos = rounded_seq_pos(track)
    sequence[track][seq_pos].rate = rate
    sequence[track][seq_pos].lock_rate = true
    sequence[track][seq_pos].rate_cued = true
  end
end

function press_stutter(division, track)
  local pos = rounded_actual_pos(track)
  local sel = step_selections[track]
  if sel ~= nil then
    pos = sel.first
  end
  local loop_len = pressed_loop_len > 0 and pressed_loop_len or 4/math.pow(2, cue_mode_time - 1)
  loop_len  = loop_len/division
  print("press stutter", track, pos, playheads[track].actual_rate, loop_len)
  engine.playStep(track, pos, playheads[track].actual_rate, loop_len)
  if cue_record_states[track] == RECORD_RECORDING then
    local seq_pos = rounded_seq_pos(track)
    sequence[track][seq_pos].subdivision = loop_len
    sequence[track][seq_pos].buf_pos = pos
    sequence[track][seq_pos].lock_loop = true
    sequence[track][seq_pos].lock_pos = true
    sequence[track][seq_pos].pos_cued = true
    sequence[track][seq_pos].loop_cued = true
  end  
end

function release_stutter(track)
  print("release stutter")
  engine.setSynth(track, 'loop', pressed_loop_len)
  
  local pos = rounded_actual_pos(track)
  if cue_record_states[track] == RECORD_RECORDING then
    local seq_pos = rounded_seq_pos(track)
    sequence[track][seq_pos].subdivision = pressed_loop_len
    sequence[track][seq_pos].buf_pos = pos
    sequence[track][seq_pos].lock_loop = true
    sequence[track][seq_pos].lock_pos = true
    sequence[track][seq_pos].pos_cued = true
    sequence[track][seq_pos].loop_cued = true
  end  
  
end

function sign(x)
  if x == 0 then
    return 0
  end
  return math.abs(x)/x
end
-- Tools
tools = {
  
  stall = {
    x = 2,
    y = 2,
    modes =  {MODE_SEQUENCE, MODE_CUE},
    apply = function(track, sel)
      if mode == MODE_SEQUENCE then
        local seq = sequence[track]
        if sel == nil then return end
        
        seq[sel.first].stall = sel.last - sel.first + 1

        if sel.last < 64 then
          seq[sel.last + 1].lock_pos = true
          seq[sel.last + 1].lock_rate = true
        end     
      end
    end,
    onPress = function (track)
      local stall_len = pressed_loop_len > 0 and pressed_loop_len or 4/math.pow(2, cue_mode_time - 1)
      engine.setSynth(track, "rateLag", stall_len)
      engine.setSynth(track, "rate", 0)
      if cue_record_states[track] == RECORD_RECORDING then
        local seq_pos = rounded_seq_pos(track)
        sequence[track][seq_pos].stall = stall_len
      end
    end,
  },
  
  fx1 = {
    x = 1,
    y = 3,
    modes =  {MODE_SEQUENCE, MODE_CUE},
    apply = function (track, sel)
      apply_fx(1, track, sel)
    end,
    onPress = function (track)
      cue_fx(1, track, 1)
    end,
    onReleaseAlways = function (track)
      cue_fx(1, track, 0)
    end,      
  },

  fx2 = {
    x = 2,
    y = 3,
    modes =  {MODE_SEQUENCE, MODE_CUE},
    apply = function (track, sel)
      apply_fx(2, track, sel)
    end,
    onPress = function (track)
      cue_fx(2, track, 1)
    end,
    onReleaseAlways = function (track)
      cue_fx(2, track, 0)
    end,      
  },

  fx3 = {
    x = 3,
    y = 3,
    modes =  {MODE_SEQUENCE, MODE_CUE},
    apply = function (track, sel)
      apply_fx(3, track, sel)
    end,
    onPress = function (track)
      cue_fx(3, track, 1)
    end,
    onReleaseAlways = function (track)
      cue_fx(3, track, 0)
    end,  
  },
  
  slow = {
    x = 1,
    y = 4,
    modes = {MODE_SEQUENCE, MODE_CUE},
    apply = function (track, sel)
      apply_rate(0.5, track, sel)
    end,
    onPress = function (track)
      engine.setSynth(track, "rate", 0.5)
    end,
    onRelease = function (track)
      if tools.fast.pressed then
        engine.setSynth(track, "rate", 2)
      else
        engine.setSynth(track, "rate", 1)
      end
    end,    
  },

  fast = {
    x = 3,
    y = 4,
    modes = {MODE_SEQUENCE, MODE_CUE},
    apply = function (track, sel)
      apply_rate(2.0, track, sel)
    end,
    onPress = function (track)
      cue_rate(2, track)
    end,
    onRelease = function (track)
      if tools.slow.pressed then
        cue_rate(0.5, track)
      else
        cue_rate(1, track)
      end
    end,        
  },
  
  normal = {
    x = 2,
    y = 7,
    pressed = false,
    modes = {MODE_CUE},
  },
  
  loop = {
    x = 3,
    y = 8,
    pressed = false,
    modes = {MODE_SEQUENCE},
    apply = function (track, sel)
      if sel ~= nil then
        sequence[track].rectangle = nil
        local ph = playheads[track]
        local offset = ph.seq_pos - ph.loop_start
        -- print("looping", track, sel.first, sel.last)
        params:set(pn("start", track), sel.first)
        params:set(pn("end", track), sel.last)        
        --ph.loop_start = sel.first
        --ph.loop_end = sel.last
        if ph.seq_pos > ph.loop_end or ph.seq_pos < ph.loop_start then
          ph.teleport = true
          ph.seq_pos = ph.loop_start + (offset % (ph.loop_end - ph.loop_start + 1))
        end
      end
    end,
  },
  stutter2 = {
    x = 1,
    y = 5,
    pressed = false,
    modes = {MODE_SEQUENCE, MODE_CUE},
    apply = function(track, sel)
      apply_stutter(2, track, sel)
    end,
    onPress = function(track)
      press_stutter(2, track)
    end,
    onRelease = release_stutter,
  },
  stutter3 = {
    x = 2,
    y = 5,
    pressed = false,
    modes = {MODE_SEQUENCE, MODE_CUE},
    apply = function(track, sel)
      apply_stutter(3, track, sel)
    end,
    onPress = function(track)
      press_stutter(3, track)
    end,
    onRelease = release_stutter,    
  },
  stutter4 = {
    x = 3,
    y = 5,
    pressed = false,
    modes = {MODE_SEQUENCE, MODE_CUE},
    apply = function(track, sel)
      apply_stutter(4, track, sel)
    end,
    onPress = function(track)
      press_stutter(4, track)
    end, 
    onRelease = release_stutter,    
  },
  reverse = {
    x = 2,
    y = 6,
    pressed = false,
    modes = {MODE_SEQUENCE, MODE_CUE},
    apply = function(track, sel)
      if mode == MODE_SEQUENCE then
        if sel == nil then return end
        local seq = sequence[track]
        -- Copy to the pattern buffer, then clear to defaults
        local buffer = {}
        for i=sel.first,sel.last,1 do
          local copied = {}
          for k, v in pairs(seq[i]) do
            copied[k] = v
          end
          copied.rate = -1 * copied.rate
          table.insert(buffer, copied)
        end
        local p = 1
        for i=sel.last,sel.first,-1 do
          for k, v in pairs(buffer[p]) do
            seq[i][k] = v
          end
          p = p + 1
        end
        seq[sel.first].lock_rate = true
        seq[sel.first].lock_subdivision = true
        if sel.last < 64 then
          seq[sel.last + 1].lock_rate = true
        end        
      end
    end,
    onPress = function(track)
      cue_rate(-1 * playheads[track].actual_rate, track)
      --engine.setSynth(track, "forward", -1)
    end,
    onRelease = function(track)
      cue_rate(-1 * playheads[track].actual_rate, track)
      -- engine.setSynth(track, "forward", 1)
    end,
  },
  cut = {
    x = 1,
    y = 7,
    pressed = false,
    modes = {MODE_SEQUENCE},
    apply = function(track, sel)
      if mode == MODE_SEQUENCE then
        if sel == nil then return end
        local seq = sequence[track]
        -- Copy to the pattern buffer, then clear to defaults
        pattern_buffer = {}
        for i=sel.first,sel.last,1 do
          local copied = {}
          for k, v in pairs(seq[i]) do
            copied[k] = v
          end
          table.insert(pattern_buffer, copied)
          seq[i] = {}
          seq[i].buf_pos = i
          seq[i].rate = 1
          seq[i].subdivision = nil
          seq[i].lock_pos = false
          seq[i].lock_rate = false
          seq[i].lock_subdivision = false
          seq[i].mute = false
          -- print("cut", i)
          -- tab.print(seq[i])
        end
        if pattern_buffer[1].buf_pos ~= seq[sel.first].buf_pos then
          seq[sel.first].lock_pos = true
        end
        if sel.last < 64 and seq[sel.last].buf_pos ~= pattern_buffer[#pattern_buffer].buf_pos then
          seq[sel.last + 1].lock_pos = true
        end
      end
    end,
  },
  copy = {
    x = 2,
    y = 7,
    pressed = false,
    modes = {MODE_SEQUENCE},
    apply = function(track, sel)
      if mode == MODE_SEQUENCE then
        if sel == nil then return end
        local seq = sequence[track]
        -- Copy to the pattern buffer, then clear to defaults
        pattern_buffer = {}
        for i=sel.first,sel.last,1 do
          local copied = {}
          for k, v in pairs(seq[i]) do
            copied[k] = v
          end
          table.insert(pattern_buffer, copied)
        end
        -- print("pattern buffer")
        -- for i, p in ipairs(pattern_buffer) do
        --   tab.print(p)
        -- end
      end      
    end,
  },
  paste = {
    x = 3,
    y = 7,
    pressed = false,
    modes = {MODE_SEQUENCE},
    apply = function(track, sel)
      if mode == MODE_SEQUENCE and pattern_buffer ~= nil then
        if sel == nil then return end
        local seq = sequence[track]
        local last = math.min(sel.last, sel.first + #pattern_buffer - 1)
        if sel.first == sel.last then
          last = sel.first + #pattern_buffer - 1
        end
        if last > 64 then
          last = 64
        end
        local p = 1
        for i=sel.first,last,1 do
          for k, v in pairs(pattern_buffer[p]) do
            seq[i][k] = v
          end
          p = p + 1
        end
        seq[sel.first].lock_pos = true
        seq[sel.first].lock_rate = true
        seq[sel.first].lock_subdivision = true
        if sel.last < 64 then
          seq[sel.last + 1].lock_pos = true
          seq[sel.last + 1].lock_rate = true
          seq[sel.last + 1].lock_subdivision = true
        end
      end      
    end,
  }
}

tools_by_coordinate = {}
for k, v in pairs(tools) do
  for i, m in ipairs(v.modes) do
    x_0 = v.x - 1
    y_0 = v.y - 1
    local idx = x_0*8 + y_0 + m*256
    tools_by_coordinate[idx] = k
  end
end

function lookup_tool(x, y, m)
  x_0 = x - 1
  y_0 = y - 1 
  local idx = x_0*8 + y_0 + m*256
  local key = tools_by_coordinate[idx]
  if key ~= nil then
    return tools[key]
  end
  return nil
end

-- Grid data
grid_dirty = true
grid_flash = 0
grid_breathe = 5
grid_breathe_incr = 1

for track=1,4,1 do
  playheads[track] = {
    seq_pos = 64,
    rate = 1,
    buf_pos = 64,
    actual_buf_pos = 64,
    actual_rate = 1,
    loop_start = 1, -- loop within sequence
    loop_end = 64,  -- loop within sequence
    division = 0.25, -- beats per step in sequence
    fx_set = { {}, {}, {} }, -- Attributes that are set of the fx
  }
  
  for step=1,64,1 do
    sequence[track][step] = {
      buf_pos = step, -- Jump to this beat in the buffer
      rate = 1, -- Set the playback to this rate
      subdivision = nil, -- Do the action every x steps, for stutter
      lock_pos = false,
      lock_rate = false,
      lock_subdivision = false,
    }
  end
end

function active_section(track)
  -- Todo: lock to selection
  if step_selections[track] ~= nil then
    return div_but_oneindex(step_selections[track].first, 16)
  end
  if section_selections[track] ~= nil then
    return section_selections[track].first
  end
  if mode == MODE_SEQUENCE then
    return div_but_oneindex(playheads[track].seq_pos, 16)
  else
    return div_but_oneindex(playheads[track].buf_pos, 16)
  end
end

function set_step_level(track)
  local p = playheads[track]
  local step = sequence[track][p.seq_pos]
  local level = params:get(pn("level", track))
  if step == nil then print("ret early"); return end
  if not transport then level = 0 end  
  if not track_cued(track) then
    if params:get(pn("mute", track)) > 0 then 
      level = 0
    end
    if step.mute then 
      level = 0 
    end
  end
  if level ~= p.level then
    engine.level(track, level)
    p.level = level
  end
end

function advance_playhead(track)
  local p = playheads[track]
  local prev_step = sequence[track][p.seq_pos]
  local looped = false
  p.seq_pos = p.seq_pos + 1
  if p.seq_pos > p.loop_end or p.seq_pos < p.loop_start then
    p.seq_pos = p.loop_start
    on_loop(track)
    looped = true
  end
  set_step_level(track)  
  local step = sequence[track][p.seq_pos]
  if seq_record_states[track] == RECORD_RECORDING then
    p.buf_pos = p.seq_pos
    p.rate = 1
    if looped then
      engine.record(track, p.seq_pos)
    end
    grid_dirty = true
    return
  end
  if cue_record_states[track] == RECORD_RECORDING then
    step.mute = params:get(pn("mute", track)) > 0
  end
  prev_step.pos_cued = nil
  prev_step.rate_cued = nil
  prev_step.loop_cued = nil
  if mode == MODE_CUE and track_cued(track) then
    -- record without locks
    if cue_record_states[track] == RECORD_RECORDING then
      if step.pos_cued then
        step.pos_cued = nil
      else
        step.buf_pos = prev_step.buf_pos + prev_step.rate
        step.lock_pos = false
      end
      if step.rate_cued then
        step.rate_cued = nil
      else
        step.rate = prev_step.rate
        step.lock_rate = false
      end
      if step.loop_cued then
        step.loop_cued = nil
      else
        step.subdivision = prev_step.subdivision
        if step.subdivision and step.subdivision > 0 then
          step.buf_pos = prev_step.buf_pos
        end
        step.lock_subdivision = false
      end
      step.mute = false
      if tools.fx1.pressed then
        cue_fx(1, track, 1)
      end
      if tools.fx2.pressed then
        cue_fx(2, track, 1)
      end
      if tools.fx3.pressed then
        cue_fx(3, track, 1)
      end
    end
  elseif step.lock_pos or step.lock_rate or step.lock_subdivision or looped or p.teleport or was_cued[track] then
    -- print ("playing step", step.buf_pos, step.rate, step.subdivision)
    if was_cued[track] and mode == MODE_CUE and cue_record_states[track] == RECORD_RECORDING then
      step.lock_pos = true
      step.lock_rate = true
      step.lock_subdivision = true
    end    
    engine.playStep(track, step.buf_pos, step.rate, step.subdivision or 0)
    p.teleport = false
    was_cued[track] = false
  end
  local fx_set_step = {{}, {}, {}}
  for k, v in pairs(step) do
    if util.string_starts(k, "fx_") then
      local parts = tab.split(k, "_")
      local idx = tonumber(parts[2])
      local attr = parts[3]
      -- print("fx", track, idx, attr, v)
      engine.setFx(track, idx, attr, v)
      fx_set_step[idx][attr] = true
      p.fx_set[idx][attr] = true
    end
  end
  -- find the fx that are set on the playhead and _not_ set on the step, and set them back to their corresponding property.
  for idx=1,3,1 do
    for k, v in pairs(p.fx_set[idx]) do
      if not fx_set_step[idx][k] then
        p.fx_set[idx][k] = nil
        local value = get_fx_value(track, idx, k)
        engine.setFx(track, idx, k, value)
      end
    end
  end
  
  if step.stall and step.stall > 0 then
    engine.setSynth(track, 'rateLag', step.stall)
    engine.setSynth(track, 'rate', 0)
  end
  
  if looped then
    for i=1,4,1 do
      if CROW_LOOP_TRACKS[params:get("crow_"..i)] == track then
        -- print("reset", track)
        crow.output[i].action = "pulse(0.01, 10)"
        crow.output[i]()
      end
    end
  end
  p.buf_pos = step.buf_pos
  p.rate = step.rate
  grid_dirty = true
end

function get_fx_value(track, idx, key)
  if key == "level" then
    local on = params:get(pn("fx"..idx.."_on", track))
    local level = params:get(pn("fx"..idx.."_level", track))
    return on*level
  end
  return params:get(pn("fx"..idx.."_"..key, track))
end

function mod_but_oneindex(x, m)
  local ret = x % m
  if ret == 0 then
    ret = m
  end
  return ret
end

function div_but_oneindex(x, d)
  return math.floor((x-1)/d) + 1
end

function mul_but_oneindex(x, m)
  return (x-1)*m + 1
end

function buttons_for_step(track, step)
  local section = div_but_oneindex(step, 16)
  local subsection = mod_but_oneindex(step, 16)
  local track_y = (track-1) * 2
  return {
    section = section,
    subsection = subsection,
    coarse_x = 6 + mod_but_oneindex(section, 2),
    coarse_y = track_y + div_but_oneindex(section, 2),
    fine_x = 8 + mod_but_oneindex(subsection, 8),
    fine_y = track_y + div_but_oneindex(subsection, 8),
  }
end

function step_for_button(x, y)
  if x > 8 then
    local track = div_but_oneindex(y, 2)
    local section = active_section(track)
    local subsection = (x-8) + 8 * ( (y-1) % 2)
    local step = (section-1)*16 + subsection
    return {
      track = track,
      section = section,
      subsection = subsection,
      step = step,
      index = step,
    }
  else
    return nil
  end
end

function section_for_button(x, y)
  if x == 6 or x == 7 then
    local section = (x-5) + 2*((y-1)%2) 
    return {
      track = div_but_oneindex(y, 2),
      section = section,
      index = section,
    }
  else
    return nil
  end
end

function sequencer_clock(track)
  -- Start at a (plausible) measure line.
  clock.sync(4)
  while true do
    if transport then
      advance_playhead(track)
    end
    clock.sync(playheads[track].division)
  end
end

function grid_clock()
  while true do -- while it's running...
    clock.sleep(1/30) -- refresh at 30fps.
    if grid_dirty then -- if a redraw is needed...
      grid_redraw() -- redraw...
      grid_dirty = false -- then redraw is no longer needed.
    end
    grid_mini_redraw()
    g:refresh()
  end
end

function screen_clock()
  while true do
    if drain > 0 then
      drain = drain - 1
    end
    clock.sleep(1/15.0)
    redraw()
  end
end

function active_selection(track)
  if step_selections[track] ~= nil then
    -- print("step sel")
    tab.print(step_selections[track])
    return step_selections[track]
  end
  local section_sel = section_selections[track]
  if section_sel ~= nil and next(section_sel.held) ~= nil then
    return {
      first = mul_but_oneindex(section_sel.first, 16),
      last = mul_but_oneindex(section_sel.last, 16) + 15,
    }
  end
end

function manage_selection(z, pressed, selections, persist, persist_only_single)
  local apply_tools = false
  if pressed ~= nil then
    local current_selection = selections[pressed.track]
    pressed_loop_len = 0
    if z == 1 and current_selection == nil then
      -- Begin selection
      local held = {}
      held[pressed.index] = true
      selections[pressed.track] = {
        first = pressed.index,
        last = pressed.index,
        held = held,
        persist = persist,
      }
      current_selection = selections[pressed.track]
      grid_dirty = true
      apply_tools = true
    elseif z == 1 then
      current_selection.held[pressed.index] = true
      local sorted = tab.sort(current_selection.held)
      if current_selection.first == current_selection.last and current_selection.first == pressed.index and #sorted == 1 then
        selections[pressed.track].persist = false
      else
        if persist_only_single and #sorted > 1 then
          selections[pressed.track].persist = false
        end
        current_selection.first = sorted[1]
        current_selection.last = sorted[#sorted]
      end
     grid_dirty = true
     apply_tools = true
    elseif z == 0 and current_selection ~= nil then
      current_selection.held[pressed.index] = nil
      if next(current_selection.held) == nil and not current_selection.persist then
        selections[pressed.track] = nil
      elseif not current_selection.persist then
        local sorted = tab.sort(current_selection.held)
        current_selection.first = sorted[1]
        current_selection.last = sorted[#sorted]
      end
      grid_dirty = true
    end
    if selections[pressed.track] ~= nil and apply_tools and mode == MODE_SEQUENCE then
      -- Apply any tools to the new selection
      for k, tool in pairs(tools) do
        if tool.pressed and tool.apply ~= nil then
          tool.apply(pressed.track, active_selection(pressed.track))
        end
      end
    elseif not persist and selections[pressed.track] ~= nil and apply_tools and mode == MODE_CUE and cue_record_states[pressed.track] ~= RECORD_PLAYING then
      if current_selection.last ~= current_selection.first then
        pressed_loop_len = current_selection.last - current_selection.first + 1
      end
      was_cued[pressed.track] = true
      engine.playStep(pressed.track, current_selection.first, playheads[pressed.track].actual_rate, pressed_loop_len)
      if cue_record_states[pressed.track] == RECORD_RECORDING then
        local seq_pos = rounded_seq_pos(pressed.track)
        sequence[pressed.track][seq_pos].buf_pos = current_selection.first
        sequence[pressed.track][seq_pos].subdivision = pressed_loop_len
        sequence[pressed.track][seq_pos].lock_pos = true
        sequence[pressed.track][seq_pos].pos_cued = true
      end
    end
  end
end

function rounded_seq_pos(track)
  local seq_pos = playheads[track].seq_pos
  local addition = util.round((clock.get_beats() % playheads[track].division)/playheads[track].division, 1)
  return seq_pos + addition
end

function normalize_amp(track)
  -- calculate the min and max amplitudes
  local lowestAmp = 1
  local highestAmp = 0.00001
  for i=1,129,1 do
    if amplitudes[track][i] ~= nil and amplitudes[track][i] > 0 then
      if i > 2 then
        lowestAmp = math.min(amplitudes[track][i] or 1, lowestAmp)
      end
      highestAmp = math.max(amplitudes[track][i] or 0.00001, highestAmp)
    end
  end
  amplitudes[track].lowest = lowestAmp
  amplitudes[track].highest = highestAmp
  amp_to_rectangle(track)
end

function on_loop(track)
  local state = record_states[track]
  if state == RECORD_RECORDING then
    -- stopping recording and monitoring happens as soon as the next slice plays.
    record_states[track] = RECORD_PLAYING
    -- automatically unmute a track as soon as it finishes recording, since "mute and record" is the trick for "don't overdub"
    if params:get(pn("mute", track)) > 0 then
      params:set(pn("mute", track), 0)
    end
    normalize_amp(track)
  elseif state == RECORD_ARMED then
    -- starting recording happens instead of playing a slice.
    record_states[track] = RECORD_RECORDING
  end
  
end

function record_press_initiated(track)
  record_timers[track] = clock.run(
    function () 
      clock.sleep(0.5)
      record_timers[track] = nil
      record_longpressed(track)
    end)  
end

function record_released(track)
  if record_timers[track] ~= nil then
    clock.cancel(record_timers[track])
    record_timers[track] = nil
    record_pressed(track)
  end
end

function record_pressed(track)
  local state = record_states[track]
  if state == RECORD_PLAYING then
    -- start monitoring
    if mode == MODE_SEQUENCE then
      engine.monitor(track, 1)
      local ph = playheads[track]
      if math.abs(ph.buffer_tempo - clock.get_tempo()) > 0.3 then
        engine.resample(track)
        record_states[track] = RECORD_RESAMPLING
        return -- Avoid getting set to RECORD_MONITORING
      end
    end
    record_states[track] = RECORD_MONITORING

  elseif state == RECORD_MONITORING then
    record_states[track] = RECORD_ARMED
  elseif state == RECORD_ARMED then
    record_states[track] = RECORD_MONITORING
  elseif state == RECORD_RECORDING then
    -- pass ?
  elseif state == RECORD_RESAMPLING then
    -- pass
  elseif state == RECORD_SOS then
    -- TODO: Stop recording
    record_states[track] = RECORD_MONITORING
  end  
end

function record_longpressed(track)
  local state = record_states[track]
  if state == RECORD_MONITORING or state == RECORD_RESAMPLING then
    record_states[track] = RECORD_PLAYING
    if mode == MODE_SEQUENCE then
      engine.monitor(track, 0)
    end
    -- TODO: stop monitoring
  elseif state == RECORD_ARMED then
    record_states[track] = RECORD_SOS
    -- TODO: start recording
  elseif state == RECORD_RECORDING then
    record_states[track] = RECORD_SOS
  else
    record_pressed(track)
  end    
end

function any_recording()
  for i=1,4,1 do
    if record_states[i] == RECORD_RECORDING or record_states[i] == RECORD_ARMED or record_states[i] == RECORD_SOS then
      return true
    end
  end
  return false
end

function any_cued()
  for i=1,4,1 do
    if track_cued(i) then
      return true
    end
  end
  return false
end

function track_cued(track)
  
  if record_states[track] == RECORD_PLAYING then
    return false
  end
  
  for k, tool in pairs(tools) do
    if tool.pressed then
      return true
    end
  end

  if step_selections[track] ~= nil and next(step_selections[track].held) ~= nil then
    return true
  end

  return false
end

function g.key(x, y, z)
  -- mode selector
  screen.ping()
  if z == 1 and x == 1 and y == 1 then
    if any_recording() then
      return
    end
    mode = MODE_SEQUENCE
    record_states = seq_record_states
    section_selections = seq_section_selections
    step_selections = seq_step_selections
    grid_dirty = true
    return
  end

  if z == 1 and x == 3 and y == 1 then
    if any_recording() then
      return
    end
    mode = MODE_CUE
    record_states = cue_record_states
    section_selections = cue_section_selections
    step_selections = cue_step_selections
    grid_dirty = true
    return
  end
  
  -- Cue-mode time selector
  if mode == MODE_CUE and y == 8 and x <= 3 then
    cue_mode_time = x
  end
  
  -- Select
  if z == 1 and x == 1 and y == 8 and mode == MODE_SEQUENCE then
    froze = false
    select_held = true
    for track=1,4,1 do
      if step_selections[track] ~= nil then
        if not step_selections[track].persist then
          step_selections[track].persist = true
          froze = true
        end
      end
    end
    print("froze is now", froze)
    grid_dirty = true
  end
  if z == 0 and x == 1 and y == 8 and mode == MODE_SEQUENCE then
    if not froze then
      print("deselect")
      for track=1,4,1 do
        step_selections[track] = nil
      end
    end
    select_held = false
    grid_dirty = true
  end  
  
  -- Record
  if x == 5 and y%2 == 1 then
    local track = div_but_oneindex(y, 2)
    if z == 1 then
      record_press_initiated(track)
    else
      record_released(track)
    end
  end  
  -- Mute
  if z == 1 and x == 5 and y%2 == 0 then
    local track = div_but_oneindex(y, 2)
    local sel = active_selection(track)
    if sel ~= nil and next(sel.held) ~= nil then
      for i=sel.first,sel.last,1 do
        sequence[track][i].mute = not sequence[track][i].mute
      end
      sequence[track].rectangle = nil
    else
      params:set(pn("mute", track), params:get(pn("mute", track)) > 0 and 0 or 1)
    end
  end
  -- Tools
  local tool = lookup_tool(x, y, mode)
  if tool ~= nil then
    if tab.contains(tool.modes, mode) then
      if mode == MODE_CUE then
        for track=1,4,1 do
          if record_states[track] == RECORD_RECORDING then
            sequence[track].rectangle = nil
          end
        end
      end
      if z == 1 then
        tool.pressed = true
        if tool.apply ~= nil and mode == MODE_SEQUENCE then
          for track=1,4,1 do
            local sel = active_selection(track)
            tool.apply(track, sel)
            if sel ~= nil then
              -- invalidate the drawn sequence
              sequence[track].rectangle = nil
            end
          end
        elseif tool.onPress ~= nil and mode == MODE_CUE then
          for i=1,4,1 do
            if record_states[i] ~= RECORD_PLAYING then
              was_cued[i] = true
              tool.onPress(i)
            end
          end  
        end
        if tool.handle ~= nil then
          tool.handle()
        end
      else
        tool.pressed = false
        if tool.onReleaseAlways ~= nil and mode == MODE_CUE then
          for i=1,4,1 do
            if record_states[i] ~= RECORD_PLAYING then
              tool.onReleaseAlways(i)
            end
          end        
        end
        if tool.onRelease ~= nil and mode == MODE_CUE then
          for i=1,4,1 do
            if track_cued(i) then
              tool.onRelease(i)
            end
          end
        end
      end
      grid_dirty = true
    end
  end
  
  -- Section selection
  local pressed = section_for_button(x, y)
  manage_selection(z, pressed, section_selections, true, true)
  
  -- Step selection
  pressed = step_for_button(x, y)
  manage_selection(z, pressed, step_selections, select_held, false)
  if pressed ~= nil and select_held then froze = true end

end

function rounded_actual_pos(track)
  return rounded_actual_pos_units(track, 1)
end

function rounded_actual_pos_units(track, units)
  local ph = playheads[track]
  local now = clock.get_beats()/ph.division
  local projected = ph.actual_rate * (now-ph.actual_timestamp) + ph.actual_buf_pos + 1 -- actual_buf_pos is 0-indexed for now
  local ret = util.round(projected, units)
  if ret > 64 then
    ret = ret - 64
  end
  return ret
end

function osc_in(path, args, from)
  -- print("osc", path, args[1], args[2], args[3], args[4], from)
  if path == "/amplitude" then
    local track = args[1]
    local slice = args[2]
    local amp = args[3]
    if amplitudes[track] ~= nil then
      amplitudes[track][slice] = amp
    end
    if slice % 8 == 0 then
      amp_to_rectangle(track)
    end
  elseif path == "/report" then
    local track = args[1]
    local pos = args[2]
    local rate = args[3]
    local loop = args[4]
    local buf_tempo = args[5]
    local ph = playheads[track]
    ph.actual_buf_pos = pos
    ph.actual_rate = rate
    ph.actual_loop = loop
    ph.actual_timestamp = clock.get_beats()/ph.division
    ph.buffer_tempo = buf_tempo*60
    grid_dirty = true
  elseif path == "/resampleAmplitude" then
    local track = args[1]
    local pos = args[2]
    local amp = args[3]
    print("resampleamp", track, pos, amp)
  elseif path == "/resampleDone" then
    local track = args[1]
    if record_states[track] == RECORD_RESAMPLING then
      record_states[track] = RECORD_MONITORING
    end
  elseif path == "/readAmpDone" then
    local track = args[1]
    normalize_amp(track)
  elseif path == "/wrote" then
    local track = args[1]
    local filename = args[2]
    params:set(pn("load", track), filename, true)
    tracks_written = tracks_written + 1
    if tracks_written == 4 then
      print("Saving params", params:get("save_as"))
      params:write(params:get("save_as"))
      tracks_written = 0
    end
  end
end

osc.event = osc_in

function grid_mini_redraw()
  -- Button animations
  if grid_flash == 0 then
    grid_flash = 1
  else
    grid_flash = 0
  end
  
  grid_breathe = grid_breathe + grid_breathe_incr
  if grid_breathe >= 15 then
    grid_breathe_incr = -1
  elseif grid_breathe <= 2 then
    grid_breathe_incr = 1
  end
  local beats = clock.get_beats()
  -- Per track
  for track=1,4,1 do
    local record_x = 5
    local record_y = mul_but_oneindex(track, 2)
    local state = record_states[track]
    if state == RECORD_PLAYING then
      g:led(record_x, record_y, INACTIVE + 1 - math.floor(3*(beats % 1)))
    elseif state == RECORD_MONITORING then
      g:led(record_x, record_y, SELECTED + 2 - math.floor(4*(beats % 1)))
    elseif state == RECORD_RESAMPLING then
      g:led(record_x, record_y, grid_breathe <= 12 and SELECTED or 0)
    elseif state == RECORD_ARMED then
      g:led(record_x, record_y, SELECTED*grid_flash)
    elseif state == RECORD_RECORDING then
      g:led(record_x, record_y, ACTIVE - math.floor( 15*math.abs(1 - beats % 2)))
    elseif state == RECORD_SOS then
      g:led(record_x, record_y, ACTIVE)
    end
    
    local mute_x = record_x
    local mute_y = record_y + 1
    g:led(mute_x, mute_y, params:get(pn("mute", track)) > 0 and INACTIVE or SELECTED)
  end
end

function grid_redraw()
  g:all(0)
  
  -- Modes
  g:led(1, 1, mode == MODE_SEQUENCE and SELECTED or INACTIVE)
  g:led(3, 1, mode == MODE_CUE and SELECTED or INACTIVE)

  -- Select
  local select_persist = false
  for track=1,4,1 do
    if step_selections[track] ~= nil and step_selections[track].persist then
      select_persist = true
      break
    end
  end
  -- Tools
  if mode == MODE_SEQUENCE then
    g:led(1, 8, select_held and ACTIVE or (select_persist and SELECTED or INACTIVE))
  elseif mode == MODE_CUE then
    for x=1,3,1 do
      g:led(x, 8, x == cue_mode_time and SELECTED or INACTIVE)
    end
  end
  for k, v in pairs(tools) do
    if tab.contains(v.modes, mode) then
      g:led(v.x, v.y, v.pressed and ACTIVE or INACTIVE)
    end
  end
  -- Sections
  for x=6,7,1 do
    for y=1,8,1 do
      local section = section_for_button(x, y)
      local selection = section_selections[section.track]
      local playhead = playheads[section.track]
      local loop_start_section = div_but_oneindex(playhead.loop_start, 16)
      local loop_end_section = div_but_oneindex(playhead.loop_end, 16)
      g:led(x, y, BACKGROUND)
      if mode == MODE_SEQUENCE and section.index >= loop_start_section and section.index <= loop_end_section then
        g:led(x, y, IN_LOOP_SECTION)
      end
      if selection ~= nil then
        if section.index >= selection.first and section.index <= selection.last then
          g:led(x, y, SELECTED)
        end
      end
      if mode == MODE_SEQUENCE and section.index == div_but_oneindex(playhead.seq_pos, 16) then
        g:led(x, y, ACTIVE)
      end
      if mode == MODE_CUE and section.index == div_but_oneindex(playhead.buf_pos, 16) then
        g:led(x, y, ACTIVE)
      end
    end
  end
  -- Steps
  for x=9,16,1 do
    for y=1,8,1 do
      local step = step_for_button(x, y)
      local selection = step_selections[step.track]
      local playhead = playheads[step.track]
      local level = BACKGROUND
      local highest = amplitudes[step.track].highest or 1
      local lowest = amplitudes[step.track].lowest or 0.00001
      local range = math.log(highest/lowest)
      local step_data = sequence[step.track][step.index]
      if mode == MODE_SEQUENCE then
        local amp1 = amplitudes[step.track][mul_but_oneindex(step_data.buf_pos, 2)] or 0
        local amp2 = amplitudes[step.track][mul_but_oneindex(step_data.buf_pos, 2) + 1] or 0
        local amp = math.max(amp1, amp2)/highest
        if highest/lowest > 10 then
          amp = math.sqrt(amp)
        elseif highest/lowest < 5 then
          amp = amp*amp
        end
        if step.index >= playhead.loop_start and step.index <= playhead.loop_end then
          level = math.max(level, math.floor(13*amp))
        else
          level = math.max(level, math.floor(7*amp))         
        end
      end
      if mode == MODE_CUE then
        local amp1 = amplitudes[step.track][mul_but_oneindex(step.index, 2)] or 0
        local amp2 = amplitudes[step.track][mul_but_oneindex(step.index, 2) + 1] or 0
        local amp = math.max(amp1, amp2)/highest
        if highest/lowest > 10 then
          amp = math.sqrt(amp)
        elseif highest/lowest < 5 then
          amp = amp*amp
        end
        level = math.max(level, math.floor(13*amp))
      end
      if selection ~= nil then
        if step.index >= selection.first and step.index <= selection.last then
          level = math.max(level, SELECTED)
        end
      end
      if mode == MODE_SEQUENCE and step_data.mute then
        level = 0
      end      
      if mode == MODE_SEQUENCE and step.index == playhead.seq_pos then
        level = ACTIVE
      end
      if mode == MODE_CUE and step.index == math.floor(playhead.actual_buf_pos) + 1 then
        level = ACTIVE
      end
      level = math.floor(level)
      if level >= 0 and x > 0 and y > 0 then
        g:led(x, y, level)
      else
        print("oh no bad int", level)
      end
    end
  end
end

function sync_every_beat()
  while true do
    clock.sync(1)
    b = clock.get_beats()
    t = clock.get_tempo()
    engine.tempo_sync(b, t/60.0)
    if params:get("metronome") > 0 then
      local rounded = util.round(b, 1)
      if rounded % 4 == 0 then
        engine.metronome(440)
      else
        engine.metronome(220)
      end
    end
  end
end


crow_known_tempo = nil
crow_known_div = {nil, nil, nil, nil}

function bpm_in_string(s)
  for w in string.gmatch(s, "%d+") do
    local bpm = tonumber(w)
    if bpm >= 45 and bpm <= 240 then
      return bpm
    end
  end
  return nil
end

function crow_every_beat()
  while true do
    clock.sync(1)
    local tempo = clock.get_tempo()
    for i=1,4,1 do
      local div = CROW_BEAT_DIVISIONS[params:get("crow_"..i)]
      local beat = 60/tempo
      if div ~= nil then
        crow.output[i].action = string.format(
          "times( %i, { to(10, %.5f, 'now'), to(0, %.5f, 'now') } )",
          div,
          beat/(4.0*div),
          beat/(4.0*div))
        crow.output[i]()
      end
      crow_known_div[i] = div
    end
    crow_known_tempo = tempo
  end
end

-- param name
function pn(base, track)
  return base .. "_" .. track
end

function reset_track(track)
  playheads[track].seq_pos = playheads[track].loop_end
  playheads[track].teleport = true
end

function reset_all()
  for track=1,4,1 do
    reset_track(track)
  end
end

function clear_track(track)
  engine.realloc(track, playheads[track].division)
  for i=1,128,1 do
    amplitudes[track][i] = 0
  end
  amplitudes[track].rectangle = nil
  amplitudes[track].dark_rectangle = nil
  amplitudes[track].highest = nil
  playheads[track].teleport = true
end

function init()
  params:add_separator("general")
  params:add_binary("metronome", "metronome", "toggle", 0)
  params:set_action("metronome", function(m)
    engine.metronome(m)
  end)
  params:add_trigger("reset_all", "reset all")
  params:set_action("reset_all", reset_all)
  params:add_binary("reset_on_transport", "reset on transport", "toggle", 1)
  params:add_number(
    "reset_all_every", 
    "reset every", 
    0, 
    256, 
    0, 
    function(param)
      if param:get() == 0 then
        return "never"
      else
        return ""..param:get()
      end
    end,
    false)
  clock.run(function ()
    while true do
      local every = params:get("reset_all_every")
      if every == 0 then
        clock.sync(4)
      else
        clock.sync(every)
        reset_all()
      end
    end
  end)
  params:add_option("ek3", "e3/k3", EK3_OPTIONS, 1)
  
  params:add_group("storage", 3)
  params:add_file("sequence_file", "sequence file")
  params:set_action("sequence_file", function(filename)
    sequence = tab.load(filename)
  end)
  params:add_number("save_as", "save as pset", 1, 32, 1)
  params:add_trigger("save", "save")
  params:set_action("save", function () 
    local i = params:get("save_as")
    local seq_filename = _path.data .. "sequence_" .. i .. ".nydl"
    tab.save(sequence, seq_filename)
    params:set("sequence_file", seq_filename, true)
    if not util.file_exists(_path.audio .. "nydl") then
      util.make_dir(_path.audio .. "nydl")
    end
    for track=1,4,1 do
      engine.saveTrack(track, _path.audio .. "nydl/" .. "pset " .. i .. " track " .. track)
    end
  end)

  params:add_separator("tracks")
  for track=1,4,1 do
    params:add_group("track "..track, 24)
    params:add_option(pn("div", track), "division", DIV_OPTIONS, 1)
    params:set_action(pn("div", track), function (opt)
      local div = DIV_VALUES[opt]
      if div ~= playheads[track].division then
        engine.realloc(track, div)
        playheads[track].division = div
      end
    end)
    params:add_file(pn("load", track), "load")
    params:set_action(pn("load", track), function (filename)
      if filename ~= nil and filename ~= "" and filename ~= "-" then
        print("calc bpm", filename)
        local bpm = bpm_in_string(filename) or clock.get_tempo()
        print("trying to load", filename, "at", bpm)
        engine.loadTrack(track, filename, bpm/60)
      end
    end)
    params:add_number(pn("start", track), "loop start", 1, 64, 1)
    params:set_action(pn("start", track), function(pos)
        playheads[track].loop_start = pos
        if playheads[track].loop_end < pos then
          params:set(pn("end", track), pos)
        end
      end)
    params:add_number(pn("end", track), "loop end", 1, 64, 64)
    params:set_action(pn("end", track), function (pos)
        if pos < playheads[track].loop_start then
          params:set(pn("end", track), playheads[track].loop_start)
        else
          playheads[track].loop_end = pos
        end
    end)
    local amp_spec = controlspec.AMP:copy()
    amp_spec.default = 1.0
    params:add_control(pn("level", track), "level", amp_spec)
    params:set_action(pn("level", track), function(level)
      set_step_level(track)
      --engine.level(track, params:get(pn("mute", track)) > 0 and 0 or level)
    end)
    params:add_binary(pn("mute", track), "mute", "toggle", 0)
    params:set_action(pn("mute", track), function(mute)
      set_step_level(track)
      --engine.level(track, mute > 0 and 0 or params:get(pn("level", track)))
    end)
    params:add_trigger(pn("reset", track), "reset")
    params:set_action(pn("reset", track), function () 
      reset_track(track)
    end)
    params:add_trigger(pn("clear", track), "clear")
    params:set_action(pn("clear", track), function () 
      clear_track(track)
    end)
    -- FX
    params:add_separator("decimate")
    params:add_binary(pn("fx1_on", track), "on", "toggle", 0)
    params:add_control(pn("fx1_level", track), "wet", amp_spec)
    params:set_action(pn("fx1_on", track), function (on)
      engine.setFx(track, 1, "level", on*params:get(pn("fx1_level", track)))
    end)
    params:set_action(pn("fx1_level", track), function (level)
      engine.setFx(track, 1, "level", level*params:get(pn("fx1_on", track)))
    end)
    params:add_control(pn("fx1_rate", track), "rate", controlspec.new(480, 48000, 'exp', 0, 1000, "Hz"))
    params:set_action(pn("fx1_rate", track), function (rate)
      engine.setFx(track, 1, "rate", rate)
    end)
    params:add_control(pn("fx1_smooth", track), "smooth", controlspec.new(0.0, 1.0, 'lin', 0, 0.2))
    params:set_action(pn("fx1_smooth", track), function (smooth)
      engine.setFx(track, 1, "smooth", smooth)
    end)
    
    params:add_separator("filter")
    params:add_binary(pn("fx2_on", track), "on", "toggle", 0)
    params:add_control(pn("fx2_level", track), "wet", amp_spec)
    params:set_action(pn("fx2_on", track), function (on)
      engine.setFx(track, 2, "level", on*params:get(pn("fx2_level", track)))
    end)
    params:set_action(pn("fx2_level", track), function (level)
      engine.setFx(track, 2, "level", level*params:get(pn("fx2_on", track)))
    end)
    params:add_control(pn("fx2_cutoff", track), "cutoff", controlspec.FREQ)
    params:set_action(pn("fx2_cutoff", track), function (f)
      engine.setFx(track, 2, "cutoff", f)
    end)    
    params:add_control(pn("fx2_res", track), "resonance", controlspec.RQ)
    params:set_action(pn("fx2_res", track), function (rq)
      engine.setFx(track, 2, "res", rq)
    end)
    params:add_control(pn("fx2_low", track), "low pass", controlspec.AMP)
    params:set_action(pn("fx2_low", track), function (a)
      engine.setFx(track, 2, "low", a)
    end)    
    params:add_control(pn("fx2_band", track), "band pass", amp_spec)
    params:set_action(pn("fx2_band", track), function (a)
      engine.setFx(track, 2, "band", a)
    end)    
    params:add_control(pn("fx2_high", track), "high pass", amp_spec)
    params:set_action(pn("fx2_high", track), function (a)
      engine.setFx(track, 2, "high", a)
    end)
    
    params:add_separator("delay send")
    params:add_binary(pn("fx3_on", track), "on", "toggle", 0)
    params:add_control(pn("fx3_level", track), "wet", amp_spec)
    params:set_action(pn("fx3_on", track), function (on)
      engine.setFx(track, 3, "level", on*params:get(pn("fx3_level", track)))
    end)
    params:set_action(pn("fx3_level", track), function (level)
      engine.setFx(track, 3, "level", level*params:get(pn("fx3_on", track)))
    end)
  end
  
  params:add_separator("send")
  params:add_control("send_delay", "delay time", controlspec.DELAY)
  params:set_action("send_delay", function(time)
    engine.setSend("delay", time)
  end)
  params:add_number("send_repeats", "delay repeats", 1, 20, 4)
  params:set_action("send_repeats", function(rep)
    engine.setSend("repeats", rep)
  end)
  
  params:add_separator("crow")
  for i=1,4,1 do
    params:add_option("crow_"..i, "crow out "..i, CROW_MODES, 1)
  end
  
  local core_tempo_action = params:lookup_param('clock_tempo').action
  params:set_action('clock_tempo', function(bpm)
      if clock.get_tempo() == bpm then
        return
      end
      for i=1,4,1 do
        if seq_record_states[i] ~= RECORD_PLAYING then
          -- refuse to change the tempo when monitoring or recording
          params:set('clock_tempo', clock.get_tempo())
          return
        end
      end
      b = clock.get_beats()
      engine.tempo_sync(b, bpm/60.0)
      core_tempo_action(bpm)
  end)
  params:add_binary("enable_tt", "teletype control", "toggle", 0)
  params:set_action("enable_tt", function (on) 
    if on > 0 then
      crow.send([[
        function ii.self.call3(track, first, last)
          tell('cue_select', track, first, last)
        end
        function ii.self.call4(track, tool, z, extra_value)
          tell('tool', track, tool, z, extra_value)
        end
      ]])
    end
  end)
  clock.run(sync_every_beat)
  clock.run(crow_every_beat)
  
  for track=1,4,1 do
    clock.run(sequencer_clock, track)
  end
  clock.run(grid_clock)
  clock.run(screen_clock)
  params:read(nil)
end

function adjust_param_by(param, delta)
  local raw = params:get_raw(param)
  raw = raw + delta/100
  if raw > 1 then 
    raw = 1 
  elseif raw < 0 then
    raw = 0 
  end
  params:set_raw(param, raw)  
end

function enc(n, d)
  if n == 1 then
    screen_track = mod_but_oneindex(math.floor(screen_track + d), 4)
  elseif n == 2 then
    params:set("ek3", mod_but_oneindex(params:get("ek3") + d, #EK3_OPTIONS + 1))
  elseif n == 3 then
    local ek3 = params:get("ek3")
    if ek3 == EK3_LEVEL then
      adjust_param_by(pn("level", screen_track), d)
    elseif ek3 == EK3_LOOP then
      local loop_start = params:get(pn("start", screen_track))
      local loop_end = params:get(pn("end", screen_track))
      local loop_len = loop_end - loop_start + 1
      if k3_pressed then
        --- Loop length
        if d > 0 and loop_len < 64 then
          -- lengthen loop
          local new_end = loop_start + (loop_len * 2) - 1
          local new_start = loop_start
          if new_end > 64 then
            new_start = new_start - (new_end - 64)
            new_end = 64
          end
          if new_start < 1 then
            new_start = 1
          end
          tools.loop.apply(screen_track, {first = new_start, last = new_end})
          --params:set(pn("start", screen_track), new_start)
          --params:set(pn("end", screen_track), new_end)
        elseif d < 0 and loop_len > 1 then
          -- shorten loop
          tools.loop.apply(screen_track, {first = loop_start, last=loop_start + math.floor(loop_len/2) - 1})
          -- params:set(pn("end", screen_track), loop_start + math.floor(loop_len/2) - 1)
        end
      else
        -- Loop position
        if d < 0 then
          local new_start = loop_start - loop_len
          if new_start < 1 then
            new_start = 1
          end
          local new_end = new_start + loop_len - 1
          tools.loop.apply(screen_track, {first=new_start, last=new_end})
          -- params:set(pn("start", screen_track), new_start)
          -- params:set(pn("end", screen_track), new_end)          
        elseif d > 0 then
          local new_end = loop_end + loop_len
          if new_end > 64 then
            new_end = 64
          end
          local new_start = new_end - loop_len + 1
          tools.loop.apply(screen_track, {first=new_start, last=new_end})
          -- params:set(pn("start", screen_track), new_start)
          -- params:set(pn("end", screen_track), new_end)           
        end
      end
    elseif ek3 == EK3_RESET then
      -- pass
    elseif ek3 == EK3_FX1 then
      adjust_param_by(pn("fx1_rate", screen_track), d)
    elseif ek3 == EK3_FX2 then
      adjust_param_by(pn("fx2_cutoff", screen_track), d)
    elseif ek3 == EK3_FX3 then
      adjust_param_by("send_delay", d)
    elseif ek3 == EK3_CLEAR then
      drain = drain + 15*d
      if drain > 100 then
        drain = 0
        if k3_pressed then
          for i=1,4,1 do
            clear_track(i)
          end
        else
          clear_track(screen_track)
        end
      end
    end
  end
end

function clock.transport.start()
  print("started transport")
  transport = true
  for track=1,4,1 do
    set_step_level(track)
  end
end

function clock.transport.stop()
  print ("stopped transport")
  transport = false
  for track=1,4,1 do
    set_step_level(track)
  end
  if params:get("reset_on_transport") > 0 then
    reset_all()
  end
end

function key(n, z)
  if n == 2 then
    if z == 1 then
      record_press_initiated(screen_track)
    else
      record_released(screen_track)
    end
  elseif n == 3 then
    k3_pressed = true
    if z == 1 then
      local ek3 = params:get("ek3")
      if ek3 == EK3_LEVEL then
        params:set(pn("mute", screen_track), 1 - params:get(pn("mute", screen_track)))
      elseif ek3 == EK3_LOOP then
        -- pass
      elseif ek3 == EK3_RESET then
        reset_all()
      elseif ek3 == EK3_FX1 then
        params:set(pn("fx1_on", screen_track),  1 - params:get(pn("fx1_on", screen_track)))
      elseif ek3 == EK3_FX2 then
        params:set(pn("fx2_on", screen_track),  1 - params:get(pn("fx2_on", screen_track)))
      elseif ek3 == EK3_FX3 then
        params:set(pn("fx3_on", screen_track),  1 - params:get(pn("fx3_on", screen_track)))
      elseif ek3 == EK3_CLEAR then
        -- pass
      end
    else
      k3_pressed = false
    end
  end
end

AMP_FMT = string.rep('b', 128*9)

function amp_to_rectangle(track)
  local highest = amplitudes[track].highest or 1
  local ret = {}
  for slice=1,128,1 do
    local amp = amplitudes[track][slice] or 0
    local normalized = 10*amp/highest
    for row=1,9,1 do
      local threshold = 10-row
      threshold = (threshold*threshold)/10
      local remainder = normalized - threshold
      local level = 0
      if remainder ~= remainder then
        -- nan
        level = 0
      elseif remainder > 1 then
        level = 6
      elseif remainder > 0 then
        level = math.floor(6*remainder)
      end
      local idx = mul_but_oneindex(row, 128) + slice - 1
      ret[idx] = level
    end
  end
  amplitudes[track].rectangle = string.pack(AMP_FMT, table.unpack(ret))
  for i=1,128*9,1 do
    ret[i] = math.floor(ret[i]/3)
  end
  amplitudes[track].dark_rectangle = string.pack(AMP_FMT, table.unpack(ret))
end

SEQ_FMT = string.rep('b', 128)

function seq_to_rectangle(track)
  if sequence[track].rectangle ~= nil then
    return
  end
  local ret = {}
  for slice=1,128,1 do
    local playhead = playheads[track]
    local seq_pos = div_but_oneindex(slice, 2)
    local step = sequence[track][seq_pos]
    local begin = slice % 2 > 0
    local loop_divisor = 1
    local level = 1
    if seq_pos >= playhead.loop_start and seq_pos <= playhead.loop_end then
      level = 2
    else
      loop_divisor = 2
    end
    if step.buf_pos ~= seq_pos or step.rate ~= 1 then
      level = 4/loop_divisor
    end      
    if (step.lock_pos or step.lock_rate) and begin then
      level = 10/loop_divisor
    end
    if step.mute then
      level = 0
    end
    ret[slice] = level
  end
  sequence[track].rectangle = string.rep(string.pack(SEQ_FMT, table.unpack(ret)), 2)
end

function redraw()
  screen.clear()
  for track=1,4,1 do
    -- The audio
    local track_start_y = mul_but_oneindex(track, 14)
    local highest = amplitudes[track].highest or 1
    seq_to_rectangle(track) -- stores it in sequence[track].rectangle
    screen.poke(0, track_start_y + 10, 128, 2, sequence[track].rectangle)
    if params:get(pn("mute", track)) > 0 then
      if amplitudes[track].dark_rectangle ~= nil then
        screen.poke(0, track_start_y, 128, 9, amplitudes[track].dark_rectangle)
      end
    else
      if amplitudes[track].rectangle ~= nil then
        screen.poke(0, track_start_y, 128, 9, amplitudes[track].rectangle)
      end
    end
    if track == screen_track then
      screen.move(0, track_start_y + 10)
      screen.level(15)
      screen.line_rel(129, 0)
      screen.stroke()
    end
    
    local ph = playheads[track]
    screen.move(ph.actual_buf_pos*2, track_start_y)
    screen.level(15)
    screen.line_rel(0, 9)
    screen.stroke()
    screen.rect((ph.seq_pos - 1)*2, track_start_y+10, 2, 2)
    screen.fill()
  end
  local k2_text = ""
  local mode_text = ""
  local value = 0
  if mode == MODE_SEQUENCE then
    if params:get(pn("mute", screen_track)) > 0 then
      if record_states[screen_track] == RECORD_PLAYING then
        mode_text = "mute"
        k2_text = "k2:mon"
      elseif record_states[screen_track] == RECORD_RECORDING then
        mode_text = "rec"
        k2_text = ""
      elseif record_states[screen_track] == RECORD_ARMED then
        mode_text = "arm"
        k2_text = "k2:unarm"
      elseif record_states[screen_track] == RECORD_MONITORING then
        mode_text = "mon"
        k2_text = "k2:rec"
      elseif record_states[screen_track] == RECORD_RESAMPLING then
        mode_text = "rsmpl"
      end      
    else
      if record_states[screen_track] == RECORD_PLAYING then
        mode_text = "play"
        k2_text = "k2:mon"
      elseif record_states[screen_track] == RECORD_RECORDING then
        mode_text = "dub"
      elseif record_states[screen_track] == RECORD_MONITORING then
        mode_text = "mon"
        k2_text = "k2:dub"
      elseif record_states[screen_track] == RECORD_ARMED then
        mode_text = "arm"
        k2_text = "k2:unarm"
      elseif record_states[screen_track] == RECORD_RESAMPLING then
        mode_text = "rsmpl"
      end
    end
  elseif mode == MODE_CUE then
      if record_states[screen_track] == RECORD_PLAYING then
        if params:get(pn("mute", screen_track)) > 0 then
          mode_text = "mute"
          k2_text = "k2:cue"
        else
          mode_text = "play"
          k2_text = "k2:cue"
        end
      elseif record_states[screen_track] == RECORD_RECORDING then
        mode_text = "seq"
      elseif record_states[screen_track] == RECORD_MONITORING then
        mode_text = "cue"
        k2_text = "k2:seq"
      elseif record_states[screen_track] == RECORD_ARMED then
        mode_text = "arm"
        k2_text = "k2:unarm"
      elseif record_states[screen_track] == RECORD_RESAMPLING then
        mode_text = "rsmpl"
      end
  end
  local ek3_text
  local ek3 = params:get("ek3")
  if ek3 == EK3_LEVEL then
    ek3_text = "k3:mute e3:lvl"
    value = params:get(pn("level", screen_track))
  elseif ek3 == EK3_LOOP then
    if k3_pressed then
      ek3_text = "k3:* e3:loop-len"
    else
      ek3_text = "k3:* e3:loop-pos"
    end
  elseif ek3 == EK3_RESET then
    ek3_text = "k3:reset"
  elseif ek3 == EK3_FX1 then
    ek3_text = "k3:redx e3:freq"
    value = params:get_raw(pn("fx1_rate", screen_track))
  elseif ek3 == EK3_FX2 then
    ek3_text = "k3:filt e3:freq"
    value = params:get_raw(pn("fx2_cutoff", screen_track))
  elseif ek3 == EK3_FX3 then
    ek3_text = "k3:send e3:delay"
    value = params:get_raw("send_delay")
  elseif ek3 == EK3_CLEAR then
    if k3_pressed then
      ek3_text = "k3:* e3:clear-all"
    else
      ek3_text = "k3:* e3:clear"
    end
    value = drain/100
  end
  screen.move(0, 62)
  screen.font_face(25) -- second best, and slightly more compact, face 25 size 6
  screen.font_size(6)
  screen.level(15)
  screen.text(mode_text)
  screen.move(23, 62)
  screen.level(3)
  screen.text(k2_text .. " " .. ek3_text)
  if value and value > 0 then
    screen.circle(124, 60, 4*value)
    screen.fill()
  end
  screen.update()
end

crow_selected = {nil, nil, nil, nil}

norns.crow.events.tool = function(track, t, z, extra_value)
  track = math.floor(track)
  t = math.floor(t)
  print("tool", track, t, z, extra_value)
  if mode == MODE_CUE then
    local tool
    if t == 0 then
      tool = tools.normal
    elseif t == 1 then
      tool = tools.reverse
    elseif t == 2 then
      tool = tools.stutter2
    elseif t == 3 then
      tool = tools.stutter3
    elseif t == 4 then
      tool = tools.stutter4
    elseif t == 5 then
      tool = tools.slow
    elseif t == 6 then
      tool = tools.fast
    elseif t == 7 then
      tool = tools.fx1
    elseif t == 8 then
      tool = tools.fx2
    elseif t == 9 then
      tool = tools.fx3
    elseif t == 10 then
      tool = tools.stall
    elseif t == 11 then
      -- mute
      params:set(pn("mute", track), z)
    end
    if tool ~= nil then
      if record_states[track] == RECORD_RECORDING then
        sequence[track].rectangle = nil
      end
      end
      if z == 1 then
        tool.pressed = true
        if tool.onPress ~= nil then
          if record_states[track] ~= RECORD_PLAYING then
            was_cued[track] = true
            tool.onPress(track)
          end
        end
        if tool.handle ~= nil then
          tool.handle()
        end
      else
        tool.pressed = false
        if tool.onReleaseAlways ~= nil then
          if record_states[track] ~= RECORD_PLAYING then
            tool.onReleaseAlways(track)
          end
        end
        if tool.onRelease ~= nil then
          if track_cued(track) then
            tool.onRelease(track)
          end
        end
      end
      grid_dirty = true
    end
end

norns.crow.events.cue_select = function(track, first, last)
  print("cue select", track, first, last)
  if mode == MODE_CUE then
    if crow_selected[track] then
      -- clear current crow selection
      manage_selection(0, {
        track = track,
        step = crow_selected[track].first,
        index = crow_selected[track].first,
      }, step_selections, false, false)
      if crow_selected[track].first ~= crow_selected[track].last then
        manage_selection(0, {
          track = track,
          step = crow_selected[track].last,
          index = crow_selected[track].last,
        }, step_selections, false, false)
      end
      crow_selected[track] = nil
    end
    if first > 0 then
      manage_selection(1, {
        track = track,
        step = first,
        index = first,
      }, step_selections, false, false)
      if last > first then

        manage_selection(1, {
        track = track,
        step = last,
        index = last,
        }, step_selections, false, false)
      end
      crow_selected[track] = {first = first, last = math.max(first, last)}
    end
  end
end
