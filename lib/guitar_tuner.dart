import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

class GuitarTunerSheet extends StatefulWidget {
  const GuitarTunerSheet({super.key});
  @override State<GuitarTunerSheet> createState() => _GuitarTunerSheetState();
}

class _GuitarTunerSheetState extends State<GuitarTunerSheet> {
  static const int sr = 44100;
  static const double tolerance = 5.0;
  static const notes = [
    _N('E', 82.41, '6th string', '6'), _N('A', 110, '5th string', '5'),
    _N('D', 146.83, '4th string', '4'), _N('G', 196, '3rd string', '3'),
    _N('B', 246.94, '2nd string', '2'), _N('E', 329.63, '1st string', '1'),
  ];

  final recorder = AudioRecorder();
  StreamSubscription<Uint8List>? sub;
  final samples = <int>[];
  bool running = false;
  bool _inTuneSoundPlayed = false;
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
        SnackBar(content: Text('Could not start microphone: ' + e.toString())));
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
    final rawCents = 1200 * math.log(p.f / target.f) / math.ln2;
    final c = rawCents.clamp(-50.0, 50.0).toDouble();
    final ok = c.abs() <= tolerance && p.c >= .60;

    if (ok && !_inTuneSoundPlayed) {
      _inTuneSoundPlayed = true;
      SystemSound.play(SystemSoundType.click);
    } else if (!ok) {
      _inTuneSoundPlayed = false;
    }

    if (mounted) setState(() {
      hz = p.f; confidence = p.c; note = target.name;
      stringName = target.stringName; cents = c;
    });
  }

  _P? pitch(List<int> x) {
    final n = x.length;
    var mean = 0.0;
    for (final v in x) mean += v;
    mean /= n;
    var energy = 0.0;
    for (final v in x) { final z = v - mean; energy += z * z; }
    if (math.sqrt(energy / n) < 180) return null;

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
      final y1 = corr(x, best - 1, mean), y2 = corr(x, best, mean);
      final y3 = corr(x, best + 1, mean), d = y1 - 2 * y2 + y3;
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

  _N nearest(double f) => notes.reduce(
    (a, b) => (f - a.f).abs() < (f - b.f).abs() ? a : b);

  bool get inTune => hz > 0 && cents.abs() <= tolerance && confidence >= .60;
  Color get accent => hz == 0 ? Colors.white54 :
    inTune ? const Color(0xFF25E88A) :
    cents.abs() <= 20 ? const Color(0xFFFFC44D) : const Color(0xFFFF756B);
  String get status => hz == 0 ? 'PLAY A STRING' :
    inTune ? 'IN TUNE!' : cents < 0 ? 'TUNE UP ↑' : 'TUNE DOWN ↓';

  @override Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF06131A),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 20),
          child: Column(children: [
            Container(width: 46, height: 4, decoration: BoxDecoration(
              color: Colors.white24, borderRadius: BorderRadius.circular(4))),
            const SizedBox(height: 14),
            Row(children: [
              const Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Guitar Tuner', style: TextStyle(
                    color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
                  SizedBox(height: 3),
                  Text('Play a string and tune to the center',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
                ],
              )),
              IconButton(
                onPressed: running ? stop : start,
                icon: Icon(running ? Icons.mic_rounded : Icons.mic_off_rounded,
                  color: running ? accent : Colors.white54)),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: Colors.white70)),
            ]),
            const SizedBox(height: 10),

            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: inTune ? const Color(0xFF123B2A) : const Color(0xFF10242E),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: inTune ? accent : Colors.white10),
                boxShadow: inTune ? [BoxShadow(
                  color: accent.withOpacity(.22), blurRadius: 18)] : null,
              ),
              child: Text(inTune ? '✓  In Tune!' : stringName,
                style: TextStyle(color: inTune ? accent : Colors.white70,
                  fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 5),
            Text(note, style: TextStyle(color: accent, fontSize: 82,
              height: .95, fontWeight: FontWeight.w900)),
            Text(hz == 0 ? '— Hz' : hz.toStringAsFixed(1) + ' Hz',
              style: const TextStyle(color: Colors.white60, fontSize: 16)),

            const SizedBox(height: 3),
            SizedBox(height: 160, width: double.infinity,
              child: CustomPaint(painter: _TuningGauge(
                cents: cents, activeColor: accent, inTune: inTune))),

            Text(status, style: TextStyle(color: accent, fontSize: 18,
              fontWeight: FontWeight.w900, letterSpacing: 1.2)),
            const SizedBox(height: 4),
            Text(hz == 0 ? 'Pluck one string near the microphone' :
              (cents >= 0 ? '+' : '') + cents.toStringAsFixed(1) + ' cents',
              style: const TextStyle(color: Colors.white54, fontSize: 14)),

            const SizedBox(height: 10),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              decoration: BoxDecoration(
                color: inTune ? const Color(0xFF123B2A) : const Color(0xFF0D202A),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: inTune ? accent : Colors.white10),
              ),
              child: Text(
                inTune ? '✓ Within tolerance  ±5 cents' : 'Green zone = ±5 cents',
                style: TextStyle(color: inTune ? accent : Colors.white54,
                  fontWeight: FontWeight.w700, fontSize: 13)),
            ),

            const SizedBox(height: 14),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: notes.map((n) {
                final selected = n.name == note && n.stringName == stringName;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 47, height: 58,
                  decoration: BoxDecoration(
                    color: selected ? const Color(0xFF123B2A) : const Color(0xFF0D202A),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: selected ? accent : Colors.white10,
                      width: selected ? 1.5 : 1)),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(n.name, style: TextStyle(color: selected ? accent : Colors.white70,
                        fontSize: 20, fontWeight: FontWeight.w800)),
                      Text(n.number, style: const TextStyle(color: Colors.white30, fontSize: 11)),
                    ]),
                );
              }).toList()),

            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _InfoTile(Icons.music_note_rounded, 'Standard', 'E A D G B E')),
              const SizedBox(width: 10),
              Expanded(child: _InfoTile(Icons.graphic_eq_rounded, 'Microphone',
                running ? 'Listening' : 'Paused', running)),
            ]),
            const SizedBox(height: 12),
            const Row(children: [
              Icon(Icons.info_outline_rounded, color: Colors.white38, size: 19),
              SizedBox(width: 9),
              Expanded(child: Text(
                'Tune until the needle reaches the green center zone. '
                'A sound plays once when the string is in tune.',
                style: TextStyle(color: Colors.white54, fontSize: 12.5, height: 1.35))),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile(this.icon, this.title, this.subtitle, [this.active = false]);
  final IconData icon; final String title, subtitle; final bool active;
  @override Widget build(BuildContext context) {
    final c = active ? const Color(0xFF25E88A) : Colors.white54;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFF0D202A),
        borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white10)),
      child: Row(children: [
        Icon(icon, color: c, size: 21), const SizedBox(width: 9),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
          Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ])),
      ]),
    );
  }
}

class _N {
  const _N(this.name, this.f, this.stringName, this.number);
  final String name, stringName, number; final double f;
}
class _P {
  const _P(this.f, this.c);
  final double f, c;
}

class _TuningGauge extends CustomPainter {
  const _TuningGauge({required this.cents, required this.activeColor, required this.inTune});
  final double cents; final Color activeColor; final bool inTune;

  @override void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height - 14);
    final radius = math.min(size.width * .39, size.height * 1.05);
    final rect = Rect.fromCircle(center: center, radius: radius);
    const start = math.pi * 1.18, sweep = math.pi * .64;
    final mid = start + sweep / 2;

    final base = Paint()..color = Colors.white10..style = PaintingStyle.stroke
      ..strokeWidth = 10..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, start, sweep, false, base);

    final green = Paint()..color = const Color(0xFF25E88A).withOpacity(.28)
      ..style = PaintingStyle.stroke..strokeWidth = 15..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, mid - sweep * .05, sweep * .10, false, green);

    final tick = Paint()..color = Colors.white38..strokeWidth = 2;
    for (var i = -10; i <= 10; i++) {
      final a = mid + (i / 10) * sweep / 2;
      final inner = radius - (i % 5 == 0 ? 25 : 18);
      canvas.drawLine(
        Offset(center.dx + math.cos(a) * inner, center.dy + math.sin(a) * inner),
        Offset(center.dx + math.cos(a) * (radius - 3), center.dy + math.sin(a) * (radius - 3)),
        tick);
    }

    void label(String s, double a) {
      final tp = TextPainter(text: TextSpan(text: s, style: const TextStyle(
        color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(center.dx + math.cos(a) * (radius - 42) - tp.width / 2,
        center.dy + math.sin(a) * (radius - 42) - tp.height / 2));
    }
    label('-50', mid - sweep / 2);
    label('-25', mid - sweep / 4);
    label('-5', mid - sweep * .05);
    label('0', mid);
    label('+5', mid + sweep * .05);
    label('+25', mid + sweep / 4);
    label('+50', mid + sweep / 2);

    final v = cents.clamp(-50.0, 50.0).toDouble();
    final angle = mid + (v / 50) * sweep / 2;
    final needle = Paint()..color = inTune ? const Color(0xFF25E88A) : activeColor
      ..strokeWidth = 4..strokeCap = StrokeCap.round;
    canvas.drawLine(center,
      Offset(center.dx + math.cos(angle) * (radius - 12),
        center.dy + math.sin(angle) * (radius - 12)), needle);
    canvas.drawCircle(center, 8, Paint()..color = needle.color);
    if (inTune) {
      canvas.drawCircle(center, 17, Paint()
        ..color = const Color(0xFF25E88A).withOpacity(.12));
    }
  }

  @override bool shouldRepaint(covariant _TuningGauge old) =>
    old.cents != cents || old.activeColor != activeColor || old.inTune != inTune;
}
