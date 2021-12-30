// NotYourDreamLooper can play slices of a buffer and record to it.

NydlTrack {
	var <server, <division, <buffer, <bufferTempo, <synth, <monitorSynth, <recording, <out;

	*new { |server, division, filename=nil, fileTempo=nil, fileBeats=nil|
		var buffer, bufferTempo;
		var tempo = TempoClock.tempo;
		var out = Bus.new(\audio, numChannels: 2, server: server);
		if (filename != nil, {
			try {
				buffer = Buffer.read(server, filename);
				if (fileTempo != nil, {
				});
			} { |error|
				buffer = Buffer.alloc(server, server.sampleRate*((64*division/tempo) + 1), 2);
				bufferTempo = tempo;
			}
		}, {
			buffer = Buffer.alloc(server, server.sampleRate*((64*division/tempo) + 1), 2);
			bufferTempo = tempo;
		});
		super.newCopyArgs(
			server, division, buffer, bufferTempo, nil, nil, false, out);
	}

	free {
		if (synth != nil, {synth.free});
		if (monitorSynth != nil, {monitorSynth.free});
		buffer.free;
		out.free;
	}

	playStep { |pos, rate, loop|
		if (synth != nil, {
			synth.set(\gate, 0);
		});
		if (recording && (monitorSynth != nil), {
			monitorSynth.set(\gate, 0);
			monitorSynth = nil;
			recording = false;
		});
		synth = Synth(\playSlice, [
				out: out,
				buf: buffer,
				bufTempo: bufferTempo,
				clockTempo: TempoClock.tempo,
				pos: pos,
				division: division,
				rate: rate,
				loop: loop,
				gate: 1,
			]);
	}

	monitor {
		if (monitorSynth == nil, {
			monitorSynth = Synth(\monitor, [out: out]);
		});
	}

	record { |pos|
		if (synth != nil, {
			synth.set(\gate, 0);
		});
		recording = true;
		synth = Synth(\record, [
				out: out,
				buf: buffer,
				tempo: TempoClock.tempo,
				pos: pos,
				gate: 1,
			]);
	}

}

Engine_NotYourDreamLooper : CroneEngine {
	var <tracks;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	initTracks {
		tracks = 4.collect {
			NydlTrack.new(Server.default, 0.25, nil, nil, nil);
		};
	}

	alloc {
		var fadeEnv = Env.asr(0.01, 1.0, 0.01, curve: 0);

		SynthDef.new(\playSlice, { |out, buf, bufTempo, clockTempo, pos, division, rate=1, loop=64, gate=1, level=1|
			var r = rate*(bufTempo/clockTempo)*BufRateScale.kr(buf);
			var start = BufRateScale.kr(buf) * SampleRate.ir  * (pos*division/bufTempo);
			var end = start + (BufRateScale.kr(buf) * SampleRate.ir * (loop*division/bufTempo));
			var phasor = Phasor.ar(rate: r, start: start, end: end, resetPos: start);
			var snd = BufRd.ar(2, buf, phasor);
			snd = EnvGen.kr(fadeEnv, gate, doneAction: Done.freeSelf) * snd;
			snd = level.lag(0.01) * snd;
			Out.ar(out, snd);
		}).add;

		SynthDef.new(\monitor, {|out, gate=1, level=1|
			var env = EnvGen.kr(fadeEnv, gate, doneAction: Done.freeSelf);
			Out.ar(out, env * level.lag(0.01) * SoundIn.ar([0, 1]));
		}).add;

		SynthDef.new(\record, {|out, buf, tempo, pos, division, gate=1, level=1|

			var in = SoundIn.ar([0, 1]);
			var start = SampleRate.ir  * (pos*division/tempo);
			var env = EnvGen.kr(fadeEnv, gate, doneAction: Done.freeSelf);
			RecordBuf.ar(
				in,
				buf,
				offset: start,
				recLevel: env,
				preLevel: level,
				run: 1.0,
				loop: 1.0,
				trigger: 1.0,
				doneAction: 0);
			Out.ar(out, env*PlayBuf.ar(2, buf, rate: 1.0, startPos: start, loop: 1.0));
		}).add;

		this.addCommand("playStep", "ifff", { |msg|
			var track = msg[1].asInteger - 1;
			var pos = msg[2].asFloat - 1;
			var rate = msg[3].asFloat;
			var loop = msg[4].asFloat;
			if (tracks != nil, {
				tracks[track].playStep(pos, rate, loop);
			})
		});

		this.addCommand("monitor", "i", { |msg|
			var track = msg[1].asInteger - 1;
			if (tracks != nil, {
				tracks[track].monitor;
			});
		});

		this.addCommand("record", "if", { |msg|
			var track = msg[1].asInteger - 1;
			var pos = msg[2].asFloat - 1;
			if (tracks != nil, {
				tracks[track].record(pos);
			});
		});

		this.addCommand("tempo_sync", "ff", { arg msg;
			var beats = msg[1].asFloat;
			var tempo = msg[2].asFloat;
			var beatDifference = beats - TempoClock.default.beats;
			var nudge = beatDifference % 4;
			if (nudge > 2, {nudge = nudge - 4});
			if ( (tempo != TempoClock.default.tempo) || (nudge.abs > 1), {
				TempoClock.default.beats = TempoClock.default.beats + nudge;
				TempoClock.default.tempo = tempo;
			}, {
				TempoClock.default.beats = TempoClock.default.beats + (0.05 * nudge);
			});
			if (tracks == nil, {
				this.initTracks;
			});
		});

		{ Mix.ar(tracks.collect(_.out)).tanh }.play;
	}

	free {
		tracks.do { |t| t.free};
	}
}