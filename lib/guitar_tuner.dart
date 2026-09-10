import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';

class GuitarTunerSheet extends StatefulWidget {
  const GuitarTunerSheet({super.key, this.embedded = false, this.onClose});
  final bool embedded;
  final VoidCallback? onClose;
  @override State<GuitarTunerSheet> createState() => _TunerState();
}

class GuitarTunerScreen extends StatelessWidget {
  const GuitarTunerScreen({super.key});
  @override Widget build(BuildContext context) => const Scaffold(
    backgroundColor: Color(0xFF06151D),
    body: SafeArea(child: GuitarTunerSheet(embedded: true)),
  );
}

class _StringTarget {
  const _StringTarget(this.note, this.hz, this.number);
  final String note;
  final double hz;
  final int number;
}

const _targets = <_StringTarget>[
  _StringTarget('E', 82.41, 6),
  _StringTarget('A', 110.00, 5),
  _StringTarget('D', 146.83, 4),
  _StringTarget('G', 196.00, 3),
  _StringTarget('B', 246.94, 2),
  _StringTarget('E', 329.63, 1),
];

const _green = Color(0xFF19F59A);
const _red = Color(0xFFFF6E6E);
const _amber = Color(0xFFFFC33D);
const _bg = Color(0xFF06151D);
const _card = Color(0xFF0C222D);
const _border = Color(0xFF193642);

class _Pitch {
  const _Pitch(this.hz, this.confidence);
  final double hz;
  final double confidence;
}

class _TunerState extends State<GuitarTunerSheet> with SingleTickerProviderStateMixin {
  final _recorder = AudioRecorder();
  final _chime = AudioPlayer();
  final _samples = <int>[];
  StreamSubscription<Uint8List>? _subscription;
  late final AnimationController _animation;

  bool _listening = false;
  bool _hasSignal = false;
  bool _verified = false;
  bool _playingChime = false;

  int _selected = 5;
  int _detected = 5;
  int _verifyTarget = -1;
  int _verifyFrames = 0;
  static const _requiredFrames = 3;

  final Set<int> _tuned = <int>{};
  double _frequency = 0;
  double _cents = 0;
  double _confidence = 0;
  double _smoothedFrequency = 0;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _stop();
    _animation.dispose();
    _chime.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!await _recorder.hasPermission() || !mounted) return;
    try {
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 44100,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      ));
      _samples.clear();
      _subscription = stream.listen(_onAudio, onError: (_) {
        if (mounted) setState(() => _listening = false);
      });
      if (mounted) setState(() => _listening = true);
    } catch (_) {}
  }

  Future<void> _stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _samples.clear();
    try { await _recorder.stop(); } catch (_) {}
    if (!mounted) return;
    setState(() {
      _listening = false;
      _hasSignal = false;
      _verified = false;
      _frequency = 0;
      _cents = 0;
      _confidence = 0;
      _smoothedFrequency = 0;
      _verifyTarget = -1;
      _verifyFrames = 0;
    });
  }

  Future<void> _toggle() => _listening ? _stop() : _start();

  void _onAudio(Uint8List bytes) {
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final value = bytes[i] | (bytes[i + 1] << 8);
      _samples.add(value > 32767 ? value - 65536 : value);
    }

    const n = 4096;
    if (_samples.length < n) return;
    if (_samples.length > n * 2) _samples.removeRange(0, _samples.length - n);

    final pitch = _pitch(_samples);
    if (pitch == null || pitch.hz < 70 || pitch.hz > 370) {
      _verifyTarget = -1;
      _verifyFrames = 0;
      if (mounted) setState(() { _hasSignal = false; _verified = false; });
      return;
    }

    final actual = _nearest(pitch.hz);
    final target = _targets[_selected];
    final targetCents = _centsFrom(pitch.hz, target.hz);

    _smoothedFrequency = _smoothedFrequency == 0
        ? pitch.hz
        : _smoothedFrequency * 0.72 + pitch.hz * 0.28;

    // The detected note must match the selected string. This is what prevents
    // low E/A from checking high E: the octave/string index must match too.
    final correctString = actual == _selected && targetCents.abs() <= 50;
    if (correctString) {
      if (_verifyTarget == _selected) {
        _verifyFrames++;
      } else {
        _verifyTarget = _selected;
        _verifyFrames = 1;
      }
    } else {
      _verifyTarget = -1;
      _verifyFrames = 0;
    }

    final verified = correctString &&
        _verifyFrames >= _requiredFrames &&
        targetCents.abs() <= 5;

    if (mounted) {
      setState(() {
        _hasSignal = true;
        _detected = actual;
        _frequency = _smoothedFrequency;
        _cents = targetCents.clamp(-50.0, 50.0);
        _confidence = pitch.confidence;
        _verified = verified;
      });
    }

    if (verified && _tuned.add(_selected) && !_playingChime) _playChime();
  }

  double _centsFrom(double frequency, double target) => 1200 * math.log(frequency / target) / math.ln2;

  int _nearest(double frequency) {
    var best = 0;
    var error = double.infinity;
    for (var i = 0; i < _targets.length; i++) {
      final e = _centsFrom(frequency, _targets[i].hz).abs();
      if (e < error) { error = e; best = i; }
    }
    return best;
  }

  // Proven detector from the old working speedometer tuner.
  _Pitch? _pitch(List<int> input) {
    const n = 4096;
    var mean = 0.0;
    for (final value in input) mean += value;
    mean /= n;

    var energy = 0.0;
    for (final value in input) {
      final v = value - mean;
      energy += v * v;
    }
    if (math.sqrt(energy / n) < 180) return null;

    final minLag = (44100 / 500).round();
    final maxLag = math.min((44100 / 70).round(), n ~/ 2);
    var bestLag = 0;
    var bestCorrelation = 0.0;

    for (var lag = minLag; lag <= maxLag; lag++) {
      var dot = 0.0, a2 = 0.0, b2 = 0.0;
      for (var i = 0; i < n - lag; i += 2) {
        final a = input[i] - mean;
        final b = input[i + lag] - mean;
        dot += a * b; a2 += a * a; b2 += b * b;
      }
      if (a2 > 0 && b2 > 0) {
        final correlation = dot / math.sqrt(a2 * b2);
        if (correlation > bestCorrelation) {
          bestCorrelation = correlation;
          bestLag = lag;
        }
      }
    }

    if (bestLag == 0 || bestCorrelation < .55) return null;

    var lag = bestLag.toDouble();
    if (bestLag > minLag && bestLag < maxLag) {
      final y1 = _correlation(input, bestLag - 1, mean);
      final y2 = _correlation(input, bestLag, mean);
      final y3 = _correlation(input, bestLag + 1, mean);
      final d = y1 - 2 * y2 + y3;
      if (d.abs() > 1e-9) lag += .5 * (y1 - y3) / d;
    }
    return _Pitch(44100 / lag, bestCorrelation);
  }

  double _correlation(List<int> x, int lag, double mean) {
    var dot = 0.0, a2 = 0.0, b2 = 0.0;
    for (var i = 0; i < x.length - lag; i += 2) {
      final a = x[i] - mean, b = x[i + lag] - mean;
      dot += a * b; a2 += a * a; b2 += b * b;
    }
    return a2 > 0 && b2 > 0 ? dot / math.sqrt(a2 * b2) : 0;
  }

  Future<void> _playChime() async {
    _playingChime = true;
    try {
      await _chime.stop();
      await _chime.play(BytesSource(_makeWav()));
    } catch (_) {} finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _playingChime = false;
    }
  }

  Uint8List _makeWav() {
    const rate = 44100, ms = 280;
    final count = rate * ms ~/ 1000;
    final pcm = Int16List(count);
    for (var i = 0; i < count; i++) {
      final t = i / rate;
      final attack = math.min(1.0, t / .012);
      final release = math.min(1.0, (ms / 1000 - t) / .09);
      final env = math.max(0.0, math.min(attack, release));
      final tone = math.sin(2 * math.pi * 880 * t) + math.sin(2 * math.pi * 1320 * t) * .65;
      pcm[i] = (tone * .22 * env * 32767).round();
    }
    final dataSize = pcm.length * 2;
    final b = ByteData(44 + dataSize);
    void text(int at, String value) {
      for (var i = 0; i < value.length; i++) b.setUint8(at + i, value.codeUnitAt(i));
    }
    text(0, 'RIFF'); b.setUint32(4, 36 + dataSize, Endian.little);
    text(8, 'WAVE'); text(12, 'fmt '); b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little); b.setUint16(22, 1, Endian.little);
    b.setUint32(24, rate, Endian.little); b.setUint32(28, rate * 2, Endian.little);
    b.setUint16(32, 2, Endian.little); b.setUint16(34, 16, Endian.little);
    text(36, 'data'); b.setUint32(40, dataSize, Endian.little);
    for (var i = 0; i < pcm.length; i++) b.setInt16(44 + i * 2, pcm[i], Endian.little);
    return b.buffer.asUint8List();
  }

  Color get _tuningColor {
    if (!_hasSignal) return Colors.white70;
    if (_verified || _cents.abs() <= 5) return _green;
    if (_cents.abs() <= 20) return _amber;
    return _red;
  }

  void _select(int index) {
    setState(() {
      _selected = index;
      _detected = index;
      _verified = false;
      _verifyTarget = -1;
      _verifyFrames = 0;
      _smoothedFrequency = 0;
    });
  }

  void _reset() {
    setState(() {
      _tuned.clear();
      _selected = 5; _detected = 5;
      _verified = false; _hasSignal = false;
      _frequency = 0; _cents = 0; _confidence = 0;
      _verifyTarget = -1; _verifyFrames = 0;
      _smoothedFrequency = 0; _samples.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = _targets[_selected];
    final detected = _targets[_detected];
    final color = _tuningColor;
    final wrong = _hasSignal && _detected != _selected;

    return Material(
      color: _bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
          child: Column(children: [
            Row(children: [
              if (!widget.embedded)
                IconButton(onPressed: widget.onClose ?? () => Navigator.maybePop(context), icon: const Icon(Icons.close_rounded, color: Colors.white70))
              else const SizedBox(width: 48),
              const Expanded(child: Text('Guitar Tuner', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800))),
              IconButton(onPressed: _reset, icon: const Icon(Icons.restart_alt_rounded, color: Colors.white70)),
              IconButton(onPressed: _toggle, icon: Icon(_listening ? Icons.mic_rounded : Icons.mic_off_rounded, color: color)),
            ]),
            const Align(alignment: Alignment.centerLeft, child: Text('Play a string and tune to the center', style: TextStyle(color: Colors.white54, fontSize: 14))),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _Info('TARGET', '${selected.note}${selected.number}')),
              const SizedBox(width: 8),
              Expanded(child: _Info('DETECTED', _hasSignal ? '${detected.note}${detected.number}' : '—')),
            ]),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
              decoration: BoxDecoration(color: _verified ? _green.withOpacity(.12) : _card, borderRadius: BorderRadius.circular(24), border: Border.all(color: _verified ? _green : _border)),
              child: Text(_verified ? '✓  IN TUNE' : wrong ? 'WRONG STRING' : _hasSignal ? 'TUNE TO CENTER' : 'PLAY A STRING', style: TextStyle(color: color, fontWeight: FontWeight.w800, letterSpacing: 1)),
            ),
            const SizedBox(height: 4),
            Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              AnimatedBuilder(
                animation: _animation,
                builder: (_, __) => SizedBox(height: 170, width: double.infinity, child: CustomPaint(painter: _Wave(cents: _cents, active: _hasSignal, verified: _verified, phase: _animation.value))),
              ),
              Text(_hasSignal ? detected.note : '—', style: TextStyle(color: color, fontSize: 82, height: .88, fontWeight: FontWeight.w900)),
              Text(_hasSignal ? '${_frequency.toStringAsFixed(1)} Hz' : 'Listening…', style: const TextStyle(color: Colors.white70, fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 5),
              Text(_hasSignal ? '${_cents >= 0 ? '+' : ''}${_cents.toStringAsFixed(1)} cents' : 'Tune until the center is reached', style: TextStyle(color: color, fontSize: 19, fontWeight: FontWeight.w800)),
            ])),
            SizedBox(height: 72, width: double.infinity, child: CustomPaint(painter: _Ruler(_cents, _hasSignal, _verified))),
            const SizedBox(height: 10),
            Row(children: List.generate(_targets.length, (i) {
              final selectedCard = i == _selected;
              final tuned = _tuned.contains(i);
              return Expanded(child: Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 3, right: i == 5 ? 0 : 3),
                child: GestureDetector(onTap: () => _select(i), child: Stack(clipBehavior: Clip.none, children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180), height: 78,
                    decoration: BoxDecoration(color: tuned ? _green.withOpacity(.12) : _card, borderRadius: BorderRadius.circular(16), border: Border.all(color: tuned ? _green : selectedCard ? _green : _border, width: tuned || selectedCard ? 1.7 : 1)),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Text(_targets[i].note, style: TextStyle(color: tuned ? _green : Colors.white, fontSize: 23, fontWeight: FontWeight.w900)),
                      Text('${_targets[i].number}', style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    ]),
                  ),
                  if (tuned) Positioned(right: -4, top: -7, child: Container(width: 24, height: 24, decoration: const BoxDecoration(color: _green, shape: BoxShape.circle), child: const Icon(Icons.check_rounded, color: _bg, size: 16))),
                ])),
              ));
            })),
            const SizedBox(height: 8),
            Text(_verified ? 'Verified • ±5 cents • chime played' : 'Green center is the tuning target • small ±5 cent tolerance', style: TextStyle(color: _verified ? _green : Colors.white38, fontSize: 13, fontWeight: FontWeight.w600)),
            if (_confidence > 0) ...[
              const SizedBox(height: 3),
              Text('Signal ${(100 * _confidence).clamp(0, 100).toStringAsFixed(0)}%', style: const TextStyle(color: Colors.white24, fontSize: 11)),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info(this.label, this.value);
  final String label;
  final String value;
  @override Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 8),
    decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(13), border: Border.all(color: _border)),
    child: Column(children: [
      Text(label, style: const TextStyle(color: Colors.white30, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1)),
      const SizedBox(height: 2),
      Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
    ]),
  );
}

class _Wave extends CustomPainter {
  const _Wave({required this.cents, required this.active, required this.verified, required this.phase});
  final double cents;
  final bool active;
  final bool verified;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final distance = active ? cents.abs().clamp(0.0, 50.0) : 50.0;
    final proximity = active ? 1.0 - distance / 50.0 : 0.0;
    final color = !active ? Colors.white54 : verified || distance <= 5 ? _green : distance <= 20 ? _amber : _red;

    // As the pitch approaches the exact target, the center grows and the
    // whole wave transitions red -> amber -> green.
    final centerRadius = 12 + proximity * 11;
    final glowRadius = 35 + proximity * 55;
    if (active) canvas.drawCircle(Offset(cx, cy), glowRadius, Paint()..color = color.withOpacity(.05 + proximity * .10));

    canvas.drawLine(Offset(cx, 8), Offset(cx, size.height - 8), Paint()..color = verified ? _green : color..strokeWidth = verified ? 4 : 3..strokeCap = StrokeCap.round);
    canvas.drawCircle(Offset(cx, cy), centerRadius, Paint()..color = color);

    const bars = 17;
    for (var i = 0; i < bars; i++) {
      final normalized = i / (bars - 1);
      final side = (normalized - .5).abs() * 2;
      final distanceFromCenter = 1 - side;
      final pulse = math.sin(phase * math.pi * 2 + i * .72).abs();
      final height = active ? 22 + pulse * (38 + proximity * 60) * (.55 + distanceFromCenter * .45) : 16 + distanceFromCenter * 12;
      final x = 10 + normalized * (size.width - 20);
      final barColor = active ? color.withOpacity(.45 + distanceFromCenter * .45) : Colors.white54;
      canvas.drawLine(Offset(x, cy - height / 2), Offset(x, cy + height / 2), Paint()..color = barColor..strokeWidth = 4..strokeCap = StrokeCap.round);
    }
  }

  @override bool shouldRepaint(covariant _Wave old) => old.cents != cents || old.active != active || old.verified != verified || old.phase != phase;
}

class _Ruler extends CustomPainter {
  const _Ruler(this.cents, this.active, this.verified);
  final double cents;
  final bool active;
  final bool verified;

  @override
  void paint(Canvas canvas, Size size) {
    const green = _green;
    const red = _red;
    const amber = _amber;
    const y = 31.0;
    for (var i = 0; i < 25; i++) {
      final value = -50 + i * 100 / 24;
      final x = (value + 50) / 100 * size.width;
      final c = value.abs() <= 5 ? green : value.abs() <= 20 ? amber : red;
      canvas.drawLine(Offset(x, y - (i.isEven ? 16 : 10)), Offset(x, y + (i.isEven ? 16 : 10)), Paint()..color = c.withOpacity(active ? 1 : .5)..strokeWidth = i.isEven ? 3 : 2);
    }
    final value = active ? cents.clamp(-50.0, 50.0) : 0.0;
    final x = (value + 50) / 100 * size.width;
    final marker = Paint()..color = verified ? green : Colors.white70..strokeWidth = 3.5;
    marker.strokeWidth = 3.5;
    canvas.drawLine(Offset(x, 3), Offset(x, 58), marker);
    final text = const TextStyle(color: Colors.white54, fontSize: 11);
    _label(canvas, '-50', 0, 62, text, TextAlign.left);
    _label(canvas, '0', size.width / 2, 62, text, TextAlign.center);
    _label(canvas, '+50', size.width, 62, text, TextAlign.right);
  }

  void _label(Canvas canvas, String value, double x, double y, TextStyle style, TextAlign align) {
    final p = TextPainter(text: TextSpan(text: value, style: style), textDirection: TextDirection.ltr)..layout();
    final dx = align == TextAlign.left ? x : align == TextAlign.right ? x - p.width : x - p.width / 2;
    p.paint(canvas, Offset(dx, y));
  }

  @override bool shouldRepaint(covariant _Ruler old) => old.cents != cents || old.active != active || old.verified != verified;
}
