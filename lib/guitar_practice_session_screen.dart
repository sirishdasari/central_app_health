import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'guitar_practice_api.dart';

class GuitarPracticeSessionScreen extends StatefulWidget {
  const GuitarPracticeSessionScreen({super.key, required this.practice});
  final GuitarPractice practice;
  @override State<GuitarPracticeSessionScreen> createState() => _GuitarPracticeSessionScreenState();
}

class _GuitarPracticeSessionScreenState extends State<GuitarPracticeSessionScreen> {
  static const bg = Color(0xFF06131A), card = Color(0xFF0D202A), green = Color(0xFF45E88F), muted = Color(0xFF9BAAB0), purple = Color(0xFFC9A7FF);
  final api = GuitarPracticeApi();
  Timer? timer;
  int elapsed = 0;
  bool running = true, saving = false, finished = false;

  @override void initState() { super.initState(); timer = Timer.periodic(const Duration(seconds: 1), (_) { if (running && mounted) setState(() => elapsed++); }); }
  @override void dispose() { timer?.cancel(); super.dispose(); }

  String fmt(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  double get progress => widget.practice.duration <= 0 ? 0 : (elapsed / (widget.practice.duration * 60)).clamp(0.0, 1.0);

  Future<void> openLink() async {
    final uri = Uri.tryParse(widget.practice.link.trim());
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> recordTime() async {
    if (elapsed <= 0 || saving) return;
    setState(() => saving = true);
    try {
      await api.recordPractice(widget.practice.id, practicedSeconds: elapsed, practiceDate: DateTime.now());
      timer?.cancel();
      if (mounted) setState(() { finished = true; saving = false; });
    } catch (e) {
      if (mounted) { setState(() => saving = false); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not record practice: $e'))); }
    }
  }

  @override Widget build(BuildContext context) => Scaffold(backgroundColor: bg, appBar: AppBar(backgroundColor: Colors.transparent, foregroundColor: Colors.white, elevation: 0, title: const Text('Practice Session', style: TextStyle(fontWeight: FontWeight.w800)), actions: [PopupMenuButton<String>(onSelected: (_) => Navigator.pop(context), itemBuilder: (_) => const [PopupMenuItem(value: 'close', child: Text('Leave session'))])]), body: finished ? _summary() : _timerView());

  Widget _timerView() => SafeArea(child: ListView(padding: const EdgeInsets.fromLTRB(18, 8, 18, 30), children: [
    Container(height: 190, padding: const EdgeInsets.all(22), decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF17353D), Color(0xFF0D202A)])), child: Column(mainAxisAlignment: MainAxisAlignment.end, crossAxisAlignment: CrossAxisAlignment.start, children: [Text(widget.practice.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 25, fontWeight: FontWeight.w800)), const SizedBox(height: 8), Text(widget.practice.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: muted, height: 1.35))])),
    if (widget.practice.link.trim().isNotEmpty) Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: openLink, icon: const Icon(Icons.link_rounded, color: purple), label: const Text('Open practice video', style: TextStyle(color: purple, fontWeight: FontWeight.w700)))),
    Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20)), child: Row(children: [const Icon(Icons.schedule_rounded, color: muted, size: 28), const SizedBox(width: 14), const Text('Target Time (from Appwrite)', style: TextStyle(color: muted, fontSize: 12)), const Spacer(), Text('${widget.practice.duration} min', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800))])),
    const SizedBox(height: 22),
    Center(child: SizedBox(width: 235, height: 235, child: Stack(alignment: Alignment.center, children: [SizedBox(width: 225, height: 225, child: CircularProgressIndicator(value: progress, strokeWidth: 12, backgroundColor: const Color(0xFF20353D), valueColor: const AlwaysStoppedAnimation<Color>(green))), Column(mainAxisSize: MainAxisSize.min, children: [Text(fmt(elapsed), style: const TextStyle(color: Colors.white, fontSize: 44, fontWeight: FontWeight.w800)), Text('/ ${fmt(widget.practice.duration * 60)}', style: const TextStyle(color: muted, fontSize: 16)), if (!running) const Padding(padding: EdgeInsets.only(top: 6), child: Text('Paused', style: TextStyle(color: Color(0xFFFFC14D), fontWeight: FontWeight.w700)))])]))),
    const SizedBox(height: 24),
    Row(mainAxisAlignment: MainAxisAlignment.center, children: [_control(running ? Icons.pause_rounded : Icons.play_arrow_rounded, running ? 'Pause' : 'Resume', running ? const Color(0xFF31464F) : green, () => setState(() => running = !running)), const SizedBox(width: 34), _control(Icons.stop_rounded, saving ? 'Saving' : 'Record Time', const Color(0xFFB94141), saving ? null : recordTime)]),
    const SizedBox(height: 22),
    Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20)), child: Row(children: [Icon(running ? Icons.music_note_rounded : Icons.pause_circle_outline_rounded, color: running ? green : const Color(0xFFFFC14D), size: 28), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(running ? 'Practice is being recorded' : 'Practice is paused', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)), const SizedBox(height: 4), Text(running ? 'Your practice time will be saved to today’s total when you record.' : 'Your progress is saved. Resume whenever you’re ready.', style: const TextStyle(color: muted, fontSize: 12))]))]))
  ]));

  Widget _control(IconData icon, String label, Color color, VoidCallback? onTap) => Column(children: [InkWell(onTap: onTap, borderRadius: BorderRadius.circular(40), child: Container(width: 64, height: 64, decoration: BoxDecoration(color: color, shape: BoxShape.circle), child: Icon(icon, color: Colors.white, size: 31))), const SizedBox(height: 8), Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600))]);

  Widget _summary() => SafeArea(child: ListView(padding: const EdgeInsets.fromLTRB(22, 35, 22, 30), children: [const SizedBox(height: 20), const Center(child: Icon(Icons.check_circle_rounded, color: green, size: 88)), const SizedBox(height: 20), const Center(child: Text('Great job!', style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800))), const SizedBox(height: 8), const Center(child: Text('You practiced for', style: TextStyle(color: muted, fontSize: 16))), const SizedBox(height: 4), Center(child: Text(fmt(elapsed), style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w800))), const SizedBox(height: 4), Center(child: Text(widget.practice.title, textAlign: TextAlign.center, style: const TextStyle(color: muted, fontSize: 15))), const SizedBox(height: 30), _summaryBox(Icons.emoji_events_rounded, 'Today’s Practice', '${fmt(elapsed)} / ${widget.practice.duration} min'), const SizedBox(height: 12), _summaryBox(Icons.local_fire_department_rounded, 'Current Streak', 'Keep going!'), const SizedBox(height: 28), Row(children: [Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context, elapsed), child: const Text('Back to Practice'))), const SizedBox(width: 12), Expanded(child: FilledButton(onPressed: () => Navigator.pop(context, elapsed), child: const Text('Done')))])]));

  Widget _summaryBox(IconData icon, String title, String value) => Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20)), child: Row(children: [Icon(icon, color: green, size: 28), const SizedBox(width: 12), Expanded(child: Text(title, style: const TextStyle(color: muted))), Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))]));
}
