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

-- Global script data
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

-- Screen interface globals
screen_track = 1


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
  print("track", track)
  tab.print(sel)
  local seq = sequence[track]
  local attr = "fx_"..idx.."_level"
  local was = seq[sel.first][attr]
  for i=sel.first,sel.last,1 do
    seq[i][attr] = nil
  end
  if was ~= nil and was > 0 then 
    seq[sel.first][attr] = 0
  else
    seq[sel.first][attr] = 1
    if sel.last < 64 then
      seq[sel.last + 1][attr] = 0
    elseif sel.first ~= 1 then
      seq[1][attr] = 0
    end
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
  engine.playStep(track, pos, playheads[track].actual_rate, loop_len)
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
  },
  
  fx1 = {
    x = 1,
    y = 3,
    modes =  {MODE_SEQUENCE, MODE_CUE},
    apply = function (track, sel)
      apply_fx(1, track, sel)
    end,
    onPress = function (track)
      engine.setFx(track, 1, "level", 1)
    end,
    onReleaseAlways = function (track)
      engine.setFx(track, 1, "level", 0)
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
      engine.setFx(track, 2, "level", 1)
    end,
    onReleaseAlways = function (track)
      engine.setFx(track, 2, "level", 0)
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
      engine.setFx(track, 3, "level", 1)
    end,
    onReleaseAlways = function (track)
      engine.setFx(track, 3, "level", 0)
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
      engine.setSynth(track, "rate", 2)
    end,
    onRelease = function (track)
      if tools.slow.pressed then
        engine.setSynth(track, "rate", 0.5)
      else
        engine.setSynth(track, "rate", 1)
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
        local ph = playheads[track]
        local offset = ph.seq_pos - ph.loop_start
        print("looping", track, sel.first, sel.last)
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
    onRelease = function(track)
      engine.setSynth(track, 'loop', pressed_loop_len)
    end,
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
    onRelease = function(track)
      engine.setSynth(track, 'loop', pressed_loop_len)
    end,    
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
    onRelease = function(track)
      engine.setSynth(track, 'loop', pressed_loop_len)
    end,    
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
      engine.setSynth(track, "forward", -1)
    end,
    onRelease = function(track)
      engine.setSynth(track, "forward", 1)
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
          print("cut", i)
          tab.print(seq[i])
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
  if mode == MODE_CUE and track_cued(track) then
    -- pass
  elseif step.lock_pos or step.lock_rate or step.lock_subdivision or looped or p.teleport or was_cued[track] then
    -- print ("playing step", step.buf_pos, step.rate, step.subdivision)
    engine.playStep(track, step.buf_pos, step.rate, step.subdivision or 0)
    p.teleport = false
    was_cued[track] = false
  end
  for k, v in pairs(step) do
    if util.string_starts(k, "fx_") then
      local parts = tab.split(k, "_")
      local idx = tonumber(parts[2])
      local attr = parts[3]
      -- print("fx", track, idx, attr, v)
      engine.setFx(track, idx, attr, v)
    end
  end  
  p.buf_pos = step.buf_pos
  p.rate = step.rate
  grid_dirty = true
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
    advance_playhead(track)
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
    clock.sync(1/8.0)
    clock.sleep(1/30.0)
    redraw()
  end
end

function active_selection(track)
  if step_selections[track] ~= nil then
    print("step sel")
    tab.print(step_selections[track])
    return step_selections[track]
  end
  local section_sel = section_selections[track]
  print("section_sel", section_sel)
  if section_sel ~= nil and next(section_sel.held) ~= nil then
    return {
      first = mul_but_oneindex(section_sel.first, 16),
      last = mul_but_oneindex(section_sel.last, 16) + 15,
    }
  end
end

function manage_selection(z, pressed, selections, persist)
  local apply_tools = false
  if pressed ~= nil then
    local current_selection = selections[pressed.track]
    pressed_loop_len = 0
    if z == 1 and current_selection == nil then
      -- Begin selection
      local held = {}
      held[pressed.index] = true
      print ("begin selection")
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
        selections[pressed.track] = nil
      else
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
    elseif not persist and selections[pressed.track] ~= nil and apply_tools and mode == MODE_CUE and cue_record_states[pressed.track] ~= MODE_PLAYING then
      if current_selection.last ~= current_selection.first then
        pressed_loop_len = current_selection.last - current_selection.first + 1
      end
      was_cued[pressed.track] = true
      engine.playStep(pressed.track, current_selection.first, playheads[pressed.track].actual_rate, pressed_loop_len)
    end
  end
end

function on_loop(track)
  local state = seq_record_states[track]
  if state == RECORD_RECORDING then
    -- stopping recording and monitoring happens as soon as the next slice plays.
    seq_record_states[track] = RECORD_PLAYING
    -- automatically unmute a track as soon as it finishes recording, since "mute and record" is the trick for "don't overdub"
    if params:get(pn("mute", track)) > 0 then
      params:set(pn("mute", track), 0)
    end
    -- calculate the min and max amplitudes
    local lowestAmp = 1
    local highestAmp = 0.00001
    for i=1,129,1 do
      lowestAmp = math.min(amplitudes[track][i] or 1, lowestAmp)
      highestAmp = math.max(amplitudes[track][i] or 0.00001, highestAmp)
    end
    amplitudes[track].lowest = lowestAmp
    amplitudes[track].highest = highestAmp
  elseif state == RECORD_ARMED then
    -- starting recording happens instead of playing a slice.
    seq_record_states[track] = RECORD_RECORDING
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
    -- pass ?
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
    params:set(pn("mute", track), params:get(pn("mute", track)) > 0 and 0 or 1)
  end
  -- Tools
  local tool = lookup_tool(x, y, mode)
  if tool ~= nil then
    if tab.contains(tool.modes, mode) then
      if z == 1 then
        tool.pressed = true
        if tool.apply ~= nil and mode == MODE_SEQUENCE then
          for track=1,4,1 do
            tool.apply(track, active_selection(track))
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
          end        end
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
  manage_selection(z, pressed, section_selections, true)
  
  -- Step selection
  pressed = step_for_button(x, y)
  manage_selection(z, pressed, step_selections, select_held)
  if pressed ~= nil and select_held then froze = true end

end

function rounded_actual_pos(track)
  local ph = playheads[track]
  local now = clock.get_beats()/ph.division
  local projected = ph.actual_rate * (now-ph.actual_timestamp) + ph.actual_buf_pos + 1 -- actual_buf_pos is 0-indexed for now
  return util.round(projected, 1)
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
  elseif path == "/report" then
    local track = args[1]
    local pos = args[2]
    local rate = args[3]
    local loop = args[4]
    local buf_tempo = args[5]
    local ph = playheads[track]
    ph.actual_buf_pos = pos
    ph.actual_rate = rate
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
  
  -- Per track
  for track=1,4,1 do
    local record_x = 5
    local record_y = mul_but_oneindex(track, 2)
    local state = record_states[track]
    if state == RECORD_PLAYING then
      g:led(record_x, record_y, INACTIVE)
    elseif state == RECORD_MONITORING then
      g:led(record_x, record_y, SELECTED)
    elseif state == RECORD_RESAMPLING then
      g:led(record_x, record_y, grid_breathe <= 12 and SELECTED or 0)
    elseif state == RECORD_ARMED then
      g:led(record_x, record_y, SELECTED*grid_flash)
    elseif state == RECORD_RECORDING then
      g:led(record_x, record_y, grid_breathe)
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
      if mode == MODE_SEQUENCE then
        local step_data = sequence[step.track][step.index]
        local amp1 = amplitudes[step.track][mul_but_oneindex(step_data.buf_pos, 2)] or 0.000001
        local amp2 = amplitudes[step.track][mul_but_oneindex(step_data.buf_pos, 2) + 1] or 0.000001
        local logAmp = math.log( (amp1+amp2) / (2*highest) )
        
        if step.index >= playhead.loop_start and step.index <= playhead.loop_end then
          level = math.max(level, 12 + math.floor(12*logAmp/range), IN_LOOP)
        else
          level = math.max(level, 6 + math.floor(6*logAmp/range), level)          
        end
      end
      if mode == MODE_CUE then
        local amp1 = amplitudes[step.track][mul_but_oneindex(step.index, 2)] or 0.000001
        local amp2 = amplitudes[step.track][mul_but_oneindex(step.index, 2) + 1] or 0.000001

        local logAmp = math.log( (amp1+amp2) / (2*highest) )
        level = math.max(level, 10 + math.floor(10*logAmp/range), 1)
      end
      if selection ~= nil then
        if step.index >= selection.first and step.index <= selection.last then
          level = math.max(level, SELECTED)
        end
      end
      if mode == MODE_SEQUENCE and step.index == playhead.seq_pos then
        level = ACTIVE
      end
      if mode == MODE_CUE and step.index == math.floor(playhead.actual_buf_pos) + 1 then
        level = ACTIVE
      end
      g:led(x, y, level)
    end
  end
end

function sync_every_beat()
  while true do
    clock.sync(1)
    b = clock.get_beats()
    t = clock.get_tempo()
    engine.tempo_sync(b, t/60.0)
  end
end


-- param name
function pn(base, track)
  return base .. "_" .. track
end

function init()
  for track=1,4,1 do
    params:add_group("Track "..track, 20)
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
      engine.level(track, params:get(pn("mute", track)) > 0 and 0 or level)
    end)
    params:add_binary(pn("mute", track), "mute", "toggle", 0)
    params:set_action(pn("mute", track), function(mute)
      engine.level(track, mute > 0 and 0 or params:get(pn("level", track)))
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
  clock.run(sync_every_beat)
  
  for track=1,4,1 do
    clock.run(sequencer_clock, track)
  end
  clock.run(grid_clock)
  clock.run(screen_clock)
end

function enc(n, d)
  if n == 1 then
    screen_track = mod_but_oneindex(math.floor(screen_track + d), 4)
  end
end

function key(n, z)
  if n == 2 then
    if z == 1 then
      record_press_initiated(screen_track)
    else
      record_released(screen_track)
    end
  end
end

function redraw()
  screen.clear()
  for track=1,4,1 do
    -- The audio
    local track_start_y = mul_but_oneindex(track, 14)
    
    for slice=1,127,1 do
      local lamp = 1
      if amplitudes[track][slice] ~= nil then
        lamp = math.max(8+math.log(amplitudes[track][slice]), 1)        
      end
      screen.move(slice, track_start_y+4)
      screen.move_rel(0, lamp/2)
      local level = 5
      if params:get(pn("mute", track)) > 0 then
        level = 2
      end
      screen.level(level)
      screen.line_rel(0, -1 * lamp)
      screen.stroke()
      screen.level(0)
    end
    if track == screen_track then
      screen.move(0, track_start_y + 5)
      screen.level(15)
      screen.line_rel(129, 0)
      screen.stroke()
    end
    
    local ph = playheads[track]
    screen.move(ph.actual_buf_pos*2, track_start_y)
    screen.level(15)
    screen.line_rel(0, 8)
  end
  if mode == MODE_SEQUENCE then
    screen.move(0, 60)
    screen.level(10)
    if params:get(pn("mute", screen_track)) > 0 then
      if record_states[screen_track] == RECORD_PLAYING then
        screen.text("mute")
      elseif record_states[screen_track] == RECORD_RECORDING then
        screen.text("rec")
      elseif record_states[screen_track] == RECORD_ARMED then
        screen.text("arm")
      elseif record_states[screen_track] == RECORD_MONITORING then
        screen.text("monitor")        
      elseif record_states[screen_track] == RECORD_RESAMPLING then
        screen.text("rsmpl")          
      end      
    else
      if record_states[screen_track] == RECORD_PLAYING then
        screen.text("play")
      elseif record_states[screen_track] == RECORD_RECORDING then
        screen.text("dub")
      elseif record_states[screen_track] == RECORD_MONITORING then
        screen.text("monitor")        
      elseif record_states[screen_track] == RECORD_ARMED then
        screen.text("arm")
      elseif record_states[screen_track] == RECORD_RESAMPLING then
        screen.text("rsmpl")           
      end
    end  
  end
  screen.stroke()  
  screen.update()
end
