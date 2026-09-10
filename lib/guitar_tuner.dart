import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

/// Guitar Tuna-inspired tuner UI for Smart Guitar.
///
/// Keeps the existing public entry points:
///   GuitarTunerSheet(embedded: ...)
///   GuitarTunerScreen
///
/// The tuner is intentionally not a speedometer/gauge.  It uses:
/// - central vertical tuning line
/// - animated symmetric signal bars
/// - large detected note
/// - frequency + cents
/// - +/-50 cents ruler
/// - E A D G B E string selector
/// - simple selected-string tuning tolerance
/// - one short system click when a selected string is successfully tuned
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
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF06151D),
      body: SafeArea(child: GuitarTunerSheet(embedded: true)),
    );
  }
}

class _TuningString {
  const _TuningString(this.note, this.frequency, this.number);
  final String note;
  final double frequency;
  final int number;
}

const List<_TuningString> _strings = [
  _TuningString('E', 82.41, 6),
  _TuningString('A', 110.00, 5),
  _TuningString('D', 146.83, 4),
  _TuningString('G', 196.00, 3),
  _TuningString('B', 246.94, 2),
  _TuningString('E', 329.63, 1),
];

class _GuitarTunerSheetState extends State<GuitarTunerSheet>
    with SingleTickerProviderStateMixin {
  final AudioRecorder _recorder = AudioRecorder();

  StreamSubscription<Uint8List>? _audioSubscription;
  final List<int> _sampleBuffer = <int>[];
  late final AnimationController _waveController;

  bool _listening = false;
  bool _hasSignal = false;
  bool _inTune = false;
  bool _lastInTune = false;
  bool _playingSuccess = false;

  int _selectedString = 5;
  int _detectedString = 5;

  final Set<int> _tunedStrings = <int>{};

  double _frequency = 0;
  double _cents = 0;
  double _signal = 0;
  double _smoothedFrequency = 0;
  double _smoothedCents = 0;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startListening());
  }

  @override
  void dispose() {
    _stopListening();
    _waveController.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _toggleListening() async {
    if (_listening) {
      await _stopListening();
    } else {
      await _startListening();
    }
  }

  Future<void> _startListening() async {
    final allowed = await _recorder.hasPermission();
    if (!allowed || !mounted) return;

    await _audioSubscription?.cancel();

    try {
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 44100,
          numChannels: 1,
          autoGain: false,
          echoCancel: false,
          noiseSuppress: false,
        ),
      );

      if (!mounted) return;
      _sampleBuffer.clear();
      setState(() => _listening = true);

      _audioSubscription = stream.listen(
        _processPcm,
        onError: (_) {
          if (mounted) {
            setState(() {
              _hasSignal = false;
              _listening = false;
            });
          }
        },
      );
    } catch (_) {
      if (mounted) setState(() => _listening = false);
    }
  }

  Future<void> _stopListening() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    _sampleBuffer.clear();

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
      _signal = 0;
      _smoothedFrequency = 0;
      _smoothedCents = 0;
    });
  }

  void _selectString(int index) {
    if (_selectedString == index) return;

    setState(() {
      _selectedString = index;
      _detectedString = index;
      _inTune = false;
      _lastInTune = false;
      _smoothedFrequency = 0;
      _smoothedCents = 0;
    });
  }

  void _processPcm(Uint8List bytes) {
    if (bytes.length < 2048) return;

    final samples = Int16List(bytes.length ~/ 2);
    final data = ByteData.sublistView(bytes);

    double sum = 0;
    for (int i = 0; i < samples.length; i++) {
      final value = data.getInt16(i * 2, Endian.little);
      samples[i] = value;
      sum += value;
    }

    final mean = sum / samples.length;

    double energy = 0;
    for (int i = 0; i < samples.length; i++) {
      final centered = samples[i] - mean;
      energy += centered * centered;
    }

    final rms = math.sqrt(energy / samples.length);
    final signal = (rms / 1800).clamp(0.0, 1.0);

    _sampleBuffer.addAll(samples);
    const windowSize = 4096;
    if (_sampleBuffer.length > windowSize * 2) {
      _sampleBuffer.removeRange(0, _sampleBuffer.length - windowSize);
    }
    if (_sampleBuffer.length < windowSize) return;

    final analysisSamples = Int16List.fromList(
      _sampleBuffer.sublist(_sampleBuffer.length - windowSize),
    );

    if (rms < 180) {
      if (mounted) {
        setState(() {
          _hasSignal = false;
          _signal = signal;
          _inTune = false;
        });
      }
      return;
    }

    final pitch = _detectPitch(analysisSamples, sampleRate: 44100);

    if (pitch == null || pitch < 70 || pitch > 370) {
      if (mounted) {
        setState(() {
          _hasSignal = false;
          _signal = signal;
          _inTune = false;
        });
      }
      return;
    }

    final actualIndex = _closestString(pitch);
    final targetIndex = _selectedString;
    final actualReference = _strings[actualIndex];
    final targetReference = _strings[targetIndex];

    final actualCents =
        1200 * math.log(pitch / actualReference.frequency) / math.ln2;
    final targetCents =
        1200 * math.log(pitch / targetReference.frequency) / math.ln2;

    final smoothed = _smoothedFrequency == 0
        ? pitch
        : (_smoothedFrequency * 0.72) + (pitch * 0.28);
    final smoothedActualCents = (_smoothedCents * 0.72) +
        (actualCents * 0.28);

    _smoothedFrequency = smoothed;
    _smoothedCents = smoothedActualCents;

    // Small practical correction only: no multi-frame/perfect verification.
    final verified = actualIndex == targetIndex && targetCents.abs() <= 10.0;

    if (mounted) {
      setState(() {
        _hasSignal = true;
        _signal = signal;
        _frequency = smoothed;
        _cents = targetCents.clamp(-50.0, 50.0);
        _detectedString = actualIndex;
        _inTune = verified;
      });
    }

    if (verified) {
      _tunedStrings.add(targetIndex);
      if (!_lastInTune && !_playingSuccess) {
        _lastInTune = true;
        Future<void>.microtask(_playSuccessChime);
      }
    } else {
      _lastInTune = false;
    }
  }

  double? _detectPitch(
    Int16List input, {
    required int sampleRate,
  }) {
    const n = 4096;
    if (input.length < n) return null;

    var mean = 0.0;
    for (final value in input) mean += value;
    mean /= n;

    var energy = 0.0;
    for (final value in input) {
      final centered = value - mean;
      energy += centered * centered;
    }
    if (math.sqrt(energy / n) < 180) return null;

    final minLag = (sampleRate / 500).round();
    final maxLag = math.min((sampleRate / 70).round(), n ~/ 2);

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

      if (a2 <= 0 || b2 <= 0) continue;

      final correlation = dot / math.sqrt(a2 * b2);
      if (correlation > bestCorrelation) {
        bestCorrelation = correlation;
        bestLag = lag;
      }
    }

    if (bestLag == 0 || bestCorrelation < 0.55) return null;

    var refinedLag = bestLag.toDouble();

    if (bestLag > minLag && bestLag < maxLag) {
      double corrAt(int lag) {
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

        if (a2 <= 0 || b2 <= 0) return 0;
        return dot / math.sqrt(a2 * b2);
      }

      final y1 = corrAt(bestLag - 1);
      final y2 = corrAt(bestLag);
      final y3 = corrAt(bestLag + 1);
      final denominator = y1 - (2 * y2) + y3;

      if (denominator.abs() > 1e-9) {
        refinedLag += 0.5 * (y1 - y3) / denominator;
      }
    }

    if (refinedLag <= 0) return null;
    return sampleRate / refinedLag;
  }

  int _closestString(double frequency) {
    int best = 0;
    double error = double.infinity;

    for (int i = 0; i < _strings.length; i++) {
      final cents =
          (1200 * math.log(frequency / _strings[i].frequency) / math.ln2)
              .abs();

      if (cents < error) {
        error = cents;
        best = i;
      }
    }

    return best;
  }

  Future<void> _playSuccessChime() async {
    _playingSuccess = true;
    try {
      await SystemSound.play(SystemSoundType.click);
    } catch (_) {
      // Sound is optional. Never let feedback affect pitch detection.
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 180));
      _playingSuccess = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _strings[_selectedString];
    final detected = _strings[_detectedString];
    final color = !_hasSignal
        ? Colors.white70
        : _inTune || _cents.abs() <= 5
            ? const Color(0xFF19F59A)
            : _cents.abs() <= 20
                ? const Color(0xFFFFC33D)
                : const Color(0xFFFF6E6E);

    final wrongString = _hasSignal && _detectedString != _selectedString;

    return Material(
      color: const Color(0xFF06151D),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
          child: Column(
            children: [
              Row(
                children: [
                  if (!widget.embedded)
                    IconButton(
                      onPressed: widget.onClose ??
                          () => Navigator.maybePop(context),
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white70),
                    )
                  else
                    const SizedBox(width: 48),
                  const Expanded(
                    child: Text(
                      'Guitar Tuner',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _tunedStrings.clear();
                        _inTune = false;
                        _hasSignal = false;
                        _frequency = 0;
                        _cents = 0;
                        _signal = 0;
                        _smoothedFrequency = 0;
                        _smoothedCents = 0;
                      });
                    },
                    icon: const Icon(Icons.restart_alt_rounded,
                        color: Colors.white70),
                  ),
                  IconButton(
                    onPressed: _toggleListening,
                    icon: Icon(
                      _listening ? Icons.mic_rounded : Icons.mic_off_rounded,
                      color: color,
                    ),
                  ),
                ],
              ),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Play a string and tune to the center',
                  style: TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _Info('TARGET', '${selected.note}${selected.number}'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _Info(
                      'DETECTED',
                      _hasSignal ? '${detected.note}${detected.number}' : '—',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                decoration: BoxDecoration(
                  color: _inTune
                      ? const Color(0xFF19F59A).withOpacity(.12)
                      : const Color(0xFF0C222D),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: _inTune
                        ? const Color(0xFF19F59A)
                        : const Color(0xFF193642),
                  ),
                ),
                child: Text(
                  _inTune
                      ? '✓  IN TUNE'
                      : wrongString
                          ? 'WRONG STRING'
                          : _hasSignal
                              ? 'TUNE TO CENTER'
                              : 'PLAY A STRING',
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AnimatedBuilder(
                      animation: _waveController,
                      builder: (_, __) => SizedBox(
                        height: 170,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: _WavePainter(
                            cents: _cents,
                            active: _hasSignal,
                            inTune: _inTune,
                            phase: _waveController.value,
                          ),
                        ),
                      ),
                    ),
                    Text(
                      _hasSignal ? detected.note : '—',
                      style: TextStyle(
                        color: color,
                        fontSize: 78,
                        height: .9,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _hasSignal
                          ? '${_frequency.toStringAsFixed(1)} Hz'
                          : '— Hz',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _hasSignal
                          ? '${_cents >= 0 ? '+' : ''}${_cents.toStringAsFixed(1)} cents'
                          : '— cents',
                      style: TextStyle(
                        color: color,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 76,
                      child: CustomPaint(
                        painter: _CentsRulerPainter(
                          cents: _cents,
                          active: _hasSignal,
                          inTune: _inTune,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: List.generate(_strings.length, (index) {
                        final string = _strings[index];
                        final selectedTile = index == _selectedString;
                        final tuned = _tunedStrings.contains(index);
                        return Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              left: index == 0 ? 0 : 4,
                              right: index == _strings.length - 1 ? 0 : 4,
                            ),
                            child: _StringTile(
                              string: string,
                              selected: selectedTile,
                              tuned: tuned,
                              onTap: () => _selectString(index),
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 10),
                    AnimatedOpacity(
                      opacity: _hasSignal ? 1 : .7,
                      duration: const Duration(milliseconds: 150),
                      child: Text(
                        _hasSignal
                            ? (wrongString
                                ? 'Select the detected string'
                                : _inTune
                                    ? '✓  In tune!'
                                    : _cents < 0
                                        ? 'Tune up'
                                        : 'Tune down')
                            : 'Tap the microphone and pluck one string at a time.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: color,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
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
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0C222D),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFF193642)),
      ),
      child: Column(
        children: [
          Text(label,
              style: const TextStyle(
                  color: Colors.white30,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _StringTile extends StatelessWidget {
  const _StringTile({
    required this.string,
    required this.selected,
    required this.tuned,
    required this.onTap,
  });

  final _TuningString string;
  final bool selected;
  final bool tuned;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final border = tuned
        ? const Color(0xFF19F59A)
        : selected
            ? const Color(0xFF5C7884)
            : const Color(0xFF193642);
    final background = tuned
        ? const Color(0xFF083526)
        : selected
            ? const Color(0xFF102A35)
            : const Color(0xFF0C222D);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 64,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border, width: tuned || selected ? 2 : 1),
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(string.note,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          fontWeight: FontWeight.w900)),
                  Text('${string.number}',
                      style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
            if (tuned)
              const Positioned(
                top: 5,
                right: 7,
                child: Icon(Icons.check_circle,
                    size: 15, color: Color(0xFF19F59A)),
              ),
          ],
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  const _WavePainter({
    required this.cents,
    required this.active,
    required this.inTune,
    required this.phase,
  });

  final double cents;
  final bool active;
  final bool inTune;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final color = !active
        ? Colors.white54
        : inTune || cents.abs() <= 5
            ? const Color(0xFF19F59A)
            : cents.abs() <= 20
                ? const Color(0xFFFFC33D)
                : const Color(0xFFFF6E6E);

    final distance = (cents.abs() / 50).clamp(0.0, 1.0);
    final proximity = 1.0 - distance;
    final radius = 12 + proximity * 11;

    final line = Paint()
      ..color = inTune ? color : Colors.white70
      ..strokeWidth = inTune ? 4 : 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(center.dx, 8),
      Offset(center.dx, size.height - 8),
      line,
    );

    canvas.drawCircle(
      center,
      radius,
      Paint()..color = color.withOpacity(.24 + proximity * .2),
    );
    canvas.drawCircle(center, radius * .58, Paint()..color = color);

    const count = 31;
    for (var i = 0; i < count; i++) {
      final normalized = i / (count - 1);
      final x = 10 + normalized * (size.width - 20);
      final side = (normalized - .5).abs() * 2;
      final pulse = .72 + .28 *
          math.sin((phase * math.pi * 2) + (normalized * math.pi * 6));
      final height = active
          ? 22 + pulse * (38 + proximity * 60) * (.55 + side * .45)
          : 16 + side * 12;
      final barColor = active
          ? color.withOpacity(.45 + side * .45)
          : Colors.white54;
      final barPaint = Paint()
        ..color = barColor
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(x, center.dy - height / 2),
        Offset(x, center.dy + height / 2),
        barPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) {
    return oldDelegate.cents != cents ||
        oldDelegate.active != active ||
        oldDelegate.inTune != inTune ||
        oldDelegate.phase != phase;
  }
}

class _CentsRulerPainter extends CustomPainter {
  const _CentsRulerPainter({
    required this.cents,
    required this.active,
    required this.inTune,
  });

  final double cents;
  final bool active;
  final bool inTune;

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final markerX = centerX + (cents.clamp(-50.0, 50.0) / 50.0) *
        (size.width / 2 - 8);

    final tickPaint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    for (var i = 0; i <= 20; i++) {
      final fraction = i / 20;
      final x = fraction * size.width;
      final tickCents = -50 + i * 5;
      final tickColor = tickCents.abs() <= 5
          ? const Color(0xFF19F59A)
          : tickCents.abs() <= 20
              ? const Color(0xFFFFC33D)
              : const Color(0xFFFF6E6E);
      tickPaint.color = tickColor;
      final h = tickCents % 10 == 0 ? 52.0 : 35.0;
      canvas.drawLine(Offset(x, 4), Offset(x, h), tickPaint);
    }

    final marker = Paint()
      ..color = active
          ? (inTune ? const Color(0xFF19F59A) : Colors.white)
          : Colors.white38
      ..strokeWidth = inTune ? 5 : 4
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(markerX, 3), Offset(markerX, 58), marker);

    const text = TextStyle(color: Colors.white54, fontSize: 11);
    _label(canvas, size, '-50', 0, Alignment.centerLeft, text);
    _label(canvas, size, '0', .5, Alignment.center, text);
    _label(canvas, size, '+50', 1, Alignment.centerRight, text);
  }

  void _label(Canvas canvas, Size size, String value, double fraction,
      Alignment alignment, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: TextDirection.ltr,
    )..layout();

    final x = fraction * size.width;
    final left = alignment == Alignment.centerLeft
        ? x
        : alignment == Alignment.centerRight
            ? x - painter.width
            : x - painter.width / 2;
    painter.paint(canvas, Offset(left, 63));
  }

  @override
  bool shouldRepaint(covariant _CentsRulerPainter oldDelegate) {
    return oldDelegate.cents != cents ||
        oldDelegate.active != active ||
        oldDelegate.inTune != inTune;
  }
}
