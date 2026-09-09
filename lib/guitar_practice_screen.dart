import 'dart:async';
import 'package:flutter/material.dart';
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
  StreamSubscription<String>? _bleSub;

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

  Future<void> _syncBleSilently() async {
    final payload = data;
    if (payload == null) return;
    await SmartGuitarBle.instance.syncTasks({
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
              })
          .toList(),
    });
  }

  Future<void> _pullProgressFromGuitar() async {
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
  }

  Future<void> _bleSync() async {
    setState(() => bleBusy = true);
    try {
      final ble = SmartGuitarBle.instance;
      if (!ble.connected) {
        final found = await ble.scan();
        if (found.isEmpty) {
          throw Exception(
              'Smart Guitar not found. Turn on Bluetooth on the guitar.');
        }
        await ble.connect(found.first.device);
      }

      final payload = data;
      if (payload != null) {
        await ble.syncTasks({
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
                  })
              .toList(),
        });
      }

      if (mounted) _msg('Smart Guitar synced');
    } catch (e) {
      if (mounted) _msg('Bluetooth sync failed: $e');
    } finally {
      if (mounted) setState(() => bleBusy = false);
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

  Future<void> _edit([GuitarPractice? p]) async {
    final v = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0D202A),
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
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
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

  void _msg(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  @override
  Widget build(BuildContext c) {
    final ps = data?.practices ?? const <GuitarPractice>[];

    return Scaffold(
      backgroundColor: const Color(0xFF06131A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text('Guitar Practice'),
        actions: [
          IconButton(
            onPressed: bleBusy ? null : _bleSync,
            tooltip: 'Smart Guitar sync',
            icon: Icon(
              bleConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              color: bleConnected
                  ? const Color(0xFF45E88F)
                  : Colors.white54,
            ),
          ),
          IconButton(
            onPressed: loading ? null : _load,
            icon: const Icon(Icons.sync_rounded),
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
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 90),
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFF102820),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${data?.dailyPracticeTime ?? 0} min planned',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  ...ps.map(_card),
                ],
              ),
            ),
    );
  }

  Widget _card(GuitarPractice p) => Card(
        color: const Color(0xFF0D202A),
        child: ListTile(
          onTap: () => _edit(p),
          leading: IconButton(
            onPressed: () => _toggle(p),
            icon: Icon(
              p.completed
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              color: p.completed
                  ? const Color(0xFF45E88F)
                  : Colors.white38,
            ),
          ),
          title: Text(
            p.title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            '${p.suggestedTime} · ${p.duration} min\n${p.description}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54),
          ),
          trailing: PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'edit') {
                _edit(p);
              } else {
                _delete(p);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
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
  late final s =
      TextEditingController(text: widget.item?.suggestedTime ?? '');
  late final d =
      TextEditingController(text: widget.item?.duration.toString() ?? '');
  late final x =
      TextEditingController(text: widget.item?.description ?? '');

  @override
  void dispose() {
    t.dispose();
    s.dispose();
    d.dispose();
    x.dispose();
    super.dispose();
  }

  InputDecoration dec(String l, IconData i) => InputDecoration(
        labelText: l,
        prefixIcon: Icon(i),
        filled: true,
        fillColor: const Color(0xFF142B35),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      );

  @override
  Widget build(BuildContext c) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          18,
          20,
          MediaQuery.viewInsetsOf(c).bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            children: [
              Text(
                widget.item == null ? 'Add practice' : 'Edit practice',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                ),
              ),
              TextField(
                controller: t,
                decoration: dec('Title', Icons.music_note),
                style: const TextStyle(color: Colors.white),
              ),
              TextField(
                controller: s,
                decoration: dec('Suggested time (HH:mm)', Icons.schedule),
                style: const TextStyle(color: Colors.white),
              ),
              TextField(
                controller: d,
                keyboardType: TextInputType.number,
                decoration: dec('Duration (minutes)', Icons.timer),
                style: const TextStyle(color: Colors.white),
              ),
              TextField(
                controller: x,
                maxLines: 4,
                decoration: dec('Description', Icons.notes),
                style: const TextStyle(color: Colors.white),
              ),
              FilledButton(
                onPressed: () {
                  final n = int.tryParse(d.text);
                  if (t.text.trim().isEmpty || n == null || n <= 0) return;
                  Navigator.pop(c, {
                    'title': t.text.trim(),
                    'suggestedTime': s.text.trim(),
                    'duration': n,
                    'description': x.text.trim(),
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
