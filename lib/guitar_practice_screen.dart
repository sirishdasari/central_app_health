import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'guitar_practice_api.dart';
import 'smart_guitar_ble.dart';

class GuitarPracticeScreen extends StatefulWidget {
  const GuitarPracticeScreen({super.key});

  @override
  State<GuitarPracticeScreen> createState() => _GuitarPracticeScreenState();
}

class _GuitarPracticeScreenState extends State<GuitarPracticeScreen> {
  final api = GuitarPracticeApi();
  GuitarPracticeResponse? data;
  bool loading = true;
  bool bleBusy = false;
  bool bleConnected = false;
  bool completedExpanded = false;
  StreamSubscription<String>? _bleSub;

  static const bg = Color(0xFF06131A);
  static const card = Color(0xFF0D202A);
  static const green = Color(0xFF45E88F);
  static const muted = Color(0xFF9BAAB0);

  @override
  void initState() {
    super.initState();
    _load();
    _listenBle();
  }

  void _listenBle() {
    _bleSub = SmartGuitarBle.instance.statusStream.listen((s) {
      if (mounted) setState(() => bleConnected = s == 'connected');
    });
  }

  @override
  void dispose() {
    _bleSub?.cancel();
    super.dispose();
  }

  Map<String, dynamic> _blePayload(GuitarPracticeResponse payload) => {
        'date': payload.date,
        'dailyPracticeTime': payload.dailyPracticeTime,
        'practices': payload.practices
            .map((p) => {
                  'id': p.id,
                  'title': p.title,
                  'completed': p.completed,
                  'suggestedTime': p.suggestedTime,
                  'duration': p.duration,
                  'description': p.description,
                  'dailyPracticeTime': p.dailyPracticeTime,
                  'link': p.link,
                })
            .toList(),
      };

  Future<void> _syncBleSilently() async {
    final payload = data;
    if (payload == null) return;
    await SmartGuitarBle.instance.syncTasks(_blePayload(payload));
  }

  Future<void> _bleSync() async {
    setState(() => bleBusy = true);
    try {
      final ble = SmartGuitarBle.instance;
      if (!ble.connected) {
        final found = await ble.scan();
        if (found.isEmpty) {
          throw Exception('Smart Guitar not found. Turn on Bluetooth on the guitar.');
        }
        await ble.connect(found.first.device);
      }
      if (data != null) await ble.syncTasks(_blePayload(data!));
      if (mounted) _msg('Smart Guitar synced');
    } catch (e) {
      if (mounted) _msg('Bluetooth sync failed: $e');
    } finally {
      if (mounted) setState(() => bleBusy = false);
    }
  }

  Future<void> _pullProgressFromGuitar() async {
    try {
      final progress = await SmartGuitarBle.instance.getProgress();
      final items = (progress['practices'] as List?) ?? const [];
      for (final raw in items) {
        if (raw is! Map) continue;
        final id = raw['id']?.toString();
        if (id == null || id.isEmpty) continue;
        final seconds = (raw['practicedSeconds'] as num?)?.toInt() ?? 0;
        final today = (raw['todayPracticeSeconds'] as num?)?.toInt();
        final update = <String, dynamic>{'practicedSeconds': seconds};
        if (today != null) update['dailyPracticeSeconds'] = today;
        await api.update(id, update);
      }
      await _load();
    } catch (e) {
      if (mounted) _msg('Could not read Smart Guitar progress: $e');
    }
  }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    try {
      final d = await api.list();
      if (mounted) setState(() => data = d);
    } catch (e) {
      if (mounted) _msg('Load failed: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _openLink(String link) async {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      _msg('Invalid practice link');
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) _msg('Could not open practice link');
  }

  Future<void> _edit([GuitarPractice? p]) async {
    final v = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: card,
      builder: (_) => _Editor(item: p),
    );
    if (v == null) return;
    try {
      if (p == null) {
        await api.create(v);
      } else {
        await api.update(p.id, v);
      }
      await _load();
      if (SmartGuitarBle.instance.connected) await _syncBleSilently();
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
      if (SmartGuitarBle.instance.connected) await _syncBleSilently();
    } catch (e) {
      if (mounted) _msg('Delete failed: $e');
    }
  }

  Future<void> _toggle(GuitarPractice p) async {
    try {
      await api.update(p.id, {'completed': !p.completed});
      await _load();
      if (SmartGuitarBle.instance.connected) await _syncBleSilently();
    } catch (e) {
      if (mounted) _msg('Update failed: $e');
    }
  }

  void _msg(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  int get _todayMinutes {
    final ps = data?.practices ?? const <GuitarPractice>[];
    final seconds = ps.fold<int>(0, (sum, p) => sum + p.dailyPracticeSeconds);
    return seconds > 0 ? (seconds / 60).floor() : 0;
  }

  int get _streak {
    final dates = <DateTime>{};
    for (final p in data?.practices ?? const <GuitarPractice>[]) {
      if (p.dailyPracticeSeconds <= 0 || p.practiceDate.isEmpty) continue;
      final d = DateTime.tryParse(p.practiceDate);
      if (d != null) dates.add(DateTime(d.year, d.month, d.day));
    }
    if (dates.isEmpty) return 0;
    var cursor = DateTime.now();
    cursor = DateTime(cursor.year, cursor.month, cursor.day);
    var count = 0;
    while (dates.contains(cursor)) {
      count++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return count;
  }

  @override
  Widget build(BuildContext context) {
    final all = data?.practices ?? const <GuitarPractice>[];
    final active = all.where((p) => !p.completed).toList();
    final completed = all.where((p) => p.completed).toList();
    final target = data?.dailyPracticeTime ?? 0;
    final today = _todayMinutes;
    final progress = target <= 0 ? 0.0 : (today / target).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 20,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Guitar Practice', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            SizedBox(height: 3),
            Text('Your daily practice plan', style: TextStyle(fontSize: 13, color: muted)),
          ],
        ),
        actions: [
          IconButton(
            onPressed: bleBusy ? null : _bleSync,
            tooltip: 'Sync with Smart Guitar',
            icon: Icon(
              bleConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
              color: bleConnected ? green : Colors.white54,
            ),
          ),
          IconButton(
            onPressed: loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(),
        child: const Icon(Icons.add),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                children: [
                  _dashboard(today, target, progress),
                  const SizedBox(height: 22),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text("Today's Practice", style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                      Text('${active.length} sessions', style: const TextStyle(color: muted, fontSize: 14)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (active.isEmpty)
                    _emptyToday()
                  else
                    ...active.map(_card),
                  if (completed.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _completedHeader(completed.length),
                    if (completedExpanded) ...[
                      const SizedBox(height: 8),
                      ...completed.map(_card),
                    ],
                  ],
                ],
              ),
            ),
    );
  }

  Widget _dashboard(int today, int target, double progress) => Column(
        children: [
          Row(
            children: [
              Expanded(
                flex: 5,
                child: _statCard(
                  child: Row(
                    children: [
                      SizedBox(
                        width: 100,
                        height: 100,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CircularProgressIndicator(
                              value: progress,
                              strokeWidth: 10,
                              backgroundColor: const Color(0xFF20353D),
                              valueColor: const AlwaysStoppedAnimation<Color>(green),
                            ),
                            Text('$today min', style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("Today's Practice", style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 5),
                            Text('$today min', style: const TextStyle(color: Colors.white, fontSize: 27, fontWeight: FontWeight.w800)),
                            Text('of $target min', style: const TextStyle(color: muted, fontSize: 14)),
                            const SizedBox(height: 10),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 8,
                                backgroundColor: const Color(0xFF20353D),
                                valueColor: const AlwaysStoppedAnimation<Color>(green),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: _statCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.local_fire_department_rounded, color: green, size: 28),
                      const SizedBox(height: 10),
                      const Text('Streak', style: TextStyle(color: muted, fontSize: 14)),
                      const SizedBox(height: 3),
                      Text('$_streak days', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 5),
                      Text(_streak > 0 ? 'Keep going!' : 'Start today', style: const TextStyle(color: muted, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF0B2420),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: green.withValues(alpha: .20)),
            ),
            child: Row(
              children: [
                Icon(bleConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled, color: bleConnected ? green : Colors.white38),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Smart Guitar', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                      Text(bleConnected ? 'ESP32 · Connected' : 'ESP32 · Not connected', style: const TextStyle(color: muted, fontSize: 12)),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: bleBusy ? null : _bleSync,
                  icon: bleBusy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync_rounded, size: 18),
                  label: Text(bleBusy ? 'Syncing' : 'Sync Now'),
                ),
              ],
            ),
          ),
        ],
      );

  Widget _statCard({required Widget child}) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF15343D)),
        ),
        child: child,
      );

  Widget _emptyToday() => Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(20)),
        child: const Column(
          children: [
            Icon(Icons.music_note_rounded, color: muted, size: 34),
            SizedBox(height: 8),
            Text('No active sessions today', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ],
        ),
      );

  Widget _completedHeader(int count) => InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => setState(() => completedExpanded = !completedExpanded),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(18)),
          child: Row(
            children: [
              const Icon(Icons.check_circle_outline_rounded, color: Colors.white70),
              const SizedBox(width: 12),
              Expanded(child: Text('Completed ($count)', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16))),
              Icon(completedExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: Colors.white70),
            ],
          ),
        ),
      );

  Widget _card(GuitarPractice p) => Card(
        color: card,
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFF15343D))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 15, 8, 14),
          child: Row(
            children: [
              IconButton(
                onPressed: () => _toggle(p),
                icon: Icon(p.completed ? Icons.check_circle : Icons.radio_button_unchecked, color: p.completed ? green : Colors.white54, size: 31),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: InkWell(
                  onTap: () => _edit(p),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 5),
                      Text('${p.suggestedTime}  ·  ${p.duration} min', style: const TextStyle(color: muted, fontSize: 13)),
                      if (p.description.trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(p.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: muted, fontSize: 13)),
                      ],
                      if (p.link.trim().isNotEmpty) ...[
                        const SizedBox(height: 7),
                        InkWell(
                          onTap: () => _openLink(p.link),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.link_rounded, size: 17, color: green),
                              SizedBox(width: 5),
                              Text('Open practice video', style: TextStyle(color: green, fontWeight: FontWeight.w700, fontSize: 13)),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              IconButton(
                onPressed: p.completed ? null : () {},
                icon: const Icon(Icons.play_circle_fill_rounded, color: green, size: 43),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'edit') _edit(p); else _delete(p);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      );
}

class _Editor extends StatefulWidget {
  const _Editor({this.item});
  final GuitarPractice? item;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final t = TextEditingController(text: widget.item?.title ?? '');
  late final s = TextEditingController(text: widget.item?.suggestedTime ?? '');
  late final d = TextEditingController(text: widget.item?.duration.toString() ?? '');
  late final x = TextEditingController(text: widget.item?.description ?? '');
  late final l = TextEditingController(text: widget.item?.link ?? '');

  @override
  void dispose() {
    t.dispose();
    s.dispose();
    d.dispose();
    x.dispose();
    l.dispose();
    super.dispose();
  }

  InputDecoration dec(String label, IconData icon) => InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        filled: true,
        fillColor: const Color(0xFF142B35),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      );

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 18, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
        child: SingleChildScrollView(
          child: Column(
            children: [
              Text(widget.item == null ? 'Add practice' : 'Edit practice', style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
              TextField(controller: t, decoration: dec('Title', Icons.music_note), style: const TextStyle(color: Colors.white)),
              TextField(controller: s, decoration: dec('Suggested time (HH:mm)', Icons.schedule), style: const TextStyle(color: Colors.white)),
              TextField(controller: d, keyboardType: TextInputType.number, decoration: dec('Duration (minutes)', Icons.timer), style: const TextStyle(color: Colors.white)),
              TextField(controller: x, maxLines: 4, decoration: dec('Description', Icons.notes), style: const TextStyle(color: Colors.white)),
              TextField(controller: l, keyboardType: TextInputType.url, decoration: dec('Practice link', Icons.link_rounded), style: const TextStyle(color: Colors.white)),
              FilledButton(
                onPressed: () {
                  final n = int.tryParse(d.text);
                  if (t.text.trim().isEmpty || n == null || n <= 0) return;
                  Navigator.pop(context, {
                    'title': t.text.trim(),
                    'suggestedTime': s.text.trim(),
                    'duration': n,
                    'description': x.text.trim(),
                    'link': l.text.trim(),
                    'completed': widget.item?.completed ?? false,
                  });
                },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      );
}
