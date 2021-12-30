b = Buffer.read(s, "/Users/naomiseyfer/Documents/Octatrack/Headless Horseman/Drum Loops/DRLoop4.wav")
b.numChannels
(
SynthDef.new(\playSlice, { |out, buf, bufTempo, clockTempo, pos, rate=1, loop=30, gate=1|
	var r = rate*(bufTempo/clockTempo)*BufRateScale.kr(buf);
	var start = BufRateScale.kr(buf) * SampleRate.ir  * (pos/bufTempo);
	var end = start + (BufRateScale.kr(buf) * SampleRate.ir * (loop/bufTempo));
	var phasor = Phasor.ar(rate: r, start: start, end: end, resetPos: start);
	Out.ar(out, EnvGen.kr(Env.asr(0.01, 1.0, 0.01, curve: 0), gate, doneAction: Done.freeSelf) * BufRd.ar(2, buf, phasor));
}).add
)
TempoClock.tempo = 2
(
Pbind(
	\instrument, \playSlice,
	\buf, b,
	\bufTempo, 16/b.duration,
	\clockTempo, 16/b.duration,
	\pos, Pseq([0, 0, 2, 3, 4, 5, 15, 15, 0, 1, 2, 4, 4, 15, 0, 15]),
	\legato, 1,
	\dur, b.duration/8,
	\rate, 1.0,
).play
)

(
{ PlayBuf.ar(2, b) }.play
)

s.sampleRate