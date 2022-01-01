// NotYourDreamLooper can play slices of a buffer and record to it.

NydlTrack {
	var <server, <track, <division, <sendBus, <buffer, <bufferTempo, <synth, <monitorSynth, <recording, <level, <toFx, <fx, <fxControls;

	*new { |server, track, division, sendBus, filename=nil, fileTempo=nil, fileBeats=nil|
		var buffer, bufferTempo;
		var tempo = TempoClock.tempo;
		var toFx = 4.collect {Bus.audio(server: server, numChannels: 2)};
		var fx = nil!3;
		var fxControls = [(), (), ()];

		fx[0] = Synth(\decimateFx, [
			in: toFx[0],
			out: toFx[1],
		], addAction: \addToTail);
		fx[1] = Synth(\svfFx, [
			in: toFx[1],
			out: toFx[2],
		], target: fx[0], addAction: \addAfter);
		fx[2] = Synth(\sendFx, [
			in: toFx[2],
			out: toFx[3],
		], target: fx[1], addAction: \addAfter);

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
			server, track, division, sendBus, buffer, bufferTempo, nil, nil, false, 1, toFx, fx, fxControls);
	}

	out {
		^toFx[3];
	}

	free {
		if (synth != nil, {synth.free});
		if (monitorSynth != nil, {monitorSynth.free});
		buffer.free;
		fx.do {|x| x.free};
		toFx.do {|x| x.free};
	}

	setFx { |fxIdx, id, value|
		fxControls[fxIdx][id] = value;
		fx[fxIdx].set(id, value);
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
			out: toFx[0],
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
				monitorSynth = Synth(\monitor, [out: toFx[0]]);
			});
		});
	}

	record { |pos|
		if (synth != nil, {
			synth.set(\gate, 0);
		});
		recording = true;
		synth = Synth(\record, [
			out: toFx[0],
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
	var <tracks, <ampDef, <sendBus, <sendChain;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	initTracks {
		tracks = 4.collect { |i|
			NydlTrack.new(Server.default, i+1, 0.25, sendBus, nil, nil, nil);
		};
		{
			Mix.ar(tracks.collect({|t| In.ar(t.out, 2)}) ++ [sendChain.last.ar(2)]).tanh
		}.play(addAction: \addToTail);
	}

	alloc {
		var fadeEnv = Env.asr(0.01, 1.0, 0.01, curve: 0);
		var luaOscAddr = NetAddr("localhost", luaOscPort);
		sendBus = Bus.audio(Server.default, numChannels: 2);
		sendChain = 2.collect { NodeProxy.new };
		sendChain[0].source = sendBus;
		sendChain[1].source = { |delay=0.2, repeats=5|
			CombC.ar(\in.ar(0!2), 2, delay, delay*repeats);
		};
		sendChain[0] <>> sendChain[1];

		SynthDef.new(\svfFx, { |in, out, level, cutoff=1000, res=0.1, low=0, band=1, high=0|
			var i = In.ar(in, 2);
			Out.ar(out, level.if(SVF.ar(i, cutoff, res, low, band, high), i));
		}).add;

		SynthDef.new(\decimateFx, { |in, out, level, rate=1000, smooth=0.2|
			var i = In.ar(in, 2);
			Out.ar(out, level.if(SmoothDecimator.ar(i, rate, smooth), i));
		}).add;

		SynthDef.new(\sendFx, {|in, out, level, send|
			var i = In.ar(in, 2);
			Out.ar(send, level*i);
			Out.ar(out, i);
		}).add;

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

		this.addCommand("setFx", "iisf", { |msg|
			var track = msg[1].asInteger - 1;
			var fxIdx = msg[2].asInteger - 1;
			var control = msg[3].asSymbol;
			var value = msg[4].asFloat;
			if (tracks == nil, {
				this.initTracks;
			});
			tracks[track].setFx(fxIdx, control, value);
		});
	}

	free {
		tracks.do { |t| t.free};
		ampDef.free;
		sendBus.free;
		sendChain.do { |x|
			x.free
		};
	}
}