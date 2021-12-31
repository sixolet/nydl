// NotYourDreamLooper can play slices of a buffer and record to it.

NydlTrack {
	var <server, <track, <division, <buffer, <bufferTempo, <synth, <monitorSynth, <recording, <level, <out;

	*new { |server, track, division, filename=nil, fileTempo=nil, fileBeats=nil|
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
		^super.newCopyArgs(
			server, track, division, buffer, bufferTempo, nil, nil, false, 1, out);
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
		// Post << "Playing step with loop " << (loop > 0).if(TempoClock.tempo/(loop*division), 0) << "\n";
		synth = Synth(\playStep, [
			out: out,
			buf: buffer,
			bufTempo: bufferTempo,
			clockTempo: TempoClock.tempo,
			pos: pos,
			division: division,
			rate: rate,
			loop: loop,
			gate: 1,
			level: level
		]);
	}

	monitor { |level|
		if (level == 0, {
			if (monitorSynth != nil, {
				monitorSynth.set(\gate, 0);
				monitorSynth = nil;
			});
		}, {
			if (monitorSynth == nil, {
			monitorSynth = Synth(\monitor, [out: out]);
			});
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
			division: division,
			gate: 1,
			level: level,
			track: track,
		]);
	}

	level_ { |l|
		level = l;
		if (synth != nil, {
			synth.set(\level, l)
		});
	}

}

Engine_NotYourDreamLooper : CroneEngine {
	classvar luaOscPort = 10111;
	var <tracks, <ampDef;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	initTracks {
		tracks = 4.collect { |i|
			NydlTrack.new(Server.default, i+1, 0.25, nil, nil, nil);
		};
	}

	alloc {
		var fadeEnv = Env.asr(0.01, 1.0, 0.01, curve: 0);
		var luaOscAddr = NetAddr("localhost", luaOscPort);

		SynthDef.new(\playStep, { |out, buf, bufTempo, clockTempo, pos, division, rate=1, loop=0, gate=1, level=1|
			var r = rate*(bufTempo/clockTempo)*BufRateScale.kr(buf);
			var stepSize = BufRateScale.kr(buf) * SampleRate.ir  * (division/bufTempo);
			var start = (rate > 0).if(pos*stepSize, (pos-rate.reciprocal)*stepSize); // When reversed, start at the end of the step
			var snd = PlayBuf.ar(2, buf, r, Impulse.kr((loop > 0).if(clockTempo/(loop*division), 0)), start, 0.0, Done.none);
			snd = EnvGen.kr(fadeEnv, gate, doneAction: Done.freeSelf) * snd;
			snd = level.lag(0.01) * snd;
			Out.ar(out, snd);
		}).add;

		SynthDef.new(\monitor, {|out, gate=1, level=1|
			var env = EnvGen.kr(fadeEnv, gate, doneAction: Done.freeSelf);
			Out.ar(out, env * level.lag(0.01) * SoundIn.ar([0, 1]));
		}).add;

		SynthDef.new(\record, {|out, buf, tempo, pos, division, gate=1, level=1, track=1|

			var in = SoundIn.ar([0, 1]);
			var start = SampleRate.ir  * (pos*division/tempo);
			var env = EnvGen.kr(fadeEnv, gate, doneAction: Done.freeSelf);
			var llevel = level.lag(0.01);
			var bufPlay = PlayBuf.ar(2, buf, rate: 1.0, startPos: start, loop: 1.0);
			var ampPulse = Impulse.kr(tempo*2/division);
			var ampCounter = PulseCount.kr(ampPulse);
			SendReply.kr(
				(ampCounter > 1).if(ampPulse, 0),
				'/recordAmplitude',
				[track, ampCounter-1+(2*pos), Amplitude.kr(Mix.ar((llevel*bufPlay)+in)/2, attackTime: 0.01, releaseTime: division)]
			);
			Out.ar(out, llevel*env*bufPlay);
			RecordBuf.ar(
				in,
				buf,
				offset: start,
				recLevel: env,
				preLevel: llevel,
				run: 1.0,
				loop: 1.0,
				trigger: 1.0,
				doneAction: 0);
		}).add;

		ampDef = OSCdef.new(\recordAmplitude, { |msg, time|
			var track = msg[3].asFloat.asInteger;
			var slice = msg[4].asFloat.asInteger;
			var amp = msg[5].asFloat;
			//"Amp % % %\n".postf(track, slice, amp);
			luaOscAddr.sendMsg("/amplitude", track, slice, amp);
		}, '/recordAmplitude');


		this.addCommand("playStep", "ifff", { |msg|
			var track = msg[1].asInteger - 1;
			var pos = msg[2].asFloat - 1;
			var rate = msg[3].asFloat;
			var loop = msg[4].asFloat;
			if (tracks != nil, {
				tracks[track].playStep(pos, rate, loop);
			})
		});

		this.addCommand("monitor", "ii", { |msg|
			var track = msg[1].asInteger - 1;
			var level = msg[2].asInteger;
			if (tracks != nil, {
				tracks[track].monitor(level);
			});
		});

		this.addCommand("record", "if", { |msg|
			var track = msg[1].asInteger - 1;
			var pos = msg[2].asFloat - 1;
			if (tracks != nil, {
				tracks[track].record(pos);
			});
		});

		this.addCommand("level", "if", { |msg|
			var track = msg[1].asInteger - 1;
			var level = msg[2].asFloat;
			if (tracks != nil, {
				tracks[track].level = level;
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
		ampDef.free;
	}
}