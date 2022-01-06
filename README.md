# nydl

nydl is not your dream looper (It might be mine. Time will tell). It's
a New Years Day looper. It's a four-channel beat-synced looper for
Norns and Grid.

## Getting Started

Install nydl, restart Norns. Plug in Grid. Start nydl.

Arrange some sound to go into your Norns, ideally one that is synced
to the Norns clock. Now turn down Norns' own monitor of your
sound. We're going to be monitoring from within the script.


## Overview

When you start nydl, Norns will show each track and the playhead
within it. You can select a track with E1. K2 is the *manticore* (see
the whole section about the manticore, below).

When you start nydl, your grid will look like this:

![](nydl-hello.gif)

To the left, there is the *sigil*. It contains tools for navigating
nydl, and for editing your sound.

In the middle there are per-track tools. Each track is represented by
two rows on the Grid. The left of this section has one manticore and
one mute per track, and the four buttons per-track to the right are
section indicators and selectors.

To the right is your sound, with a button lit up to represent your
playhead.

## The Manticore

In the per-track tools section of the grid, the top left button of the
per-track controls for every track (the one that's darker) is the
*manticore* button. On Norns itself, K2 is the *manticore* button for
the selected track.

Aside from being a mythical creature, this *manticore* is a
portmanteau of "monitor" and "record", and that's what you'll do with
this button.

Press that manticore for a channel, and you should hear your input
monitored on that channel. Press it once more, and it should begin
flashing quickly. The quick flashing indicates you aren't recording
quite yet, but you will be at the next loop point.

Soon the next loop point will arrive, and the manticore will start
breathing, indicating it is recording. It'll do this for one loop, and
then go dark, muting the monitor and replacing it with the recording
you just made. You can always press the manticore again, starting
monitoring for the track again, and pressing it yet again will
overdub.

If you're monitoring and you want to stop monitoring without
recording, long-press the manticore and you'll go back to just playing
the loop.

If you change tempo, monitoring after the change will trigger a
resampling phase for that track. You will be prevented from recording
until the resample is complete. You will be prevented from changing
tempo while monitoring or recording.

## The Mute

The mute button for each track is right under the manticore. It mutes
the recording, but not the monitor. To replace the sound on a track
instead of overdubbing, record to it while the recording is
muted. When the manticore is done recording, along with muting the
monitor, it'll unmute the track for you so it keeps playing
seamlessly.

## The Sigil

The tools at your disposal are arranged in a *sigil* to the left of
your grid. The pattern keeps you from having to count buttons.

### Edit vs. Cue

The first row of the sigil selects the mode for the grid. The meaning
of "recording" and "monitoring" are different in each mode. The two
modes have independent monitoring status, and you can't switch modes
while recording.

**Edit mode** The top left button selects *edit mode*.

  In edit mode, monitoring monitors the input sound.

  In edit mode, recording records the input sound.

  In edit mode, the right half of the grid represents steps in a
  sequence, each of which may contain a parameter lock; lockable
  parameters include a buffer position to jump to, a rate to play at,
  a rate to stutter the loop at, or effect parameters. You have 64
  steps in your sequence, available 16 steps at a time on 4 pages. The
  pages are accessed in the middle section of the grid. In edit mode
  you can select one or more steps by pressing a range of buttons on a
  track, and then press the button for a tool on the sigil, applying
  that tool to that range of steps. It also works to press a page
  button or a range of page buttons; this will apply the tool to the
  whole page.

**Cue mode** The button on the other side of the sigil from the edit
  mode button is the cue mode button. 

  In cue mode, monitoring determines which tracks your tools from the
  sigil will be applied to, and which tracks are available for cueing.

  In cue mode, recording (will, yet unimplemented) records your series
  of cues into the sequence.

  In cue mode, the right half of the grid represents your sound. If
  you have a sequence with jumps, you'll see the playhead jump to
  follow the sequence. You can cue specific slices by pressing buttons
  or ranges of buttons. Pressing sigil buttons cues their effects
  wherever the playhead currently is.