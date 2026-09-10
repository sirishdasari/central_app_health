import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'guitar_practice_api.dart';

class GuitarPracticeSessionScreen extends StatefulWidget {
  const GuitarPracticeSessionScreen({super.key, required this.practice});

  final GuitarPractice practice;

  @override
  State<GuitarPracticeSessionScreen> createState() => _GuitarPracticeSessionScreenState();
}

class _GuitarPracticeSessionScreenState extends State<GuitarPracticeSessionScreen> {
  static const bg = Color(0xFF06131A);
  static const card = Color(0xFF0D202A);
  static const green = Color(0xFF45E88F);
  static const muted = Color(0xFF9BAAB0);

  final api = GuitarPracticeApi();
  Timer? _timer;
  int _elapsedSeconds = 0;
  bool _running = true;
  bool _recording = false;
  bool _saved = false;

  int get _targetSeconds => widget.practice.duration * 60;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_running || !mounted) return;
      setState(() => _elapsedSeconds++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _format(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _openLink() async {
    final uri = Uri.tryParse(widget.practice.link.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _recordAndFinish() async {
    if (_elapsedSeconds <= 0 || _recording) return;
    setState(() => _recording = true);
    try {
      await api.recordPractice(
        widget.practice.id,
        practicedSeconds: _elapsedSeconds,
        practiceDate: DateTime.now(),
      );
      if (!mounted) return;
      _saved = true;
      Navigator.pop(context, _elapsedSeconds);
    } catch (e) {
      if (mounted) {
        setState(() => _recording = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not record practice: $e')),
        );
      }
    }
  }

  Future<void> _finishWithoutSaving() async {
    _timer?.cancel();
    if (_elapsedSeconds == 0) {
      Navigator.pop(context);
      return;
    }
    await _recordAndFinish();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _targetSeconds <= 0
        ? 0.0
        : (_elapsedSeconds / _targetSeconds).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Practice Session', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'finish') _finishWithoutSaving();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'finish', child: Text('Finish & record')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
          children: [
            Container(
              height: 190,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF17353D), Color(0xFF0D202A)],
                ),
              ),
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(widget.practice.title,
                      style: const TextStyle(color: Colors.white, fontSize: 25, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Text(widget.practice.description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: muted, fontSize: 14, height: 1.35)),
                ],
              ),
            ),
            if (widget.practice.link.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _openLink,
                  icon: const Icon(Icons.link_rounded, color: Color(0xFFC9A7FF)),
                  label: const Text('Open practice video', style: TextStyle(color: Color(0xFFC9A7FF), fontWeight: FontWeight.w700)),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20)),
              child: Row(
                children: [
                  const Icon(Icons.schedule_rounded, color: muted, size: 28),
                  const SizedBox(width: 14),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Target Time (from Appwrite)', style: TextStyle(color: muted, fontSize: 12)),
                    ],
                  ),
                  const Spacer(),
                  Text('${widget.practice.duration} min', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                ],
              ),
            ),
            const SizedBox(height: 22),
            Center(
              child: SizedBox(
                width: 235,
                height: 235,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 225,
                      height: 225,
                      child: CircularProgressIndicator(
                        value: progress,
                        strokeWidth: 12,
                        backgroundColor: const Color(0xFF20353D),
                        valueColor: const AlwaysStoppedAnimation<Color>(green),
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_format(_elapsedSeconds), style: const TextStyle(color: Colors.white, fontSize: 44, fontWeight: FontWeight.w800)),
                        Text('/ ${_format(_targetSeconds)}', style: const TextStyle(color: muted, fontSize: 16)),
                        if (!_running) const Padding(padding: EdgeInsets.only(top: 6), child: Text('Paused', style: TextStyle(color: Color(0xFFFFC14D), fontWeight: FontWeight.w700))),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _control(
                  icon: _running ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  label: _running ? 'Pause' : 'Resume',
                  color: _running ? const Color(0xFF31464F) : green,
                  onTap: () => setState(() => _running = !_running),
                ),
                const SizedBox(width: 34),
                _control(
                  icon: Icons.stop_rounded,
                  label: _recording ? 'Recording' : 'Finish',
                  color: const Color(0xFFB94141),
                  onTap: _recording ? null : _finishWithoutSaving,
                ),
              ],
            ),
            const SizedBox(height: 22),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20)),
              child: Row(
                children: [
                  Icon(_running ? Icons.music_note_rounded : Icons.pause_circle_outline_rounded,
                      color: _running ? green : const Color(0xFFFFC14D), size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_running ? 'Practice is being recorded' : 'Practice is paused',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Text(_running
                            ? 'Your practice time will be saved to today’s total when you finish.'
                            : 'Your progress is saved. Resume whenever you’re ready.',
                            style: const TextStyle(color: muted, fontSize: 12, height: 1.35)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _control({required IconData icon, required String label, required Color color, required VoidCallback? onTap}) {
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(40),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 31),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
