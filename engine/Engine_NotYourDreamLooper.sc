// NotYourDreamLooper can play slices of a buffer and record to it.


NydlTrack {
	var <server, <track, <division, <sendBus, <buffer, <bufferTempo, <synth, <monitorSynth, <recording, <level, <toFx, <fx, <fxControls, <resampler;

	*new { |server, track, division, sendBus, filename=nil, fileTempo=nil, fileBeats=nil|
		var buffer, bufferTempo;
		var tempo = TempoClock.tempo;
		var toFx = 4.collect {Bus.audio(server: server, numChannels: 2)};
		var fx = nil!3;
		var fxControls = [(), (), ()];

		fx[0] = Synth(\decimateFx, [
			in: toFx[0],
			out: toFx[1],
			send: sendBus,
		], addAction: \addToTail);
		fx[1] = Synth(\svfFx, [
			in: toFx[1],
			out: toFx[2],
			send: sendBus,
		], target: fx[0], addAction: \addAfter);
		fx[2] = Synth(\sendFx, [
			in: toFx[2],
			out: toFx[3],
			send: sendBus,
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
			server, track, division, sendBus, buffer, bufferTempo, nil, nil, false, 1, toFx, fx, fxControls, nil);
	}

	load { |filename, fileTempo, cb|
		Buffer.read(server, filename, action: { |buf|
			var oldBuf = buffer;
			var readAmp;
			buffer = buf;
			bufferTempo = fileTempo;
			readAmp = Synth(\readAmp, [
				buf: buffer,
				tempo: fileTempo,
				division: division,
				gate: 1,
				track: track]);
			Routine.new({
				((64 + 16)*division).yield;
				oldBuf.free;
				readAmp.set(\gate, 0);
				cb.value;
			}).play;
		});
	}

	realloc { |div|
		var tempo = TempoClock.tempo;
		var oldBuf = buffer;
		var oldDiv = division;
		var buf = Buffer.alloc(server, server.sampleRate*((64*div/tempo) + 1), 2);
		buffer = buf;
		bufferTempo = tempo;
		division = div;
		Routine.new({
			(16*oldDiv).yield;
			oldBuf.free;
		}).play;
	}

	out {
		^toFx[3];
	}

	maybeResample { |callback|
		var difference = 64*division*(1 - TempoClock.tempo/bufferTempo).abs;
		// we can tolerate 0.1 beat (less than a 32nd note) of slop
		var tempoGood = (difference < 0.1);
		if (tempoGood, callback, { this.resample(callback) });
	}

	resample { |callback|
		resampler = Routine.new({
			var done = false;
			{ done.not }.while {
				var toTempo = TempoClock.tempo;
				var newBuffer = Buffer.alloc(server, server.sampleRate*((64*division/toTempo) + 1), 2);
				var tempoGood = true;
				// This frees itself after 16 positions
				var resamplerSynth = Synth.new(\resample, [
					oldBuf: buffer,
					oldTempo: bufferTempo,
					newBuf: newBuffer,
					newTempo: toTempo,
					division: division,
					track: track,
				]);
				16.do {
					var difference = 64*division*(1 - (TempoClock.tempo/toTempo)).abs;
					// "Debug ratio % difference % \n".postf(TempoClock.tempo/toTempo, difference);
					// we can tolerate 0.1 beat (less than a 32nd note) of slop
					tempoGood = (difference < 0.1);
					if (tempoGood, {
						division.yield;
					});
				};
				if (tempoGood, {
					var oldBuf = buffer;
					buffer = newBuffer;
					bufferTempo = toTempo;
					Post << "calling callback\n";
					callback.value;
					resampler = nil;
					done = true;
					// Wait until the old buffer is definitely not in use anymore.
					(16*division).yield;
					oldBuf.free;
				}, {
					// Tempo changed; try again in a few seconds once the user is done fucking with it.
					"Tempo changed again was % now % \n".postf(TempoClock.tempo, toTempo);
					resamplerSynth.free;
					newBuffer.free;
					5.yield;
				});
			};
		}).play;
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

	setSynth { |id, value|
		synth.set(id, value)
	}

	playStep { |pos, rate, loop|
		if (synth != nil, {
			var closureSynth = synth;
			synth.set(\gate, 0);
			// There may be a race condition when under computer control and the synth gets its
			// gate set to 0 before it ever starts, so it doesn't clean itself up.
			TempoClock.sched(4, {
				if (closureSynth.isPlaying, {
					closureSynth.free;
				});
			});
		}, {
			"no prev step to stop".postln;
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
			level: level,
			track: track,
		]);
		NodeWatcher.register(synth, assumePlaying: true);
		// "playing % id %\n".postf(synth, synth.nodeID);
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
	var <tracks, <ampDef, <reportDef, <sendBus, <returnBus, <sendSynth, <metro;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	initTracks {
		"init tracks".postln;
		tracks = 4.collect { |i|
			NydlTrack.new(Server.default, i+1, 0.25, sendBus, nil, nil, nil);
		};
		sendSynth = Synth(\sendDelay, [
			in: sendBus,
			out: returnBus,
			delay: 0.2,
			repeats: 4,
		], addAction: \addToTail);
		{
			Mix.ar(tracks.collect({|t| In.ar(t.out, 2)}) ++ [In.ar(returnBus, 2)]).tanh
		}.play(addAction: \addToTail);
	}

	alloc {
		var fadeEnv = Env.asr(0.01, 1.0, 0.01, curve: 0);
		var luaOscAddr = NetAddr("localhost", luaOscPort);
		sendBus = Bus.audio(Server.default, numChannels: 2);
		returnBus = Bus.audio(Server.default, numChannels: 2);

		SynthDef.new(\resample, { |oldBuf, oldTempo, newBuf, newTempo, division, track|
			var oldRate = (newTempo/oldTempo)*BufRateScale.kr(oldBuf);
			var oldStepSize = BufRateScale.kr(oldBuf) * SampleRate.ir  * (division/oldTempo);
			var newStepSize = SampleRate.ir * (division/newTempo);
			var line = Line.kr(0, 16.1, 16.1*(division/newTempo), doneAction: Done.freeSelf);
			4.do { |i|
				var play = PlayBuf.ar(2, oldBuf, oldRate, startPos: i*16*oldStepSize, loop: 0, doneAction: Done.none);
				var record = RecordBuf.ar(play, newBuf, i*16*SampleRate.ir*(division/newTempo), 1.0, 0.0, loop: 0.0, doneAction: Done.none);
				var pwr = (RunningSum.ar((Mix.ar(play)/2).squared, (newStepSize/2)) / (newStepSize/2)).sqrt;

				SendReply.kr(
					Impulse.kr(2*(newTempo/division)),
					'/resampleAmplitude',
					[track, line + (i*16), pwr]
			    );
			};
		}).add;

		SynthDef.new(\metronome, { |out, hz|
			Out.ar(out, 0.25*SinOsc.ar(hz!2)*EnvGen.kr(Env.perc(releaseTime: 0.3), Impulse.kr(0), doneAction: Done.freeSelf));
		}).add;

		SynthDef.new(\sendDelay, { |in, out, delay, repeats|
			Out.ar(out, CombC.ar(In.ar(in, 2), 2, delay.lag(0.2), delay*repeats));
		}).add;

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

		SynthDef.new(\playStep, { |out, buf, bufTempo, clockTempo, pos, division, rate=1, loop=0, gate=1, level=1, track=1, forward=1, rateLag = 0|
			var r = (forward*rate*(clockTempo/bufTempo)*BufRateScale.kr(buf)).lag(rateLag*division/clockTempo);
			var stepSize = BufRateScale.kr(buf) * SampleRate.ir  * (division/bufTempo);
			var start = (rate > 0).if(pos*stepSize, (pos-rate.reciprocal)*stepSize); // When reversed, start at the end of the step
			var reset = Impulse.kr((loop > 0).if(clockTempo/(loop*division), 0));
			var report = Impulse.kr(clockTempo*3/division);
			var phasor = Phasor.ar(reset, r, 0, 64*stepSize, start);
			var snd = BufRd.ar(2, buf, phasor);
			snd = EnvGen.kr(fadeEnv, gate, doneAction: Done.freeSelf) * snd;
			SendReply.kr(gate*report, '/report', [track, phasor/stepSize, rate, loop]);
			snd = level.lag(0.01) * snd;
			Out.ar(out, snd);
		}).add;

		SynthDef.new(\monitor, {|out, gate=1, level=1|
			var env = EnvGen.kr(fadeEnv, gate, doneAction: Done.freeSelf);
			Out.ar(out, env * level.lag(0.01) * SoundIn.ar([0, 1]));
		}).add;

		SynthDef.new(\readAmp, {|buf, tempo, division, gate=1, track=1|

			var stepSize = SampleRate.ir * (division/tempo);
			var start = 0;
			var env = EnvGen.kr(fadeEnv, gate, doneAction: Done.freeSelf);

			var bufPlay = PlayBuf.ar(2, buf, rate: 1.0, startPos: start, loop: 1.0);
			var ampPulse = Impulse.kr(tempo*2/division);
			var ampCounter = PulseCount.kr(ampPulse);
			var pwr = (RunningSum.ar((Mix.ar((bufPlay))/2).squared, (stepSize/2)) / (stepSize/2)).sqrt;

			SendReply.kr(
				(ampCounter > 1).if(ampPulse, 0),
				'/recordAmplitude',
				[track, ampCounter-1, pwr]
			);
		}).add;

		SynthDef.new(\record, {|out, buf, tempo, pos, division, gate=1, level=1, track=1|

			var in = SoundIn.ar([0, 1]);
			var stepSize = SampleRate.ir * (division/tempo);
			var start = pos*stepSize;
			var env = EnvGen.kr(fadeEnv, gate, doneAction: Done.freeSelf);
			var llevel = level.lag(0.01);

			var bufPlay = PlayBuf.ar(2, buf, rate: 1.0, startPos: start, loop: 1.0);
			var ampPulse = Impulse.kr(tempo*2/division);
			var ampCounter = PulseCount.kr(ampPulse);
			var pwr = (RunningSum.ar((Mix.ar((llevel*bufPlay)+in)/2).squared, (stepSize/2)) / (stepSize/2)).sqrt;

			SendReply.kr(
				(ampCounter > 1).if(ampPulse, 0),
				'/recordAmplitude',
				[track, ampCounter-1+(2*pos), pwr]
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

		ampDef = OSCdef.new(\resampleAmplitude, { |msg, time|
			var track = msg[3].asFloat.asInteger;
			var pos = msg[4].asFloat;
			var amp = msg[5].asFloat;
			"Amp % % %\n".postf(track, pos, amp);
			luaOscAddr.sendMsg("/resampleAmplitude", track, pos, amp);
		}, '/resampleAmplitude');

		reportDef = OSCdef.new(\report, { |msg, time|
			var track = msg[3].asFloat.asInteger;
			var pos = msg[4].asFloat;
			var rate = msg[5].asFloat;
			var loop = msg[6].asFloat;
			luaOscAddr.sendMsg("/report", track, pos, rate, loop, tracks[track-1].bufferTempo);
		}, '/report');

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

		this.addCommand("resample", "i", { |msg|
			var track = msg[1].asInteger - 1;
			tracks[track].resample({
				luaOscAddr.sendMsg("/resampleDone", track+1);
			});
		});

		this.addCommand("loadTrack", "isf", { |msg|
			var track = msg[1].asInteger - 1;
			var fileName = msg[2].asString;
			var fileTempo = msg[3].asFloat;
			"load % % %\n".postf(track, fileName, fileTempo);
			if (tracks == nil, {
				this.initTracks;
			});
			tracks[track].load(fileName, fileTempo, {
				luaOscAddr.sendMsg("/readAmpDone", track+1);
			});
		});

		this.addCommand("saveTrack", "is", { |msg|
			var track = msg[1].asInteger - 1;
			var filePrefix = msg[2].asString;
			var fileName = filePrefix ++ " " ++ (60*tracks[track].bufferTempo).asStringPrec(3) ++ "bpm.aiff";
			tracks[track].buffer.write(fileName, headerFormat: "aiff", sampleFormat: "float");
			luaOscAddr.sendMsg("/wrote", track+1, fileName);
		});

		this.addCommand("realloc", "if", { |msg|
			var track = msg[1].asInteger - 1;
			var div = msg[2].asFloat;
			"realloc".postln;
			if (tracks == nil, {
				this.initTracks;
			});
			tracks[track].realloc(div);
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
			4.do { |track|
			  tracks[track].setSynth(\clockTempo, tempo);
			}
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

		this.addCommand("setSend", "sf", { |msg|
			var control = msg[1].asSymbol;
			var value = msg[2].asFloat;
			sendSynth.set(control, value);
		});

		this.addCommand("setSynth", "isf", { |msg|
			var track = msg[1].asInteger - 1;
			var control = msg[2].asSymbol;
			var value = msg[3].asFloat;
			if (tracks == nil, {
				this.initTracks;
			});
			tracks[track].setSynth(control, value);
		});

		this.addCommand("metronome", "f", { |msg|
			var hz = msg[1].asFloat;
			Synth(\metronome, [hz: hz]);
		});

		this.initTracks;
	}

	free {
		tracks.do { |t| t.free};
		ampDef.free;
		reportDef.free;
		sendSynth.free;
		sendBus.free;
		returnBus.free;
		metro.free;
	}
}