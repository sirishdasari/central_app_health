import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'guitar_practice_api.dart';
import 'guitar_practice_session_screen.dart';
import 'smart_guitar_ble.dart';

class GuitarPracticeHomeScreen extends StatefulWidget {
  const GuitarPracticeHomeScreen({super.key});
  @override
  State<GuitarPracticeHomeScreen> createState() => _GuitarPracticeHomeScreenState();
}

class _GuitarPracticeHomeScreenState extends State<GuitarPracticeHomeScreen> {
  final api = GuitarPracticeApi();
  GuitarPracticeResponse? data;
  bool loading = true, syncing = false, connected = false, completedOpen = false;
  StreamSubscription<String>? bleSub;
  static const bg = Color(0xFF06131A), card = Color(0xFF0D202A), green = Color(0xFF45E88F), muted = Color(0xFF9BAAB0), purple = Color(0xFFC9A7FF);

  @override
  void initState() { super.initState(); _load(); bleSub = SmartGuitarBle.instance.statusStream.listen((s) { if (mounted) setState(() => connected = s == 'connected'); }); }
  @override
  void dispose() { bleSub?.cancel(); super.dispose(); }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    try { final d = await api.list(); if (mounted) setState(() => data = d); }
    catch (e) { if (mounted) _msg('Load failed: $e'); }
    finally { if (mounted) setState(() => loading = false); }
  }

  Map<String, dynamic> _payload() => {
    'date': data?.date,
    'dailyPracticeTime': data?.dailyPracticeTime,
    'practices': (data?.practices ?? const <GuitarPractice>[]).map((p) => {
      'id': p.id, 'title': p.title, 'completed': p.completed, 'suggestedTime': p.suggestedTime,
      'duration': p.duration, 'description': p.description, 'dailyPracticeTime': p.dailyPracticeTime,
      'dailyPracticeSeconds': p.dailyPracticeSeconds, 'practiceDate': p.practiceDate, 'link': p.link,
    }).toList(),
  };

  Future<void> _sync() async {
    setState(() => syncing = true);
    try {
      final ble = SmartGuitarBle.instance;
      if (!ble.connected) { final found = await ble.scan(); if (found.isEmpty) throw Exception('Smart Guitar not found'); await ble.connect(found.first.device); }
      if (data != null) await ble.syncTasks(_payload());
      if (mounted) _msg('Smart Guitar synced');
    } catch (e) { if (mounted) _msg('Bluetooth sync failed: $e'); }
    finally { if (mounted) setState(() => syncing = false); }
  }

  Future<void> _start(GuitarPractice p) async {
    final result = await Navigator.push<int>(context, MaterialPageRoute(builder: (_) => GuitarPracticeSessionScreen(practice: p)));
    if (result != null && result > 0) await _load();
  }

  Future<void> _openLink(String value) async {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) { _msg('Invalid practice link'); return; }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) _msg('Could not open practice link');
  }

  Future<void> _toggle(GuitarPractice p) async {
    try { await api.update(p.id, {'completed': !p.completed}); await _load(); }
    catch (e) { if (mounted) _msg('Update failed: $e'); }
  }

  Future<void> _edit([GuitarPractice? p]) async {
    final value = await showModalBottomSheet<Map<String, dynamic>>(context: context, isScrollControlled: true, backgroundColor: card, builder: (_) => _Editor(item: p));
    if (value == null) return;
    try { if (p == null) await api.create(value); else await api.update(p.id, value); await _load(); if (connected) await _sync(); }
    catch (e) { if (mounted) _msg('Save failed: $e'); }
  }

  Future<void> _delete(GuitarPractice p) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(title: const Text('Delete practice?'), content: Text(p.title), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete'))]));
    if (ok != true) return;
    try { await api.delete(p.id); await _load(); } catch (e) { if (mounted) _msg('Delete failed: $e'); }
  }

  int get _todaySeconds {
    final now = DateTime.now();
    return (data?.practices ?? const <GuitarPractice>[]).fold(0, (sum, p) {
      final d = DateTime.tryParse(p.practiceDate);
      if (d == null || d.year != now.year || d.month != now.month || d.day != now.day) return sum;
      return sum + p.dailyPracticeSeconds;
    });
  }

  int get _streak {
    final dates = <DateTime>{};
    for (final p in data?.practices ?? const <GuitarPractice>[]) {
      if (p.dailyPracticeSeconds <= 0) continue;
      final d = DateTime.tryParse(p.practiceDate);
      if (d != null) dates.add(DateTime(d.year, d.month, d.day));
    }
    var day = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day), count = 0;
    while (dates.contains(day)) { count++; day = day.subtract(const Duration(days: 1)); }
    return count;
  }

  String _time(int seconds) => '${seconds ~/ 60} min';
  void _msg(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final all = data?.practices ?? const <GuitarPractice>[];
    final active = all.where((p) => !p.completed).toList();
    final completed = all.where((p) => p.completed).toList();
    final target = data?.dailyPracticeTime ?? 0;
    final today = _todaySeconds;
    final progress = target <= 0 ? 0.0 : (today / (target * 60)).clamp(0.0, 1.0);
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(backgroundColor: Colors.transparent, foregroundColor: Colors.white, elevation: 0, titleSpacing: 20,
        title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Guitar Practice', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)), SizedBox(height: 2), Text('Your daily practice plan, synced with Smart Guitar', style: TextStyle(fontSize: 12, color: muted))]),
        actions: [IconButton(onPressed: syncing ? null : _sync, icon: Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled, color: connected ? green : Colors.white54)), IconButton(onPressed: loading ? null : _load, icon: const Icon(Icons.refresh_rounded))]),
      floatingActionButton: FloatingActionButton(onPressed: () => _edit(), child: const Icon(Icons.add)),
      body: loading ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
        _dashboard(today, target, progress), const SizedBox(height: 22),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text("Today's Practice", style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)), Text('${active.length} sessions', style: const TextStyle(color: muted))]),
        const SizedBox(height: 12), if (active.isEmpty) _empty() else ...active.map(_card),
        if (completed.isNotEmpty) ...[const SizedBox(height: 4), _completedHeader(completed.length), if (completedOpen) ...completed.map(_card)],
      ])),
    );
  }

  Widget _dashboard(int today, int target, double progress) => Column(children: [
    Row(children: [Expanded(flex: 5, child: _box(child: Row(children: [SizedBox(width: 92, height: 92, child: Stack(alignment: Alignment.center, children: [CircularProgressIndicator(value: progress, strokeWidth: 9, backgroundColor: const Color(0xFF20353D), valueColor: const AlwaysStoppedAnimation<Color>(green)), Text(_time(today), style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800))])), const SizedBox(width: 14), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text("Today's Practice", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)), Text(_time(today), style: const TextStyle(color: Colors.white, fontSize: 25, fontWeight: FontWeight.w800)), Text('of $target min', style: const TextStyle(color: muted)), const SizedBox(height: 8), ClipRRect(borderRadius: BorderRadius.circular(8), child: LinearProgressIndicator(value: progress, minHeight: 7, backgroundColor: const Color(0xFF20353D), valueColor: const AlwaysStoppedAnimation<Color>(green)))])]))), const SizedBox(width: 10), Expanded(flex: 3, child: _box(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.local_fire_department_rounded, color: green, size: 28), const SizedBox(height: 8), const Text('Streak', style: TextStyle(color: muted, fontSize: 13)), Text('$_streak days', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)), Text(_streak == 0 ? 'Start today!' : 'Keep going!', style: const TextStyle(color: muted, fontSize: 12))])))])]),
    const SizedBox(height: 10),
    Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13), decoration: BoxDecoration(color: const Color(0xFF0B2420), borderRadius: BorderRadius.circular(20), border: Border.all(color: green.withAlpha(45))), child: Row(children: [Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled, color: connected ? green : Colors.white38), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Smart Guitar', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)), Text(connected ? 'ESP32 · Connected' : 'ESP32 · Not connected', style: const TextStyle(color: muted, fontSize: 12))])), OutlinedButton.icon(onPressed: syncing ? null : _sync, icon: syncing ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.sync_rounded, size: 17), label: Text(syncing ? 'Syncing' : 'Sync Now'))]))
  ]);

  Widget _box({required Widget child}) => Container(padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF15343D))), child: child);

  Widget _card(GuitarPractice p) => Container(margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.fromLTRB(12, 12, 6, 12), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF15343D))), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
    IconButton(onPressed: () => _toggle(p), icon: Icon(p.completed ? Icons.check_circle : Icons.radio_button_unchecked, color: p.completed ? green : Colors.white54, size: 28)),
    const SizedBox(width: 2), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)), const SizedBox(height: 4), Text('${p.suggestedTime}  ·  ${p.duration} min', style: const TextStyle(color: muted)), const SizedBox(height: 4), Text(p.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: muted, fontSize: 13)), if (p.link.trim().isNotEmpty) TextButton.icon(onPressed: () => _openLink(p.link), style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 30)), icon: const Icon(Icons.link_rounded, color: purple, size: 16), label: const Text('Open practice video', style: TextStyle(color: purple, fontWeight: FontWeight.w700))])), if (!p.completed) IconButton(onPressed: () => _start(p), style: IconButton.styleFrom(backgroundColor: green, foregroundColor: bg), icon: const Icon(Icons.play_arrow_rounded, size: 28)), PopupMenuButton<String>(onSelected: (v) { if (v == 'edit') _edit(p); if (v == 'delete') _delete(p); }, itemBuilder: (_) => const [PopupMenuItem(value: 'edit', child: Text('Edit')), PopupMenuItem(value: 'delete', child: Text('Delete'))])
  ]));

  Widget _completedHeader(int count) => InkWell(onTap: () => setState(() => completedOpen = !completedOpen), borderRadius: BorderRadius.circular(18), child: Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(18)), child: Row(children: [const Icon(Icons.check_circle_outline_rounded, color: Colors.white70), const SizedBox(width: 12), Expanded(child: Text('Completed ($count)', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16))), Icon(completedOpen ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: Colors.white70)])));
  Widget _empty() => _box(child: const Column(children: [Icon(Icons.music_note_rounded, color: muted, size: 34), SizedBox(height: 8), Text('No active sessions today', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700))]));
}

class _Editor extends StatefulWidget {
  const _Editor({this.item});
  final GuitarPractice? item;
  @override State<_Editor> createState() => _EditorState();
}
class _EditorState extends State<_Editor> {
  late final title = TextEditingController(text: widget.item?.title ?? '');
  late final time = TextEditingController(text: widget.item?.suggestedTime ?? '');
  late final duration = TextEditingController(text: widget.item?.duration.toString() ?? '');
  late final description = TextEditingController(text: widget.item?.description ?? '');
  late final link = TextEditingController(text: widget.item?.link ?? '');
  @override void dispose() { title.dispose(); time.dispose(); duration.dispose(); description.dispose(); link.dispose(); super.dispose(); }
  InputDecoration dec(String label, IconData icon) => InputDecoration(labelText: label, prefixIcon: Icon(icon), filled: true, fillColor: const Color(0xFF142B35), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none));
  @override Widget build(BuildContext context) => Padding(padding: EdgeInsets.fromLTRB(20, 18, 20, MediaQuery.viewInsetsOf(context).bottom + 20), child: SingleChildScrollView(child: Column(children: [Text(widget.item == null ? 'Add practice' : 'Edit practice', style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)), TextField(controller: title, decoration: dec('Title', Icons.music_note), style: const TextStyle(color: Colors.white)), TextField(controller: time, decoration: dec('Suggested time (HH:mm)', Icons.schedule), style: const TextStyle(color: Colors.white)), TextField(controller: duration, keyboardType: TextInputType.number, decoration: dec('Duration (minutes)', Icons.timer), style: const TextStyle(color: Colors.white)), TextField(controller: description, maxLines: 4, decoration: dec('Description', Icons.notes), style: const TextStyle(color: Colors.white)), TextField(controller: link, keyboardType: TextInputType.url, decoration: dec('Practice link', Icons.link_rounded), style: const TextStyle(color: Colors.white)), FilledButton(onPressed: () { final n = int.tryParse(duration.text); if (title.text.trim().isEmpty || n == null || n <= 0) return; Navigator.pop(context, {'title': title.text.trim(), 'suggestedTime': time.text.trim(), 'duration': n, 'description': description.text.trim(), 'link': link.text.trim(), 'completed': widget.item?.completed ?? false}); }, child: const Text('Save'))])));
}
