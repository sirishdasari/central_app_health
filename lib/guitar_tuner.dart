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
/// - green success only after the SELECTED string is verified for several
///   consecutive frames at the correct octave and within +/-5 cents
/// - one short system click when a selected string is successfully verified
class GuitarTunerSheet extends StatefulWidget {
  const GuitarTunerSheet({
    super.key,
    this.embedded = false,
    this.onClose,
  });

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

  // Strings that have been successfully tuned during this tuner session.
  final Set<int> _tunedStrings = <int>{};

  // A tick is only awarded after the selected string has been detected
  // consistently. This prevents octave errors or another string from being
  // marked tuned.
  int _verificationString = -1;
  int _verificationFrames = 0;
  static const int _requiredVerificationFrames = 3;

  double _frequency = 0;
  double _cents = 0;
  double _signal = 0;

  // Smoothed pitch prevents the UI from jumping around between samples.
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
      _verificationString = -1;
      _verificationFrames = 0;
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
      _verificationString = -1;
      _verificationFrames = 0;
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

    // Proven working path: rolling 4096-sample window.
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
      _verificationString = -1;
      _verificationFrames = 0;
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
      _verificationString = -1;
      _verificationFrames = 0;
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

    // The selected string must match the detected string and be within
    // +/-50 cents before verification can start.
    final candidateMatchesTarget =
        actualIndex == targetIndex && targetCents.abs() <= 50.0;

    if (candidateMatchesTarget) {
      if (_verificationString == targetIndex) {
        _verificationFrames++;
      } else {
        _verificationString = targetIndex;
        _verificationFrames = 1;
      }
    } else {
      _verificationString = -1;
      _verificationFrames = 0;
    }

    final verified = candidateMatchesTarget &&
        _verificationFrames >= _requiredVerificationFrames &&
        targetCents.abs() <= 5.0;

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
        // Keep audio feedback completely outside the microphone/audio-player
        // path. AudioPlayer can compete with Android AudioRecord and interrupt
        // the stream, which was the source of the intermittent tuner freeze.
        Future<void>.microtask(_playSuccessChime);
      }
    } else {
      _lastInTune = false;
    }
  }

  // Proven detector from the original working speedometer tuner:
  // 4096-sample autocorrelation, 70-500 Hz range, correlation threshold .55,
  // and parabolic lag refinement.
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
    // IMPORTANT: do not use AudioPlayer while AudioRecorder is streaming.
    // Android can switch/compete for the audio route and interrupt the tuner.
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
                        _selectedString = 5;
                        _detectedString = 5;
                        _inTune = false;
                        _lastInTune = false;
                        _hasSignal = false;
                        _frequency = 0;
                        _cents = 0;
                        _signal = 0;
                        _smoothedFrequency = 0;
                        _smoothedCents = 0;
                        _verificationString = -1;
                        _verificationFrames = 0;
                        _sampleBuffer.clear();
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
                          painter: _Wave(
                            cents: _cents,
                            active: _hasSignal,
                            verified: _inTune,
                            phase: _waveController.value,
                          ),
                        ),
                      ),
                    ),
                    Text(
                      _hasSignal ? detected.note : '—',
                      style: TextStyle(
                        color: color,
                        fontSize: 82,
                        height: .95,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      _hasSignal
                          ? '${_frequency.toStringAsFixed(1)} Hz'
                          : '— Hz',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      _hasSignal
                          ? '${_cents >= 0 ? '+' : ''}${_cents.toStringAsFixed(1)} cents'
                          : '— cents',
                      style: TextStyle(
                        color: color,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 72,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _Ruler(_cents, _hasSignal, _inTune),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: List.generate(_strings.length, (i) {
                        final item = _strings[i];
                        final selectedCard = i == _selectedString;
                        final tuned = _tunedStrings.contains(i);
                        return Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(right: i == 5 ? 0 : 6),
                            child: GestureDetector(
                              onTap: () => _selectString(i),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 160),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  color: tuned
                                      ? const Color(0xFF123B2B)
                                      : const Color(0xFF0C222D),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: selectedCard
                                        ? color
                                        : const Color(0xFF193642),
                                    width: selectedCard ? 2 : 1,
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          item.note,
                                          style: TextStyle(
                                            color: tuned
                                                ? const Color(0xFF19F59A)
                                                : Colors.white,
                                            fontSize: 22,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                        if (tuned) ...[
                                          const SizedBox(width: 3),
                                          const Icon(Icons.check_rounded,
                                              color: Color(0xFF19F59A), size: 17),
                                        ],
                                      ],
                                    ),
                                    Text(
                                      '${item.number}',
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 12),
                    AnimatedOpacity(
                      opacity: _inTune ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.check_circle,
                              color: Color(0xFF19F59A), size: 28),
                          SizedBox(width: 8),
                          Text(
                            'In tune!',
                            style: TextStyle(
                              color: Color(0xFF19F59A),
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _signal > 0
                          ? 'Signal ${(_signal * 100).clamp(0, 100).toStringAsFixed(0)}%'
                          : 'Standard tuning • E A D G B E',
                      style: const TextStyle(
                        color: Colors.white30,
                        fontSize: 11,
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
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF0C222D),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: const Color(0xFF193642)),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Colors.white30,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      );
}

class _Wave extends CustomPainter {
  const _Wave({
    required this.cents,
    required this.active,
    required this.verified,
    required this.phase,
  });

  final double cents;
  final bool active;
  final bool verified;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final distance = (cents / 50).clamp(-1.0, 1.0);
    final distanceFromCenter = distance.abs();
    final proximity = 1.0 - distanceFromCenter;

    final color = !active
        ? Colors.white54
        : verified || distanceFromCenter <= .10
            ? const Color(0xFF19F59A)
            : distanceFromCenter <= .40
                ? const Color(0xFFFFC33D)
                : const Color(0xFFFF6E6E);

    final line = Paint()
      ..color = verified ? const Color(0xFF19F59A) : Colors.white70
      ..strokeWidth = verified ? 4 : 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(centerX, 8),
      Offset(centerX, size.height - 8),
      line,
    );

    const bars = 31;
    final pulse = .88 + .12 * math.sin(phase * math.pi * 2);
    for (var i = 0; i < bars; i++) {
      final normalized = i / (bars - 1);
      final fromCenter = (normalized - .5).abs() * 2;
      final envelope = math.max(0.10, 1 - fromCenter * 1.35);
      final phaseOffset = math.sin((i * .75) + phase * math.pi * 2);
      final height = active
          ? 18 + pulse * (36 + proximity * 62) * envelope *
              (.72 + .28 * phaseOffset.abs())
          : 16 + envelope * 10;
      final x = 10 + normalized * (size.width - 20);
      final barColor = active
          ? color.withOpacity(.45 + envelope * .55)
          : Colors.white54;
      final barPaint = Paint()
        ..color = barColor
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(x, centerY - height / 2),
        Offset(x, centerY + height / 2),
        barPaint,
      );
    }

    final radius = 10 + proximity * 14;
    final glow = Paint()
      ..color = color.withOpacity(active ? .18 + proximity * .22 : .08)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
    canvas.drawCircle(Offset(centerX, centerY), radius + 7, glow);

    final dot = Paint()..color = color.withOpacity(active ? .95 : .35);
    canvas.drawCircle(Offset(centerX, centerY), radius, dot);
  }

  @override
  bool shouldRepaint(covariant _Wave old) =>
      old.cents != cents ||
      old.active != active ||
      old.verified != verified ||
      old.phase != phase;
}

class _Ruler extends CustomPainter {
  const _Ruler(this.cents, this.active, this.verified);
  final double cents;
  final bool active;
  final bool verified;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = 25.0;
    final centerX = size.width / 2;

    final tickPaint = Paint()
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    for (var i = -20; i <= 20; i++) {
      final fraction = (i + 20) / 40;
      final x = fraction * size.width;
      final absCents = (i * 2.5).abs();
      tickPaint.color = !active
          ? Colors.white24
          : absCents <= 5
              ? const Color(0xFF19F59A)
              : absCents <= 20
                  ? const Color(0xFFFFC33D)
                  : const Color(0xFFFF6E6E);
      final h = i % 4 == 0 ? 35.0 : 25.0;
      canvas.drawLine(
        Offset(x, centerY - h / 2),
        Offset(x, centerY + h / 2),
        tickPaint,
      );
    }

    if (!active) return;

    final fraction = ((cents.clamp(-50.0, 50.0) + 50.0) / 100.0);
    final x = fraction * size.width;
    final marker = Paint()
      ..color = verified ? const Color(0xFF19F59A) : Colors.white
      ..strokeWidth = verified ? 5 : 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(x, 3), Offset(x, 58), marker);

    final text = const TextStyle(color: Colors.white54, fontSize: 11);
    _label(canvas, '-50', 0, 62, text, TextAlign.left);
    _label(canvas, '0', centerX, 62, text, TextAlign.center);
    _label(canvas, '+50', size.width, 62, text, TextAlign.right);
  }

  void _label(
    Canvas canvas,
    String value,
    double x,
    double y,
    TextStyle style,
    TextAlign align,
  ) {
    final p = TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = align == TextAlign.left
        ? x
        : align == TextAlign.right
            ? x - p.width
            : x - p.width / 2;
    p.paint(canvas, Offset(dx, y));
  }

  @override
  bool shouldRepaint(covariant _Ruler old) =>
      old.cents != cents || old.active != active || old.verified != verified;
}
