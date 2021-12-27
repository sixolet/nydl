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
    print("btn", x, y)

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

function manage_selection(pressed, selections, persist)
  if pressed ~= nil then
  local current_selection = selections[pressed.track]
  if z == 1 and current_selection == nil then
    -- Begin selection
    selections[pressed.track] = {
      first = pressed.index,
      last = pressed.index,
      held = {pressed.index = true},
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
  manage_selection(pressed, section_selections, true)
  
  -- Step selection
  manage_selection(pressed, step_selections, false)
  
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

  for track=1,4,1 do
    local track_y = (track-1) * 2
    local p = playheads[track]
    local buttons
    -- mutes are bright when false
    g:led(6, mul_but_oneindex(track, 2) + 1, mute_states[track] and INACTIVE or ACTIVE)
    -- sequence view
    if mode == MODE_SEQUENCE then
      buttons = buttons_for_step(track, p.seq_pos)
      -- Light the looped section
      local section_start = 0
      for s=1,4,1 do
        local section_x = 6 + mod_but_oneindex(s, 2)
        local section_y = track_y + div_but_oneindex(s, 2)
        section_start = mul_but_oneindex(s, 16)
        if s == selected_sections[track] then
          g:led(section_x, section_y, SELECTED)
        elseif (section_start+15) >= p.loop_start and section_start <= p.loop_end then
          g:led(section_x, section_y, IN_LOOP)
        end
        if s == buttons.section then
          for i=section_start,section_start+15,1 do
            if i >= p.loop_start and i <= p.loop_end then
              g:led(8 + mod_but_oneindex(i, 8), track_y + div_but_oneindex(i-section_start, 8), IN_LOOP)
            end
          end
        end
      end      
    else
      buttons = buttons_for_step(track, p.buf_pos)
    end

    -- Light the playheads bright
    g:led(buttons.coarse_x, buttons.coarse_y, ACTIVE)
    g:led(buttons.fine_x, buttons.fine_y, ACTIVE)
  end
  g:refresh()
end

function init()
  for track=1,4,1 do
    clock.run(sequencer_clock, track)
  end
  clock.run(grid_clock)
end

