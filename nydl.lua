tab = require 'tabutil'

engine.name = 'NotYourDreamLooper'

g = grid.connect()

-- Brightnesses
OFF = 0
IN_LOOP = 3
IN_LOOP_SECTION = 2
INACTIVE = 4
INTERESTING = 12
SELECTED = 8
ACTIVE = 15

-- Modes
MODE_SOUND = 1
MODE_SEQUENCE = 2
MODE_CUE = 3

-- Record states
RECORD_PLAYING = 1
RECORD_MONITORING = 2
RECORD_ARMED = 3
RECORD_RECORDING = 4
RECORD_SOS = 5

-- Global script data
sequence = { {}, {}, {}, {} }
pattern_buffer = nil
playheads = {}
step_selections = {nil, nil, nil, nil}
section_selections = {nil, nil, nil, nil}
record_states = {1, 1, 1, 1}
record_timers = {nil, nil, nil, nil}
mute_states = {false, false , false, false}
select_held = false
froze = false
mode = MODE_SOUND

-- Tools
tools = {
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
        ph.loop_start = sel.first
        ph.loop_end = sel.last
        if ph.seq_pos > ph.loop_end or ph.seq_pos < ph.loop_start then
          ph.seq_pos = ph.loop_start + (offset % (ph.loop_end - ph.loop_start + 1))
        end
      end
    end,
  },
  cut = {
    x = 1,
    y = 7,
    pressed = false,
    modes = {MODE_SOUND, MODE_SEQUENCE, MODE_CUE},
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
          seq[i].buf_pos = i
          seq[i].rate = 1
          seq[i].subdivision = nil
          seq[i].lock_pos = false
          seq[i].lock_rate = false
          seq[i].lock_subdivision = false
        end
      end
    end,
  },
  copy = {
    x = 2,
    y = 7,
    pressed = false,
    modes = {MODE_SOUND, MODE_SEQUENCE},
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
        print("pattern buffer")
        for i, p in ipairs(pattern_buffer) do
          tab.print(p)
        end
      end      
    end,
  },
  paste = {
    x = 3,
    y = 7,
    pressed = false,
    modes = {MODE_SOUND, MODE_SEQUENCE},
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
  x_0 = v.x - 1
  y_0 = v.y - 1
  local idx = x_0*8 + y_0
  tools_by_coordinate[idx] = k
end

function lookup_tool(x, y)
  x_0 = x - 1
  y_0 = y - 1 
  local idx = x_0*8 + y_0
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

function default_next(step)
  -- The default next step if our parameters don't change. A stuttered step keeps resetting; otherwise advance
  return {
    buf_pos = (step.subdivision == nil) and (step.buf_pos) or (step.buf_pos + step.rate),
    rate = step.rate,
    subdivision = step.subdivision,
    lock_pos = false,
    lock_rate = false,
    lock_subdivision = false,
  }
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
  if record_states[track] == RECORD_RECORDING then
    p.buf_pos = p.seq_pos
    p.rate = 1
    if looped then
      engine.record(track, p.seq_pos)
    end
    grid_dirty = true
    return
  elseif step.lock_pos or step.lock_rate or step.lock_subdivision or looped then
    print ("playing step", step.buf_pos, step.rate, step.subdivision)
    engine.playStep(track, step.buf_pos, step.rate, step.subdivision or 64.0)
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
  if x == 7 or x == 8 then
    local section = (x-6) + 2*((y-1)%2) 
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
      grid_dirty = true
      apply_tools = true
    elseif z == 1 then
      current_selection.held[pressed.index] = true
      local sorted = tab.sort(current_selection.held)
      if current_selection.first == current_selection.last and current_selection.first == pressed.index and #sorted == 1 then
        current_selection[pressed.track] = nil
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
    if selections[pressed.track] ~= nil and apply_tools then
      -- Apply any tools to the new selection
      for k, tool in pairs(tools) do
        if tool.pressed and tool.apply ~= nil then
          tool.apply(pressed.track, active_selection(pressed.track))
        end
      end
    else
      -- Pass
    end
  end
end

function on_loop(track)
  local state = record_states[track]
  if state == RECORD_RECORDING then
    -- stopping recording and monitoring happens as soon as the next slice plays.
    record_states[track] = RECORD_PLAYING
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
    record_states[track] = RECORD_MONITORING
    -- start monitoring
    engine.monitor(track)
  elseif state == RECORD_MONITORING then
    record_states[track] = RECORD_ARMED
  elseif state == RECORD_ARMED then
    -- pass ?
  elseif state == RECORD_RECORDING then
    -- pass ?
  elseif state == RECORD_SOS then
    -- TODO: Stop recording
    record_states[track] = RECORD_MONITORING
  end  
end

function record_longpressed(track)
  local state = record_states[track]
  if state == RECORD_MONITORING then
    record_states[track] = RECORD_PLAYING
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

function g.key(x, y, z)
  -- mode selector
  if z == 1 and x == 1 and y == 1 then
    mode = MODE_SOUND
    grid_dirty = true
    return
  end
  if z == 1 and x == 2 and y == 1 then
    mode = MODE_SEQUENCE
    grid_dirty = true
    return
  end
  if z == 1 and x == 3 and y == 1 then
    mode = MODE_CUE
    grid_dirty = true
    return
  end
  
  -- Select
  if z == 1 and x == 1 and y == 8 then
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
  if z == 0 and x == 1 and y == 8 then
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
  if x == 6 and y%2 == 1 then
    local track = div_but_oneindex(y, 2)
    if z == 1 then
      record_press_initiated(track)
    else
      record_released(track)
    end
  end  
  -- Mute
  if z == 1 and x == 6 and y%2 == 0 then
    local track = div_but_oneindex(y, 2)
    mute_states[track] = not mute_states[track]
  end
  -- Tools
  local tool = lookup_tool(x, y)
  if tool ~= nil then
    if tab.contains(tool.modes, mode) then
      if z == 1 then
        tool.pressed = true
        if tool.apply ~= nil then
          for track=1,4,1 do
            tool.apply(track, active_selection(track))
          end
        end
        if tool.handle ~= nil then
          tool.handle()
        end
      else
        tool.pressed = false
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

  if mode == MODE_SOUND then
    sound_key(x, y, z)
  elseif mode == MODE_SEQUENCE then
    sequence_key(x, y, z)
  elseif mode == MODE_CUE then
    cue_key(x, y, z)
  end
end

function sound_key(x, y, z)
end

function sequence_key(x, y, z)
end

function cue_key(x, y, z)
  local step = step_for_button(x, y)
  if step ~= nil then
    print(step.step)
  end
end

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
    local record_x = 6
    local record_y = mul_but_oneindex(track, 2)
    local state = record_states[track]
    if state == RECORD_PLAYING then
      g:led(record_x, record_y, INACTIVE)
    elseif state == RECORD_MONITORING then
      g:led(record_x, record_y, SELECTED)
    elseif state == RECORD_ARMED then
      g:led(record_x, record_y, SELECTED*grid_flash)
    elseif state == RECORD_RECORDING then
      g:led(record_x, record_y, grid_breathe)
    elseif state == RECORD_SOS then
      g:led(record_x, record_y, ACTIVE)
    end
    
    local mute_x = record_x
    local mute_y = record_y + 1
    g:led(mute_x, mute_y, mute_states[track] and INACTIVE or SELECTED)
  end
end

function grid_redraw()
  g:all(0)
  
  -- Modes
  g:led(1, 1, mode == MODE_SOUND and SELECTED or INACTIVE)
  g:led(2, 1, mode == MODE_SEQUENCE and SELECTED or INACTIVE)
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
  g:led(1, 8, select_held and ACTIVE or (select_persist and SELECTED or INACTIVE))
  for k, v in pairs(tools) do
    if tab.contains(v.modes, mode) then
      g:led(v.x, v.y, v.pressed and ACTIVE or INACTIVE)
    end
  end
  -- Sections
  for x=7,8,1 do
    for y=1,8,1 do
      local section = section_for_button(x, y)
      local selection = section_selections[section.track]
      local playhead = playheads[section.track]
      local loop_start_section = div_but_oneindex(playhead.loop_start, 16)
      local loop_end_section = div_but_oneindex(playhead.loop_end, 16)
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
      if (mode == MODE_SOUND or mode == MODE_CUE) and section.index == div_but_oneindex(playhead.buf_pos, 16) then
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
      if mode == MODE_SEQUENCE and step.index >= playhead.loop_start and step.index <= playhead.loop_end then
        g:led(x, y, IN_LOOP)
      end
      if selection ~= nil then
        if step.index >= selection.first and step.index <= selection.last then
          g:led(x, y, SELECTED)
        end
      end
      if mode == MODE_SEQUENCE and step.index == playhead.seq_pos then
        g:led(x, y, ACTIVE)
      end
      if (mode == MODE_SOUND or mode == MODE_CUE) and step.index == playhead.buf_pos then
        g:led(x, y, ACTIVE)
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
  end
end

function init()
  clock.run(sync_every_beat)
  
  for track=1,4,1 do
    clock.run(sequencer_clock, track)
  end
  clock.run(grid_clock)
end

