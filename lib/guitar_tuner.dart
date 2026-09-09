import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:record/record.dart';

class GuitarTunerSheet extends StatefulWidget {
  const GuitarTunerSheet({super.key});
  @override State<GuitarTunerSheet> createState() => _GuitarTunerSheetState();
}

class _GuitarTunerSheetState extends State<GuitarTunerSheet> {
  static const int sr = 44100;
  static const notes = [
    _N('E', 82.41, '6th string'), _N('A', 110, '5th string'),
    _N('D', 146.83, '4th string'), _N('G', 196, '3rd string'),
    _N('B', 246.94, '2nd string'), _N('E', 329.63, '1st string'),
  ];
  final AudioRecorder recorder = AudioRecorder();
  StreamSubscription<Uint8List>? sub;
  final samples = <int>[];
  bool running = false;
  String note = '--', stringName = 'Play a string';
  double hz = 0, cents = 0, confidence = 0;

  @override void initState() { super.initState(); start(); }
  @override void dispose() { stop(); recorder.dispose(); super.dispose(); }

  Future<void> start() async {
    try {
      if (!await recorder.hasPermission()) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission is required for tuning.')));
        return;
      }
      final stream = await recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits, sampleRate: sr, numChannels: 1,
        autoGain: false, echoCancel: false, noiseSuppress: false,
      ));
      sub = stream.listen(onAudio);
      if (mounted) setState(() => running = true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start microphone: $e')));
    }
  }

  Future<void> stop() async {
    await sub?.cancel(); sub = null;
    try { if (await recorder.isRecording()) await recorder.stop(); } catch (_) {}
    if (mounted) setState(() => running = false);
  }

  void onAudio(Uint8List bytes) {
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final v = bytes[i] | (bytes[i + 1] << 8);
      samples.add(v > 32767 ? v - 65536 : v);
    }
    const n = 4096;
    if (samples.length < n) return;
    if (samples.length > n * 2) samples.removeRange(0, samples.length - n);
    final p = pitch(samples);
    if (p == null) return;
    final target = nearest(p.f);
    final c = 1200 * math.log(p.f / target.f) / math.ln2;
    if (mounted) setState(() {
      hz = p.f; confidence = p.c; note = target.name;
      stringName = target.stringName; cents = c.clamp(-50.0, 50.0);
    });
  }

  _P? pitch(List<int> x) {
    final n = x.length;
    var mean = 0.0;
    for (final v in x) mean += v;
    mean /= n;
    var e = 0.0;
    for (final v in x) { final z = v - mean; e += z * z; }
    if (math.sqrt(e / n) < 180) return null;
    final minLag = (sr / 500).round();
    final maxLag = math.min((sr / 70).round(), n ~/ 2);
    var best = 0, bestC = 0.0;
    for (var lag = minLag; lag <= maxLag; lag++) {
      var dot = 0.0, a2 = 0.0, b2 = 0.0;
      for (var i = 0; i < n - lag; i += 2) {
        final a = x[i] - mean, b = x[i + lag] - mean;
        dot += a * b; a2 += a * a; b2 += b * b;
      }
      if (a2 > 0 && b2 > 0) {
        final c = dot / math.sqrt(a2 * b2);
        if (c > bestC) { bestC = c; best = lag; }
      }
    }
    if (best == 0 || bestC < .55) return null;
    var lag = best.toDouble();
    if (best > minLag && best < maxLag) {
      final y1 = corr(x, best - 1, mean), y2 = corr(x, best, mean), y3 = corr(x, best + 1, mean);
      final d = y1 - 2 * y2 + y3;
      if (d.abs() > 1e-9) lag += .5 * (y1 - y3) / d;
    }
    return _P(sr / lag, bestC);
  }

  double corr(List<int> x, int lag, double mean) {
    var dot = 0.0, a2 = 0.0, b2 = 0.0;
    for (var i = 0; i < x.length - lag; i += 2) {
      final a = x[i] - mean, b = x[i + lag] - mean;
      dot += a * b; a2 += a * a; b2 += b * b;
    }
    return a2 > 0 && b2 > 0 ? dot / math.sqrt(a2 * b2) : 0;
  }

  _N nearest(double f) => notes.reduce((a, b) =>
    (f - a.f).abs() < (f - b.f).abs() ? a : b);

  Color get color => hz == 0 ? Colors.white54 :
    cents.abs() <= 5 ? const Color(0xFF45E88F) :
    cents.abs() <= 18 ? Colors.amber : Colors.white70;

  String get status => hz == 0 ? 'Play a string' :
    cents.abs() <= 5 ? 'IN TUNE' : cents < 0 ? 'TUNE UP' : 'TUNE DOWN';

  @override Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF06131A),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 44, height: 4, decoration: BoxDecoration(
            color: Colors.white24, borderRadius: BorderRadius.circular(4))),
          const SizedBox(height: 14),
          Row(children: [
            const Expanded(child: Text('Guitar Tuner', style: TextStyle(
              color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800))),
            IconButton(onPressed: running ? stop : start,
              icon: Icon(running ? Icons.mic : Icons.mic_off, color: color)),
            IconButton(onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close, color: Colors.white70)),
          ]),
          Text(stringName, style: const TextStyle(color: Colors.white54, fontSize: 15)),
          Text(note, style: TextStyle(color: color, fontSize: 92,
            height: .95, fontWeight: FontWeight.w800)),
          Text(hz == 0 ? '— Hz' : '${hz.toStringAsFixed(1)} Hz',
            style: const TextStyle(color: Colors.white60, fontSize: 16)),
          const SizedBox(height: 18),
          SizedBox(height: 96, child: CustomPaint(
            painter: _Gauge(cents, color), child: const SizedBox.expand())),
          Text(status, style: TextStyle(color: color, fontSize: 17,
            fontWeight: FontWeight.w800, letterSpacing: 1.4)),
          const SizedBox(height: 12),
          Text(hz == 0 ? 'Pluck one string and hold it near the microphone' :
            '${cents >= 0 ? '+' : ''}${cents.toStringAsFixed(1)} cents',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 14)),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.center,
            children: notes.map((n) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: CircleAvatar(radius: 21, backgroundColor:
                n.name == note && n.stringName == stringName
                  ? const Color(0xFF163C2A) : const Color(0xFF10242E),
                child: Text(n.name, style: TextStyle(
                  color: n.name == note && n.stringName == stringName
                    ? const Color(0xFF45E88F) : Colors.white70,
                  fontWeight: FontWeight.w700))))).toList()),
          const SizedBox(height: 8),
          Text(confidence > 0 ? 'Signal ${(confidence * 100).clamp(0, 100).toStringAsFixed(0)}%' :
            'Standard tuning • E A D G B E',
            style: const TextStyle(color: Colors.white30, fontSize: 12)),
        ]),
      )),
    );
  }
}

class _N {
  const _N(this.name, this.f, this.stringName);
  final String name, stringName; final double f;
}
class _P {
  const _P(this.f, this.c);
  final double f, c;
}
class _Gauge extends CustomPainter {
  const _Gauge(this.cents, this.color);
  final double cents; final Color color;
  @override void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height - 8);
    final r = math.min(size.width * .43, size.height * 1.7);
    final rect = Rect.fromCircle(center: center, radius: r);
    final base = Paint()..color = Colors.white12..style = PaintingStyle.stroke
      ..strokeWidth = 10..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, math.pi * 1.12, math.pi * .76, false, base);
    final v = cents.clamp(-50.0, 50.0) / 50.0;
    final angle = math.pi * 1.5 + v * math.pi * .38;
    final active = Paint()..color = color..style = PaintingStyle.stroke
      ..strokeWidth = 10..strokeCap = StrokeCap.round;
    if (cents != 0) canvas.drawArc(rect, math.pi * 1.5,
      v * math.pi * .38, false, active);
    final tick = Paint()..color = Colors.white38..strokeWidth = 2;
    for (var i = -5; i <= 5; i++) {
      final a = math.pi * 1.5 + (i / 5) * math.pi * .38;
      canvas.drawLine(
        Offset(center.dx + math.cos(a) * (r - 20), center.dy + math.sin(a) * (r - 20)),
        Offset(center.dx + math.cos(a) * (r - 4), center.dy + math.sin(a) * (r - 4)), tick);
    }
    final needle = Paint()..color = color..strokeWidth = 4..strokeCap = StrokeCap.round;
    canvas.drawLine(center, Offset(center.dx + math.cos(angle) * (r - 12),
      center.dy + math.sin(angle) * (r - 12)), needle);
    canvas.drawCircle(center, 7, Paint()..color = color);
  }
  @override bool shouldRepaint(covariant _Gauge old) =>
    old.cents != cents || old.color != color;
}
