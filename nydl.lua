tab = require 'tabutil'

g = grid.connect()

-- Brightnesses
OFF = 0
IN_LOOP = 2
INACTIVE = 4
INTERESTING = 12
SELECTED = 8
ACTIVE = 15

-- Modes
MODE_SOUND = 1
MODE_SEQUENCE = 2
MODE_CUE = 3

-- Record states
NOT_RECORDING = 1
RECORDING_ONCE = 2
RECORDING_MANY = 3
RECORDING_CUE = 4
PRIMED = 5

sequence = { {}, {}, {}, {} }
playheads = {}
step_selections = {nil, nil, nil, nil}
section_selections = {nil, nil, nil, nil}
record_states = {1, 1, 1, 1}
mute_states = {false, false , false, false}
mode = MODE_SOUND

-- Grid data
grid_dirty = true
grid_flash = 0
grid_breathe = 5

for track=1,4,1 do
  playheads[track] = {
    seq_pos = 1,
    rate = 1,
    buf_pos = 1,
    loop_start = 1, -- loop within sequence
    loop_end = 64,  -- loop within sequence
    division = 0.25, -- beats per step in sequence
  }
  
  for step=1,64,1 do
    sequence[track][step] = {
      buf_pos = nil, -- Jump to this beat in the buffer
      rate = nil, -- Set the playback to this rate
      subdivision = nil, -- Do the action every x beats, for stutter
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
  p.seq_pos = p.seq_pos + 1
  if p.seq_pos > p.loop_end then
    p.seq_pos = p.loop_start
  end
  step = sequence[track][p.seq_pos]
  if step.beat ~= nil then
    p.buf_pos = step.buf_pos
  else
    p.buf_pos = mod_but_oneindex(p.buf_pos + p.rate, 64)
  end
  if step.rate ~= nil then
    p.rate = step.rate
  end
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
  while true do
    clock.sync(playheads[track].division)
    advance_playhead(track)
  end
end

function grid_clock()
  while true do -- while it's running...
    clock.sleep(1/30) -- refresh at 30fps.
    if grid_dirty then -- if a redraw is needed...
      grid_redraw() -- redraw...
      grid_dirty = false -- then redraw is no longer needed.
    end
  end
end

function manage_selection(z, pressed, selections, persist)
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
    elseif z == 1 then
      if pressed.index < current_selection.first then
        current_selection.first = pressed.index
      elseif pressed.index > current_selection.last then
        current_selection.last = pressed.index
      elseif current_selection.held[current_selection.first] then
        current_selection.last = pressed.index
      elseif current_selection.held[current_selection.last] then
        current_selection.first = pressed.index
      elseif current_selection.first == current_selection.last and current_selection.first == pressed.index then
        -- pressing a selected thing again clears the selection
        selections[pressed.track] = nil
      else
        current_selection.first = pressed.index
        current_selection.last = pressed.index
      end
     current_selection.held[pressed.index] = true
    elseif z == 0 and current_selection ~= nil then
      current_selection.held[pressed.index] = nil
      if next(current_selection.held) == nil and not current_selection.persist then
        selections[pressed.track] = nil
      elseif not current_selection.persist then
        local sorted = tab.sort(current_selection.held)
        current_selection.first = sorted[1]
        current_selection.last = sorted[#sorted]
      end
    end
    if selections[pressed.track] ~= nil then
      tab.print(selections[pressed.track])
    else
      print("no selection for", pressed.track)
    end
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
  -- mutes
  if z == 1 and x == 6 and y%2 == 0 then
    local track = div_but_oneindex(y, 2)
    mute_states[track] = not mute_states[track]
  end
  
  -- Section selection
  local pressed = section_for_button(x, y)
  manage_selection(z, pressed, section_selections, true)
  
  -- Step selection
  pressed = step_for_button(x, y)
  manage_selection(z, pressed, step_selections, false)
  
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

function grid_redraw()
  g:all(0)
  -- Modes
  g:led(1, 1, mode == MODE_SOUND and SELECTED or INACTIVE)
  g:led(2, 1, mode == MODE_SEQUENCE and SELECTED or INACTIVE)
  g:led(3, 1, mode == MODE_CUE and SELECTED or INACTIVE)

  -- Sections
  for x=7,8,1 do
    for y=1,8,1 do
      local section = section_for_button(x, y)
      local selection = section_selections[section.track]
      local playhead = playheads[section.track]
      local loop_start_section = mod_but_oneindex(playhead.loop_start, 16)
      local loop_end_section = mod_but_oneindex(playhead.loop_end, 16)
      if mode == MODE_SEQUENCE and section.index >= loop_start_section and section.index <= loop_end_section then
        g:led(x, y, IN_LOOP)
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
  -- Do the thing
  g:refresh()
end

function init()
  for track=1,4,1 do
    clock.run(sequencer_clock, track)
  end
  clock.run(grid_clock)
end

