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
  String selectedLevel = 'All';
  String selectedCategory = 'All';
  StreamSubscription<String>? bleSub;

  static const bg = Color(0xFF06131A);
  static const card = Color(0xFF0D202A);
  static const green = Color(0xFF45E88F);
  static const muted = Color(0xFF9BAAB0);
  static const purple = Color(0xFFC9A7FF);
  static const border = Color(0xFF15343D);

  @override
  void initState() {
    super.initState();
    _load();
    bleSub = SmartGuitarBle.instance.statusStream.listen((s) {
      if (mounted) setState(() => connected = s == 'connected');
    });
  }

  @override
  void dispose() {
    bleSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    try {
      final r = await api.list();
      if (mounted) setState(() => data = r);
    } catch (e) {
      if (mounted) _msg('Load failed: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Map<String, dynamic> _payload() => {
        'practices': (data?.practices ?? const <GuitarPractice>[]).map((p) => {
              'id': p.id,
              'title': p.title,
              'completed': p.completed,
              'suggestedTime': p.suggestedTime,
              'description': p.description,
              'dailyPracticeTime': p.dailyPracticeTime,
              'category': p.category,
              'level': p.level,
              'link': p.link,
            }).toList(),
      };

  Future<void> _sync() async {
    if (syncing) return;
    setState(() => syncing = true);
    try {
      final ble = SmartGuitarBle.instance;
      if (!ble.connected) {
        final found = await ble.scan();
        if (found.isEmpty) throw Exception('Smart Guitar not found. Turn on Bluetooth on the guitar.');
        await ble.connect(found.first.device);
      }
      if (data != null) await ble.syncTasks(_payload());
      if (mounted) _msg('Smart Guitar synced');
    } catch (e) {
      if (mounted) _msg('Bluetooth sync failed: $e');
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  Future<void> _start(GuitarPractice p) async {
    final result = await Navigator.push<int>(context, MaterialPageRoute(builder: (_) => GuitarPracticeSessionScreen(practice: p)));
    if (result != null && mounted) await _load();
  }

  Future<void> _openLink(String value) async {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      _msg('Invalid practice link');
      return;
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && mounted) _msg('Could not open practice link');
  }

  Future<void> _toggle(GuitarPractice p) async {
    try {
      await api.update(p.id, {'completed': !p.completed});
      await _load();
    } catch (e) {
      if (mounted) _msg('Update failed: $e');
    }
  }

  Future<void> _edit([GuitarPractice? p]) async {
    final value = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: card,
      builder: (_) => _Editor(item: p),
    );
    if (value == null) return;
    try {
      if (p == null) await api.create(value); else await api.update(p.id, value);
      await _load();
      if (connected && mounted) await _sync();
    } catch (e) {
      if (mounted) _msg('Save failed: $e');
    }
  }

  Future<void> _delete(GuitarPractice p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete practice?'),
        content: Text(p.title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.delete(p.id);
      await _load();
      if (connected && mounted) await _sync();
    } catch (e) {
      if (mounted) _msg('Delete failed: $e');
    }
  }

  int get _todayMinutes => (data?.practices ?? const <GuitarPractice>[]).fold<int>(0, (sum, p) => sum + p.dailyPracticeTime);

  List<GuitarPractice> _filtered(List<GuitarPractice> source) => source.where((p) {
        final levelOk = selectedLevel == 'All' || p.level == selectedLevel;
        final categoryOk = selectedCategory == 'All' || p.category == selectedCategory;
        return levelOk && categoryOk;
      }).toList();

  List<String> get _categories {
    final values = (data?.practices ?? const <GuitarPractice>[]).map((p) => p.category.trim()).where((v) => v.isNotEmpty).toSet().toList()..sort();
    return ['All', ...values];
  }

  String _time(int minutes) => minutes < 60 ? '$minutes min' : '${minutes ~/ 60}h ${minutes % 60}m';

  void _msg(String s) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  Widget build(BuildContext context) {
    final all = data?.practices ?? const <GuitarPractice>[];
    final active = _filtered(all.where((p) => !p.completed).toList());
    final completed = _filtered(all.where((p) => p.completed).toList());

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 20,
        title: const Text('Guitar Practice', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800)),
        actions: [
          IconButton(tooltip: 'Sync with Smart Guitar', onPressed: syncing ? null : _sync, icon: Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled, color: connected ? green : Colors.white54)),
          IconButton(tooltip: 'Refresh', onPressed: loading ? null : _load, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      floatingActionButton: FloatingActionButton(onPressed: () => _edit(), child: const Icon(Icons.add)),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                children: [
                  _summary(),
                  const SizedBox(height: 18),
                  Row(children: [
                    const Expanded(child: Text("Today's Practice", style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800))),
                    PopupMenuButton<String>(
                      tooltip: 'Filter',
                      icon: const Icon(Icons.filter_list_rounded, color: Colors.white70),
                      itemBuilder: (_) => [
                        const PopupMenuItem(enabled: false, child: Text('Difficulty')),
                        ...['All', 'Beginner', 'Intermediate', 'Advanced'].map((v) => CheckedPopupMenuItem(value: 'level:$v', checked: selectedLevel == v, child: Text(v))),
                        const PopupMenuDivider(),
                        const PopupMenuItem(enabled: false, child: Text('Category')),
                        ..._categories.map((v) => CheckedPopupMenuItem(value: 'category:$v', checked: selectedCategory == v, child: Text(v))),
                      ],
                      onSelected: (v) {
                        final parts = v.split(':');
                        setState(() {
                          if (parts.first == 'level') selectedLevel = parts.sublist(1).join(':');
                          if (parts.first == 'category') selectedCategory = parts.sublist(1).join(':');
                        });
                      },
                    ),
                  ]),
                  if (selectedLevel != 'All' || selectedCategory != 'All') Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 8),
                    child: Row(children: [
                      if (selectedLevel != 'All') _chip(selectedLevel, purple: true),
                      if (selectedCategory != 'All') ...[const SizedBox(width: 6), _chip(selectedCategory)],
                      const Spacer(),
                      TextButton(onPressed: () => setState(() { selectedLevel = 'All'; selectedCategory = 'All'; }), child: const Text('Clear')),
                    ]),
                  ),
                  const SizedBox(height: 6),
                  if (active.isEmpty) _empty() else ...active.map(_card),
                  if (completed.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _completedHeader(completed.length),
                    if (completedOpen) ...[const SizedBox(height: 8), ...completed.map(_card)],
                  ],
                ],
              ),
            ),
    );
  }

  Widget _summary() => Row(children: [
        Expanded(child: _stat(Icons.timer_outlined, _time(_todayMinutes), "Today's Practice")),
        const SizedBox(width: 8),
        Expanded(child: _stat(Icons.check_circle_rounded, '${data?.practices.where((p) => p.completed).length ?? 0}', 'Completed')),
        const SizedBox(width: 8),
        Expanded(child: _syncStat()),
      ]);

  Widget _stat(IconData icon, String value, String label) => Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(18), border: Border.all(color: border)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, color: green, size: 21), const SizedBox(height: 7), Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)), Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: muted, fontSize: 10))]));

  Widget _syncStat() => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(18), border: Border.all(color: border)), child: Row(children: [Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled, color: connected ? green : Colors.white54, size: 21), const SizedBox(width: 6), Expanded(child: TextButton(onPressed: syncing ? null : _sync, child: Text(syncing ? 'Syncing' : 'Sync', style: TextStyle(color: connected ? green : purple, fontWeight: FontWeight.w800))))]));

  Widget _chip(String text, {bool purple = false}) {
    return Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4), decoration: BoxDecoration(color: (purple ? const Color(0xFFC9A7FF) : green).withAlpha(28), borderRadius: BorderRadius.circular(20)), child: Text(text, style: TextStyle(color: purple ? const Color(0xFFC9A7FF) : green, fontSize: 11, fontWeight: FontWeight.w700)));
  }

  Widget _card(GuitarPractice p) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
        decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20), border: Border.all(color: border)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconButton(onPressed: () => _toggle(p), icon: Icon(p.completed ? Icons.check_circle : Icons.radio_button_unchecked, color: p.completed ? green : Colors.white54, size: 28)),
          const SizedBox(width: 2),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 5, children: [_chip(p.category), _chip(p.level, purple: true)]),
            const SizedBox(height: 5),
            Row(children: [const Icon(Icons.schedule_rounded, color: muted, size: 15), const SizedBox(width: 5), Text(p.suggestedTime.isEmpty ? 'No suggested time' : p.suggestedTime, style: const TextStyle(color: muted)), const SizedBox(width: 10), const Icon(Icons.timer_outlined, color: muted, size: 15), const SizedBox(width: 4), Text('Practiced ${_time(p.dailyPracticeTime)}', style: const TextStyle(color: muted))]),
            if (p.description.trim().isNotEmpty) ...[const SizedBox(height: 4), Text(p.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: muted, fontSize: 13))],
            if (p.link.trim().isNotEmpty) TextButton.icon(onPressed: () => _openLink(p.link), style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 30), tapTargetSize: MaterialTapTargetSize.shrinkWrap), icon: const Icon(Icons.link_rounded, color: purple, size: 16), label: const Text('Open practice video', style: TextStyle(color: purple, fontWeight: FontWeight.w700))),
          ])),
          Column(children: [
            if (!p.completed) IconButton(tooltip: 'Start practice', onPressed: () => _start(p), style: IconButton.styleFrom(backgroundColor: green, foregroundColor: bg), icon: const Icon(Icons.play_arrow_rounded, size: 28)),
            PopupMenuButton<String>(onSelected: (v) { if (v == 'edit') _edit(p); if (v == 'delete') _delete(p); }, itemBuilder: (_) => const [PopupMenuItem(value: 'edit', child: Text('Edit')), PopupMenuItem(value: 'delete', child: Text('Delete'))]),
          ]),
        ]),
      );

  Widget _completedHeader(int count) => InkWell(onTap: () => setState(() => completedOpen = !completedOpen), borderRadius: BorderRadius.circular(18), child: Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(18)), child: Row(children: [const Icon(Icons.check_circle_outline_rounded, color: Colors.white70), const SizedBox(width: 12), Expanded(child: Text('Completed ($count)', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16))), Icon(completedOpen ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: Colors.white70)])));

  Widget _empty() => _box(child: const Column(children: [Icon(Icons.music_note_rounded, color: muted, size: 34), SizedBox(height: 8), Text('No practice sessions match these filters', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700))]));
  Widget _box({required Widget child}) => Container(padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20), border: Border.all(color: border)), child: child);
}

class _Editor extends StatefulWidget {
  const _Editor({this.item});
  final GuitarPractice? item;
  @override State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final title = TextEditingController(text: widget.item?.title ?? '');
  late final time = TextEditingController(text: widget.item?.suggestedTime ?? '');
  late final dailyPracticeTime = TextEditingController(text: widget.item?.dailyPracticeTime.toString() ?? '0');
  late final description = TextEditingController(text: widget.item?.description ?? '');
  late final link = TextEditingController(text: widget.item?.link ?? '');
  late final category = TextEditingController(text: widget.item?.category ?? '');
  late String level = widget.item?.level ?? '';
  static const levels = ['Beginner', 'Intermediate', 'Advanced'];

  @override
  void dispose() {
    title.dispose(); time.dispose(); dailyPracticeTime.dispose(); description.dispose(); link.dispose(); category.dispose();
    super.dispose();
  }

  InputDecoration _dec(String label, IconData icon) => InputDecoration(labelText: label, prefixIcon: Icon(icon), filled: true, fillColor: const Color(0xFF142B35), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none));

  void _save() {
    final t = title.text.trim();
    final daily = int.tryParse(dailyPracticeTime.text.trim());
    if (t.isEmpty) return _msg('Enter a practice title');
    if (daily == null || daily < 0) return _msg('Enter a valid daily practice time');
    if (level.isEmpty) return _msg('Select a difficulty level');
    Navigator.pop(context, {'title': t, 'suggestedTime': time.text.trim(), 'description': description.text.trim(), 'dailyPracticeTime': daily, 'category': category.text.trim(), 'level': level, 'link': link.text.trim(), 'completed': widget.item?.completed ?? false});
  }

  void _msg(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(child: Padding(padding: EdgeInsets.fromLTRB(20, 18, 20, bottom + 20), child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(widget.item == null ? 'Add practice' : 'Edit practice', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
      const SizedBox(height: 18),
      TextField(controller: title, decoration: _dec('Session name', Icons.music_note), style: const TextStyle(color: Colors.white)),
      const SizedBox(height: 10),
      TextField(controller: category, decoration: _dec('Category', Icons.category_outlined), style: const TextStyle(color: Colors.white)),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(value: level.isEmpty ? null : level, decoration: _dec('Difficulty level', Icons.signal_cellular_alt_rounded), dropdownColor: const Color(0xFF142B35), items: levels.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(), onChanged: (v) => setState(() => level = v ?? '')),
      const SizedBox(height: 10),
      TextField(controller: time, decoration: _dec('Suggested time (HH:mm)', Icons.schedule), style: const TextStyle(color: Colors.white)),
      const SizedBox(height: 10),
      TextField(controller: dailyPracticeTime, keyboardType: TextInputType.number, decoration: _dec('Practice time (minutes)', Icons.timer_outlined), style: const TextStyle(color: Colors.white)),
      const SizedBox(height: 10),
      TextField(controller: description, maxLines: 4, decoration: _dec('Description', Icons.notes), style: const TextStyle(color: Colors.white)),
      const SizedBox(height: 10),
      TextField(controller: link, keyboardType: TextInputType.url, decoration: _dec('Practice video URL', Icons.link_rounded), style: const TextStyle(color: Colors.white)),
      const SizedBox(height: 16),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ]))));
  }
}
