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
  static const purple = Color(0xFFC9A7FF);

  final api = GuitarPracticeApi();
  Timer? timer;
  int elapsed = 0;
  int recordedMinutes = 0;
  bool running = true;
  bool saving = false;
  bool completed = false;

  @override
  void initState() {
    super.initState();
    recordedMinutes = widget.practice.dailyPracticeTime;
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (running && mounted) setState(() => elapsed++);
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  String fmt(int seconds) =>
      '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

  String mins(int value) => value < 60 ? '$value min' : '${value ~/ 60}h ${value % 60}m';

  Future<void> openLink() async {
    final uri = Uri.tryParse(widget.practice.link.trim());
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> recordTime() async {
    if (elapsed <= 0 || saving) return;
    setState(() => saving = true);
    try {
      final updated = await api.recordPractice(
        widget.practice.id,
        practicedSeconds: elapsed,
      );
      timer?.cancel();
      if (mounted) {
        setState(() {
          recordedMinutes = updated;
          elapsed = 0;
          running = false;
          saving = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Practice time recorded: $updated min total')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not record practice: $e')),
        );
      }
    }
  }

  Future<void> markCompleted() async {
    if (completed) return;
    try {
      await api.setCompleted(widget.practice.id, true);
      if (mounted) setState(() => completed = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not complete session: $e')),
        );
      }
    }
  }

  void done() => Navigator.pop(context, recordedMinutes);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Practice Session', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          PopupMenuButton<String>(
            onSelected: (_) => done(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'leave', child: Text('Leave session')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
        children: [
          _infoCard(),
          const SizedBox(height: 14),
          _suggestedTimeCard(),
          const SizedBox(height: 22),
          _timerCard(),
          const SizedBox(height: 18),
          _todayCard(),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: completed ? null : markCompleted,
                  child: Text(completed ? 'Completed ✓' : 'Completed'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: done,
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoCard() => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF17353D), card],
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.practice.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 25, fontWeight: FontWeight.w800)),
          const SizedBox(height: 9),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _chip(widget.practice.category),
            _chip(widget.practice.level, purple: true),
          ]),
          if (widget.practice.description.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(widget.practice.description, maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(color: muted, height: 1.35)),
          ],
          if (widget.practice.link.trim().isNotEmpty)
            TextButton.icon(
              onPressed: openLink,
              icon: const Icon(Icons.link_rounded, color: purple),
              label: const Text('Open practice video', style: TextStyle(color: purple, fontWeight: FontWeight.w700)),
            ),
        ]),
      );

  Widget _suggestedTimeCard() => Container(
        padding: const EdgeInsets.all(17),
        decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20)),
        child: Row(children: [
          const Icon(Icons.schedule_rounded, color: muted, size: 27),
          const SizedBox(width: 12),
          const Text('Suggested Time', style: TextStyle(color: muted)),
          const Spacer(),
          Text(widget.practice.suggestedTime.isEmpty ? '--' : widget.practice.suggestedTime, style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
        ]),
      );

  Widget _timerCard() => Column(children: [
        Center(
          child: SizedBox(
            width: 250,
            height: 250,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox(width: 235, height: 235, child: CircularProgressIndicator(value: null, strokeWidth: 12, backgroundColor: const Color(0xFF20353D), valueColor: const AlwaysStoppedAnimation<Color>(green))),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text(running ? 'PRACTICING' : 'PAUSED', style: TextStyle(color: running ? green : const Color(0xFFFFC14D), fontWeight: FontWeight.w800, fontSize: 13)),
                const SizedBox(height: 5),
                Text(fmt(elapsed), style: const TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.w800)),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Text('Recorded for this session: ${mins(recordedMinutes)}', style: const TextStyle(color: muted)),
        const SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _control(running ? Icons.pause_rounded : Icons.play_arrow_rounded, running ? 'Pause' : 'Resume', running ? const Color(0xFF31464F) : green, () {
            if (timer == null) {
              timer = Timer.periodic(const Duration(seconds: 1), (_) { if (running && mounted) setState(() => elapsed++); });
            }
            setState(() => running = !running);
          }),
          const SizedBox(width: 34),
          _control(Icons.stop_rounded, saving ? 'Saving' : 'Record Time', const Color(0xFFB94141), saving ? null : recordTime),
        ]),
      ]);

  Widget _todayCard() => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20)),
        child: Row(children: [
          const Icon(Icons.timer_outlined, color: green, size: 27),
          const SizedBox(width: 12),
          const Expanded(child: Text("Today's Practice", style: TextStyle(color: muted))),
          Text(mins(recordedMinutes), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
        ]),
      );

  Widget _chip(String text, {bool purple = false}) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: (purple ? const Color(0xFFC9A7FF) : green).withAlpha(28), borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(color: purple ? const Color(0xFFC9A7FF) : green, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }

  Widget _control(IconData icon, String label, Color color, VoidCallback? onTap) => Column(children: [
        InkWell(onTap: onTap, borderRadius: BorderRadius.circular(40), child: Container(width: 64, height: 64, decoration: BoxDecoration(color: color, shape: BoxShape.circle), child: Icon(icon, color: Colors.white, size: 31))),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      ]);
}
