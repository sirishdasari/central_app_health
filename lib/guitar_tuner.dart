import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
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
/// - one short chime when a selected string is successfully verified
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
      backgroundColor: _TunerColors.background,
      body: SafeArea(
        child: GuitarTunerSheet(embedded: true),
      ),
    );
  }
}

class _TunerColors {
  static const background = Color(0xFF06151D);
  static const panel = Color(0xFF081922);
  static const card = Color(0xFF0C222D);
  static const cardBorder = Color(0xFF193642);
  static const text = Color(0xFFF2F5F6);
  static const muted = Color(0xFF8E9AA0);
  static const dim = Color(0xFF56666D);
  static const green = Color(0xFF19F59A);
  static const greenDark = Color(0xFF0A573B);
  static const red = Color(0xFFFF6E6E);
  static const amber = Color(0xFFFFC33D);
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
  final AudioPlayer _successPlayer = AudioPlayer();

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

  // Do not award a tick from one lucky audio frame. The selected string must
  // be detected consistently at the correct octave before it is verified.
  int _verificationString = -1;
  int _verificationFrames = 0;
  static const int _requiredVerificationFrames = 3;

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
  }

  @override
  void dispose() {
    _stopListening();
    _waveController.dispose();
    _successPlayer.dispose();
    _recorder.dispose();
    super.dispose();
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
          // Keep the proven speedometer-tuner audio path.
          autoGain: false,
          echoCancel: false,
          noiseSuppress: false,
        ),
      );

      _sampleBuffer.clear();
      if (!mounted) return;
      setState(() => _listening = true);
      _audioSubscription = stream.listen(
        _processPcm,
        onError: (_) {
          if (mounted) setState(() => _listening = false);
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

  void _processPcm(Uint8List bytes) {
    if (bytes.length < 2048) return;

    final samples = Int16List(bytes.length ~/ 2);
    final data = ByteData.sublistView(bytes);
    for (int i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little);
    }

    _sampleBuffer.addAll(samples);
    const windowSize = 4096;
    if (_sampleBuffer.length > windowSize * 2) {
      _sampleBuffer.removeRange(0, _sampleBuffer.length - windowSize);
    }
    if (_sampleBuffer.length < windowSize) return;

    final analysis = Int16List.fromList(
      _sampleBuffer.sublist(_sampleBuffer.length - windowSize),
    );

    double chunkSum = 0;
    for (final value in samples) chunkSum += value;
    final chunkMean = chunkSum / samples.length;
    double energy = 0;
    for (final value in samples) {
      final centered = value - chunkMean;
      energy += centered * centered;
    }
    final rms = math.sqrt(energy / samples.length);
    final signal = (rms / 1800).clamp(0.0, 1.0);

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

    final pitch = _detectPitch(analysis, sampleRate: 44100);
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

    // Detection tells us what was actually heard. The selected string is
    // always the verification target. This is critical for the two E strings:
    // E4 must verify the high E, while E2 must never verify it.
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
    _smoothedFrequency = smoothed;
    _smoothedCents = (_smoothedCents * 0.72) + (actualCents * 0.28);

    // First verify note identity/octave (within 50 cents), then require the
    // actual tuning to settle within +/-5 cents for several frames.
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
        // Keep the microphone callback free of blocking audio work.
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

    // This is the proven detector used by the original speedometer tuner:
    // full autocorrelation across the guitar range with the same 0.55
    // confidence threshold and parabolic refinement.
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

    double refinedLag = bestLag.toDouble();
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
      final wav = _makeSuccessWav();
      await _successPlayer.stop();
      await _successPlayer.play(BytesSource(wav));
    } catch (_) {
      // Chime is feedback only; never stop tuning if audio playback fails.
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      _playingSuccess = false;
    }
  }

  Uint8List _makeSuccessWav() {
    const sampleRate = 44100;
    const durationMs = 280;
    const count = sampleRate * durationMs ~/ 1000;
    final pcm = Int16List(count);

    for (int i = 0; i < count; i++) {
      final t = i / sampleRate;
      final attack = math.min(1.0, t / 0.012);
      final release = math.min(1.0, (durationMs / 1000 - t) / 0.09);
      final envelope = math.max(0.0, math.min(attack, release));
      final first = math.sin(2 * math.pi * 880 * t);
      final second =
          math.sin(2 * math.pi * 1320 * t) * (0.65 * math.min(1, t / 0.04));
      pcm[i] = ((first + second) * 0.22 * envelope * 32767).round();
    }

    final dataSize = pcm.length * 2;
    final buffer = ByteData(44 + dataSize);

    void writeAscii(int offset, String value) {
      for (int i = 0; i < value.length; i++) {
        buffer.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    buffer.setUint32(4, 36 + dataSize, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    buffer.setUint32(16, 16, Endian.little);
    buffer.setUint16(20, 1, Endian.little);
    buffer.setUint16(22, 1, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * 2, Endian.little);
    buffer.setUint16(32, 2, Endian.little);
    buffer.setUint16(34, 16, Endian.little);
    writeAscii(36, 'data');
    buffer.setUint32(40, dataSize, Endian.little);
    for (int i = 0; i < pcm.length; i++) {
      buffer.setInt16(44 + i * 2, pcm[i], Endian.little);
    }
    return buffer.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _strings[_selectedString];
    final detected = _strings[_detectedString];
    final statusColor = !_hasSignal
        ? _TunerColors.muted
        : _inTune
            ? _TunerColors.green
            : _TunerColors.text;

    final status = !_hasSignal
        ? 'PLAY A STRING'
        : _inTune
            ? 'IN TUNE'
            : detected.number == selected.number
                ? (_cents < 0 ? 'TUNE UP' : 'TUNE DOWN')
                : 'WRONG STRING';

    return Material(
      color: _TunerColors.background,
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
                      icon: const Icon(Icons.close_rounded),
                      color: Colors.white70,
                    )
                  else
                    const SizedBox(width: 48),
                  const Expanded(
                    child: Text(
                      'Guitar Tuner',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _TunerColors.text,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _listening ? _stopListening : _startListening,
                    icon: Icon(
                      _listening ? Icons.mic_rounded : Icons.mic_off_rounded,
                      color: _listening ? _TunerColors.green : _TunerColors.muted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _InfoChip(
                      label: 'TARGET',
                      value: '${selected.note} ${selected.number}',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _InfoChip(
                      label: 'DETECTED',
                      value: _hasSignal ? '${detected.note} ${detected.number}' : '—',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AnimatedBuilder(
                      animation: _waveController,
                      builder: (context, child) => CustomPaint(
                        size: const Size(double.infinity, 100),
                        painter: _TunerWavePainter(
                          cents: _cents,
                          active: _hasSignal,
                          inTune: _inTune,
                          phase: _waveController.value,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _hasSignal ? detected.note : '—',
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 84,
                        height: .95,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      _hasSignal ? '${_frequency.toStringAsFixed(1)} Hz' : '— Hz',
                      style: const TextStyle(
                        color: _TunerColors.muted,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _hasSignal
                          ? '${_cents >= 0 ? '+' : ''}${_cents.toStringAsFixed(1)} cents'
                          : '— cents',
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      status,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              _buildCentsRuler(),
              const SizedBox(height: 8),
              _buildStringSelector(),
              const SizedBox(height: 8),
              Text(
                _inTune
                    ? 'Verified target • ±5 cents • chime played'
                    : 'Tap a string, then pluck and hold it near the microphone.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _inTune ? _TunerColors.green : _TunerColors.muted,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCentsRuler() {
    return SizedBox(
      height: 76,
      child: CustomPaint(
        painter: _CentsRulerPainter(
          cents: _cents,
          active: _hasSignal,
          inTune: _inTune,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }

  Widget _buildStringSelector() {
    return Row(
      children: List.generate(_strings.length, (index) {
        final string = _strings[index];
        final selected = index == _selectedString;
        final tuned = _tunedStrings.contains(index);
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(
              left: index == 0 ? 0 : 4,
              right: index == _strings.length - 1 ? 0 : 4,
            ),
            child: _StringTile(
              string: string,
              selected: selected,
              tuned: tuned,
              onTap: () => _selectString(index),
            ),
          ),
        );
      }),
    );
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
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: _TunerColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _TunerColors.cardBorder),
      ),
      child: Column(
        children: [
          Text(label, style: const TextStyle(color: _TunerColors.dim, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.1)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(color: _TunerColors.text, fontSize: 14, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _StringTile extends StatelessWidget {
  const _StringTile({required this.string, required this.selected, required this.tuned, required this.onTap});
  final _TuningString string;
  final bool selected;
  final bool tuned;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final borderColor = tuned
        ? _TunerColors.green
        : selected
            ? _TunerColors.green.withOpacity(0.8)
            : _TunerColors.cardBorder;
    final background = tuned
        ? _TunerColors.greenDark.withOpacity(0.55)
        : _TunerColors.card;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        height: 82,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: borderColor, width: tuned || selected ? 1.7 : 1.0),
          boxShadow: tuned
              ? [BoxShadow(color: _TunerColors.green.withOpacity(0.22), blurRadius: 16, spreadRadius: 1)]
              : null,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  string.note,
                  style: TextStyle(
                    color: tuned
                        ? _TunerColors.green
                        : selected
                            ? _TunerColors.text
                            : _TunerColors.muted,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text('${string.number}', style: const TextStyle(color: _TunerColors.dim, fontSize: 11, fontWeight: FontWeight.w700)),
              ],
            ),
            if (tuned)
              Positioned(
                right: -5,
                top: -5,
                child: Container(
                  width: 25,
                  height: 25,
                  decoration: const BoxDecoration(color: _TunerColors.green, shape: BoxShape.circle),
                  child: const Icon(Icons.check_rounded, color: _TunerColors.background, size: 18),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TunerWavePainter extends CustomPainter {
  _TunerWavePainter({required this.cents, required this.active, required this.inTune, required this.phase});
  final double cents;
  final bool active;
  final bool inTune;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final glowPaint = Paint()
      ..color = inTune ? _TunerColors.green.withOpacity(0.12) : _TunerColors.green.withOpacity(0.04)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 26);
    if (active) canvas.drawCircle(Offset(centerX, centerY), 65, glowPaint);

    final linePaint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = inTune ? _TunerColors.green : _TunerColors.muted;
    canvas.drawLine(Offset(centerX, 14), Offset(centerX, size.height - 10), linePaint);

    canvas.drawCircle(
      Offset(centerX, centerY),
      inTune ? 18 : 13,
      Paint()..color = inTune ? _TunerColors.green : _TunerColors.text,
    );

    const count = 17;
    for (var i = 0; i < count; i++) {
      final normalized = i / (count - 1);
      final distance = (normalized - 0.5).abs() * 2;
      final wave = active
          ? math.sin((phase * math.pi * 2) + i * 0.45) * (1 - distance * 0.45)
          : 0.0;
      final height = active ? 28 + wave * (92 * (1 - normalized * 0.42)) : 16.0;
      final x = 12 + normalized * (size.width - 24);
      final paint = Paint()
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = inTune ? _TunerColors.green.withOpacity(0.75) : _TunerColors.muted.withOpacity(0.65);
      canvas.drawLine(Offset(x, centerY - height / 2), Offset(x, centerY + height / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TunerWavePainter oldDelegate) =>
      oldDelegate.cents != cents || oldDelegate.active != active || oldDelegate.inTune != inTune || oldDelegate.phase != phase;
}

class _CentsRulerPainter extends CustomPainter {
  _CentsRulerPainter({required this.cents, required this.active, required this.inTune});
  final double cents;
  final bool active;
  final bool inTune;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height * 0.55;
    final left = 16.0;
    final right = size.width - 16.0;
    final width = right - left;
    final base = Paint()..color = _TunerColors.cardBorder..strokeWidth = 2..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(left, centerY), Offset(right, centerY), base);

    final greenZone = Paint()
      ..color = _TunerColors.green.withOpacity(0.18)
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(_x(left, width, -5), centerY), Offset(_x(left, width, 5), centerY), greenZone);

    for (var i = -5; i <= 5; i++) {
      final x = _x(left, width, i * 10.0);
      final tickHeight = i == 0 ? 20.0 : 11.0;
      final tickPaint = Paint()
        ..color = i == 0 ? _TunerColors.text : _TunerColors.dim
        ..strokeWidth = i == 0 ? 2.4 : 1.4;
      canvas.drawLine(Offset(x, centerY - tickHeight / 2), Offset(x, centerY + tickHeight / 2), tickPaint);
    }

    final markerCents = active ? cents.clamp(-50.0, 50.0) : 0.0;
    final markerX = _x(left, width, markerCents);
    final markerPaint = Paint()
      ..color = inTune ? _TunerColors.green : _TunerColors.text
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(markerX, centerY - 17), Offset(markerX, centerY + 17), markerPaint);

    const style = TextStyle(color: _TunerColors.dim, fontSize: 10, fontWeight: FontWeight.w700);
    _drawText(canvas, '-50', Offset(left, size.height - 5), style);
    _drawText(canvas, '0', Offset(size.width / 2, size.height - 5), style);
    _drawText(canvas, '+50', Offset(right, size.height - 5), style);
  }

  double _x(double left, double width, double centsValue) {
    final normalized = (centsValue + 50) / 100;
    return left + normalized.clamp(0.0, 1.0) * width;
  }

  void _drawText(Canvas canvas, String text, Offset center, TextStyle style) {
    final tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height));
  }

  @override
  bool shouldRepaint(covariant _CentsRulerPainter oldDelegate) =>
      oldDelegate.cents != cents || oldDelegate.active != active || oldDelegate.inTune != inTune;
}
