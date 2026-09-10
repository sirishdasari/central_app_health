import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

class GuitarTunerSheet extends StatefulWidget {
  const GuitarTunerSheet({super.key, this.embedded = false, this.onClose});
  final bool embedded;
  final VoidCallback? onClose;
  @override
  State<GuitarTunerSheet> createState() => _GuitarTunerSheetState();
}

class GuitarTunerScreen extends StatelessWidget {
  const GuitarTunerScreen({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(
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

const _strings = <_StringTarget>[
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

class _GuitarTunerSheetState extends State<GuitarTunerSheet>
    with SingleTickerProviderStateMixin {
  final _recorder = AudioRecorder();
  final _samples = <int>[];
  StreamSubscription<Uint8List>? _subscription;
  late final AnimationController _wave;

  bool _listening = false;
  bool _hasSignal = false;
  bool _inTune = false;
  bool _lastInTune = false;
  bool _playingSuccess = false;
  bool _autoMode = true;

  int _selected = 5;
  int _detected = 5;
  int _autoCandidate = -1;
  int _autoCandidateFrames = 0;
  static const _autoFrames = 4;

  final Set<int> _tuned = <int>{};
  double _frequency = 0;
  double _cents = 0;
  double _smoothedFrequency = 0;
  double _smoothedCents = 0;

  @override
  void initState() {
    super.initState();
    _wave = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _stop();
    _wave.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!await _recorder.hasPermission() || !mounted) return;
    await _subscription?.cancel();
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
      _subscription = stream.listen(_processAudio, onError: (_) {
        if (mounted) setState(() => _listening = false);
      });
      if (mounted) setState(() => _listening = true);
    } catch (_) {
      if (mounted) setState(() => _listening = false);
    }
  }

  Future<void> _stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _samples.clear();
    try {
      await _recorder.stop();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _listening = false;
      _hasSignal = false;
      _inTune = false;
      _lastInTune = false;
      _frequency = 0;
      _cents = 0;
      _smoothedFrequency = 0;
      _smoothedCents = 0;
      _autoCandidate = -1;
      _autoCandidateFrames = 0;
    });
  }

  Future<void> _toggleMic() => _listening ? _stop() : _start();

  void _setAuto(bool value) {
    setState(() {
      _autoMode = value;
      _autoCandidate = -1;
      _autoCandidateFrames = 0;
      _inTune = false;
      _lastInTune = false;
    });
  }

  void _selectString(int index) {
    setState(() {
      _autoMode = false;
      _selected = index;
      _inTune = false;
      _lastInTune = false;
      _autoCandidate = -1;
      _autoCandidateFrames = 0;
      _smoothedFrequency = 0;
      _smoothedCents = 0;
    });
  }

  void _processAudio(Uint8List bytes) {
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final value = bytes[i] | (bytes[i + 1] << 8);
      _samples.add(value > 32767 ? value - 65536 : value);
    }

    const n = 4096;
    if (_samples.length < n) return;
    if (_samples.length > n * 2) {
      _samples.removeRange(0, _samples.length - n);
    }

    final pitch = _detectPitch(_samples);
    if (pitch == null || pitch < 70 || pitch > 370) {
      _autoCandidate = -1;
      _autoCandidateFrames = 0;
      if (mounted) {
        setState(() {
          _hasSignal = false;
          _inTune = false;
        });
      }
      return;
    }

    final actual = _closestString(pitch);
    final actualCents = _centsFrom(pitch, _strings[actual].hz);

    // Auto mode is deliberately sticky. A different string must be heard
    // consistently for several frames before the selected string changes.
    if (_autoMode && actual != _selected && actualCents.abs() <= 65) {
      if (_autoCandidate == actual) {
        _autoCandidateFrames++;
      } else {
        _autoCandidate = actual;
        _autoCandidateFrames = 1;
      }
      if (_autoCandidateFrames >= _autoFrames) {
        _selected = actual;
        _autoCandidate = -1;
        _autoCandidateFrames = 0;
        _inTune = false;
        _lastInTune = false;
        _smoothedFrequency = pitch;
        _smoothedCents = actualCents;
      }
    } else if (actual == _selected) {
      _autoCandidate = -1;
      _autoCandidateFrames = 0;
    }

    final target = _strings[_selected];
    final targetCents = _centsFrom(pitch, target.hz);

    _smoothedFrequency = _smoothedFrequency == 0
        ? pitch
        : _smoothedFrequency * .72 + pitch * .28;
    _smoothedCents = _smoothedCents == 0
        ? targetCents
        : _smoothedCents * .72 + targetCents * .28;

    final verified = actual == _selected && targetCents.abs() <= 10;

    if (mounted) {
      setState(() {
        _hasSignal = true;
        _detected = actual;
        _frequency = _smoothedFrequency;
        _cents = targetCents.clamp(-50.0, 50.0);
        _inTune = verified;
      });
    }

    if (verified) {
      _tuned.add(_selected);
      if (!_lastInTune && !_playingSuccess) {
        _lastInTune = true;
        Future<void>.microtask(_playSuccess);
      }
    } else {
      _lastInTune = false;
    }
  }

  double _centsFrom(double frequency, double target) =>
      1200 * math.log(frequency / target) / math.ln2;

  int _closestString(double frequency) {
    var best = 0;
    var error = double.infinity;
    for (var i = 0; i < _strings.length; i++) {
      final e = _centsFrom(frequency, _strings[i].hz).abs();
      if (e < error) {
        error = e;
        best = i;
      }
    }
    return best;
  }

  // Original working detector: 4096-sample autocorrelation.
  double? _detectPitch(List<int> input) {
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
      var dot = 0.0;
      var a2 = 0.0;
      var b2 = 0.0;
      for (var i = 0; i < n - lag; i += 2) {
        final a = input[i] - mean;
        final b = input[i + lag] - mean;
        dot += a * b;
        a2 += a * a;
        b2 += b * b;
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
    return lag > 0 ? 44100 / lag : null;
  }

  double _correlation(List<int> x, int lag, double mean) {
    var dot = 0.0, a2 = 0.0, b2 = 0.0;
    for (var i = 0; i < x.length - lag; i += 2) {
      final a = x[i] - mean;
      final b = x[i + lag] - mean;
      dot += a * b;
      a2 += a * a;
      b2 += b * b;
    }
    return a2 > 0 && b2 > 0 ? dot / math.sqrt(a2 * b2) : 0;
  }

  Future<void> _playSuccess() async {
    _playingSuccess = true;
    try {
      await SystemSound.play(SystemSoundType.click);
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 180));
    _playingSuccess = false;
  }

  void _reset() {
    setState(() {
      _tuned.clear();
      _selected = 5;
      _detected = 5;
      _hasSignal = false;
      _inTune = false;
      _lastInTune = false;
      _frequency = 0;
      _cents = 0;
      _smoothedFrequency = 0;
      _smoothedCents = 0;
      _autoCandidate = -1;
      _autoCandidateFrames = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = _strings[_selected];
    final detected = _strings[_detected];
    final color = !_hasSignal
        ? Colors.white70
        : _inTune || _cents.abs() <= 5
            ? _green
            : _cents.abs() <= 20
                ? _amber
                : _red;
    final wrong = _hasSignal && _detected != _selected;

    return Material(
      color: _bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
          child: Column(
            children: [
              Row(
                children: [
                  if (!widget.embedded)
                    IconButton(
                      onPressed: widget.onClose ?? () => Navigator.maybePop(context),
                      icon: const Icon(Icons.close_rounded, color: Colors.white70),
                    )
                  else
                    const SizedBox(width: 48),
                  const Expanded(
                    child: Text(
                      'Guitar Tuner',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(onPressed: _reset, icon: const Icon(Icons.restart_alt_rounded, color: Colors.white70)),
                  IconButton(
                    onPressed: _toggleMic,
                    icon: Icon(_listening ? Icons.mic_rounded : Icons.mic_off_rounded, color: color),
                  ),
                ],
              ),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Play a string and tune to the center', style: TextStyle(color: Colors.white54, fontSize: 14)),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _Info('TARGET', '${selected.note}${selected.number}')),
                  const SizedBox(width: 8),
                  Expanded(child: _Info('DETECTED', _hasSignal ? '${detected.note}${detected.number}' : '—')),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                decoration: BoxDecoration(
                  color: _inTune ? _green.withOpacity(.12) : _card,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: _inTune ? _green : _border),
                ),
                child: Text(
                  _inTune ? '✓  IN TUNE' : wrong ? 'DETECTING...' : _hasSignal ? 'TUNE TO CENTER' : 'PLAY A STRING',
                  style: TextStyle(color: color, fontWeight: FontWeight.w800, letterSpacing: 1),
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AnimatedBuilder(
                      animation: _wave,
                      builder: (_, __) => SizedBox(
                        height: 170,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: _WavePainter(cents: _cents, active: _hasSignal, inTune: _inTune, phase: _wave.value),
                        ),
                      ),
                    ),
                    Text(_hasSignal ? detected.note : '—', style: TextStyle(color: color, fontSize: 78, height: .9, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 4),
                    Text(_hasSignal ? '${_frequency.toStringAsFixed(1)} Hz' : '— Hz', style: const TextStyle(color: Colors.white70, fontSize: 24, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(_hasSignal ? '${_cents >= 0 ? '+' : ''}${_cents.toStringAsFixed(1)} cents' : '— cents', style: TextStyle(color: color, fontSize: 19, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 76,
                      child: CustomPaint(
                        painter: _Ruler(cents: _cents, active: _hasSignal, inTune: _inTune),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: List.generate(_strings.length, (index) {
                        return Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(left: index == 0 ? 0 : 4, right: index == 5 ? 0 : 4),
                            child: _StringTile(
                              string: _strings[index],
                              selected: index == _selected,
                              tuned: _tuned.contains(index),
                              onTap: () => _selectString(index),
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 9),
                    _ModeToggle(autoMode: _autoMode, onChanged: _setAuto),
                    const SizedBox(height: 8),
                    Text(
                      _autoMode
                          ? 'AUTO • stays on a string until another string is heard steadily'
                          : 'MANUAL • select a string above',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(13), border: Border.all(color: _border)),
        child: Column(children: [
          Text(label, style: const TextStyle(color: Colors.white30, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
        ]),
      );
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.autoMode, required this.onChanged});
  final bool autoMode;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => Container(
        height: 38,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(20), border: Border.all(color: _border)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _ModeButton(label: 'AUTO', active: autoMode, onTap: () => onChanged(true)),
          _ModeButton(label: 'MANUAL', active: !autoMode, onTap: () => onChanged(false)),
        ]),
      );
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({required this.label, required this.active, required this.onTap});
  final String label;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
          decoration: BoxDecoration(color: active ? _green.withOpacity(.16) : Colors.transparent, borderRadius: BorderRadius.circular(16)),
          child: Text(label, style: TextStyle(color: active ? _green : Colors.white54, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .8)),
        ),
      );
}

class _StringTile extends StatelessWidget {
  const _StringTile({required this.string, required this.selected, required this.tuned, required this.onTap});
  final _StringTarget string;
  final bool selected;
  final bool tuned;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final border = tuned ? _green : selected ? const Color(0xFF5C7884) : _border;
    final background = tuned ? const Color(0xFF083526) : selected ? const Color(0xFF102A35) : _card;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 64,
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(16), border: Border.all(color: border, width: tuned || selected ? 2 : 1)),
        child: Stack(children: [
          Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(string.note, style: const TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w900)),
            Text('${string.number}', style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w700)),
          ])),
          if (tuned) const Positioned(top: 5, right: 7, child: Icon(Icons.check_circle, size: 15, color: _green)),
        ]),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  const _WavePainter({required this.cents, required this.active, required this.inTune, required this.phase});
  final double cents;
  final bool active;
  final bool inTune;
  final double phase;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final color = !active ? Colors.white54 : inTune || cents.abs() <= 5 ? _green : cents.abs() <= 20 ? _amber : _red;
    final proximity = 1 - (cents.abs() / 50).clamp(0.0, 1.0);
    final radius = 12 + proximity * 11;
    final line = Paint()
      ..color = inTune ? color : Colors.white70
      ..strokeWidth = inTune ? 4 : 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(center.dx, 8), Offset(center.dx, size.height - 8), line);
    canvas.drawCircle(center, radius, Paint()..color = color.withOpacity(.24 + proximity * .2));
    canvas.drawCircle(center, radius * .58, Paint()..color = color);
    const count = 31;
    for (var i = 0; i < count; i++) {
      final normalized = i / (count - 1);
      final x = 10 + normalized * (size.width - 20);
      final side = (normalized - .5).abs() * 2;
      final pulse = .72 + .28 * math.sin(phase * math.pi * 2 + normalized * math.pi * 6);
      final height = active ? 22 + pulse * (38 + proximity * 60) * (.55 + side * .45) : 16 + side * 12;
      final paint = Paint()
        ..color = active ? color.withOpacity(.45 + side * .45) : Colors.white54
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(x, center.dy - height / 2), Offset(x, center.dy + height / 2), paint);
    }
  }
  @override
  bool shouldRepaint(covariant _WavePainter old) => old.cents != cents || old.active != active || old.inTune != inTune || old.phase != phase;
}

class _Ruler extends CustomPainter {
  const _Ruler({required this.cents, required this.active, required this.inTune});
  final double cents;
  final bool active;
  final bool inTune;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.width / 2;
    final marker = center + (cents.clamp(-50.0, 50.0) / 50) * (size.width / 2 - 8);
    final ticks = Paint()..strokeWidth = 3..strokeCap = StrokeCap.round;
    for (var i = 0; i <= 20; i++) {
      final c = -50 + i * 5;
      ticks.color = c.abs() <= 5 ? _green : c.abs() <= 20 ? _amber : _red;
      final x = i / 20 * size.width;
      canvas.drawLine(Offset(x, 4), Offset(x, c % 10 == 0 ? 52 : 35), ticks);
    }
    final p = Paint()
      ..color = active ? (inTune ? _green : Colors.white) : Colors.white38
      ..strokeWidth = inTune ? 5 : 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(marker, 3), Offset(marker, 58), p);
    _label(canvas, size, '-50', 0, TextAlign.left);
    _label(canvas, size, '0', .5, TextAlign.center);
    _label(canvas, size, '+50', 1, TextAlign.right);
  }
  void _label(Canvas canvas, Size size, String text, double fraction, TextAlign align) {
    final tp = TextPainter(text: TextSpan(text: text, style: const TextStyle(color: Colors.white54, fontSize: 11)), textDirection: TextDirection.ltr)..layout();
    final x = fraction * size.width;
    final left = align == TextAlign.left ? x : align == TextAlign.right ? x - tp.width : x - tp.width / 2;
    tp.paint(canvas, Offset(left, 63));
  }
  @override
  bool shouldRepaint(covariant _Ruler old) => old.cents != cents || old.active != active || old.inTune != inTune;
}
