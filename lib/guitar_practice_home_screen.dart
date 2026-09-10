import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'guitar_practice_api.dart';
import 'guitar_practice_session_screen.dart';
import 'smart_guitar_ble.dart';

class GuitarPracticeHomeScreen extends StatefulWidget {
  const GuitarPracticeHomeScreen({super.key});

  @override
  State<GuitarPracticeHomeScreen> createState() =>
      _GuitarPracticeHomeScreenState();
}

class _GuitarPracticeHomeScreenState extends State<GuitarPracticeHomeScreen> {
  final GuitarPracticeApi api = GuitarPracticeApi();

  GuitarPracticeResponse? data;
  bool loading = true;
  bool syncing = false;
  bool connected = false;
  bool completedOpen = false;
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
    bleSub = SmartGuitarBle.instance.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => connected = status == 'connected');
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
      final result = await api.list();
      if (mounted) setState(() => data = result);
    } catch (e) {
      if (mounted) _msg('Load failed: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Map<String, dynamic> _payload() {
    final current = data;
    return {
      'date': current?.date,
      'dailyPracticeTime': current?.dailyPracticeTime,
      'practices': (current?.practices ?? const <GuitarPractice>[])
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
  }

  Future<void> _sync() async {
    if (syncing) return;
    if (mounted) setState(() => syncing = true);

    try {
      final ble = SmartGuitarBle.instance;
      if (!ble.connected) {
        final found = await ble.scan();
        if (found.isEmpty) {
          throw Exception(
            'Smart Guitar not found. Turn on Bluetooth on the guitar.',
          );
        }
        await ble.connect(found.first.device);
      }
      if (data != null) {
        await ble.syncTasks(_payload());
      }
      if (mounted) _msg('Smart Guitar synced');
    } catch (e) {
      if (mounted) _msg('Bluetooth sync failed: $e');
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  Future<void> _start(GuitarPractice practice) async {
    final result = await Navigator.push<int>(
      context,
      MaterialPageRoute(
        builder: (_) => GuitarPracticeSessionScreen(practice: practice),
      ),
    );
    if (result != null && mounted) await _load();
  }

  Future<void> _openLink(String value) async {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      _msg('Invalid practice link');
      return;
    }
    final opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) _msg('Could not open practice link');
  }

  Future<void> _toggle(GuitarPractice practice) async {
    try {
      await api.update(
        practice.id,
        {'completed': !practice.completed},
      );
      await _load();
    } catch (e) {
      if (mounted) _msg('Update failed: $e');
    }
  }

  Future<void> _edit([GuitarPractice? practice]) async {
    final value = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: card,
      builder: (_) => _Editor(item: practice),
    );
    if (value == null) return;

    try {
      if (practice == null) {
        await api.create(value);
      } else {
        await api.update(practice.id, value);
      }
      await _load();
      if (connected && mounted) await _sync();
    } catch (e) {
      if (mounted) _msg('Save failed: $e');
    }
  }

  Future<void> _delete(GuitarPractice practice) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete practice?'),
        content: Text(practice.title),
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
      await api.delete(practice.id);
      await _load();
      if (connected && mounted) await _sync();
    } catch (e) {
      if (mounted) _msg('Delete failed: $e');
    }
  }

  // The Appwrite schema has no practiceDate or elapsed-seconds column.
  // Therefore the only persisted practice amount available to the app is
  // the duration of sessions marked completed.
  int get _completedMinutes =>
      (data?.practices ?? const <GuitarPractice>[])
          .where((p) => p.completed)
          .fold<int>(0, (sum, p) => sum + p.duration);

  int get _completedCount =>
      (data?.practices ?? const <GuitarPractice>[])
          .where((p) => p.completed)
          .length;

  String _time(int minutes) {
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    if (hours > 0) return '${hours}h ${mins}m';
    return '$mins min';
  }

  void _msg(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = data?.practices ?? const <GuitarPractice>[];
    final active = all.where((p) => !p.completed).toList();
    final completed = all.where((p) => p.completed).toList();
    final target = data?.dailyPracticeTime ?? 0;
    final practiced = _completedMinutes;
    final progress = target <= 0
        ? 0.0
        : (practiced / target).clamp(0.0, 1.0).toDouble();

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
            Text(
              'Guitar Practice',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 2),
            Text(
              'Your daily practice plan, synced with Smart Guitar',
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Sync with Smart Guitar',
            onPressed: syncing ? null : _sync,
            icon: Icon(
              connected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              color: connected ? green : Colors.white54,
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
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
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                children: [
                  _dashboard(practiced, target, progress),
                  const SizedBox(height: 22),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Expanded(
                        child: Text(
                          "Today's Practice",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Text(
                        '${active.length} sessions',
                        style: const TextStyle(color: muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (active.isEmpty) _empty() else ...active.map(_card),
                  if (completed.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _completedHeader(completed.length),
                    if (completedOpen) ...[
                      const SizedBox(height: 8),
                      ...completed.map(_card),
                    ],
                  ],
                ],
              ),
            ),
    );
  }

  Widget _dashboard(int practiced, int target, double progress) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 560;

        final practiceBox = _box(
          child: Row(
            children: [
              SizedBox(
                width: narrow ? 82 : 92,
                height: narrow ? 82 : 92,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 9,
                      backgroundColor: const Color(0xFF20353D),
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(green),
                    ),
                    Text(
                      _time(practiced),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Today's Practice",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      _time(practiced),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'of $target min target',
                      style: const TextStyle(color: muted),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 7,
                        backgroundColor: const Color(0xFF20353D),
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(green),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

        final completedBox = _box(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: green,
                size: 28,
              ),
              const SizedBox(height: 8),
              const Text(
                'Completed',
                style: TextStyle(color: muted, fontSize: 13),
              ),
              Text(
                '$_completedCount sessions',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                _time(practiced),
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            ],
          ),
        );

        return Column(
          children: [
            if (narrow)
              Column(
                children: [
                  practiceBox,
                  const SizedBox(height: 10),
                  SizedBox(width: double.infinity, child: completedBox),
                ],
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 5, child: practiceBox),
                  const SizedBox(width: 10),
                  Expanded(flex: 3, child: completedBox),
                ],
              ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 13,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF0B2420),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: green.withAlpha(45)),
              ),
              child: Row(
                children: [
                  Icon(
                    connected
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_disabled,
                    color: connected ? green : Colors.white38,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Smart Guitar',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          connected
                              ? 'ESP32 · Connected'
                              : 'ESP32 · Not connected',
                          style: const TextStyle(
                            color: muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: syncing ? null : _sync,
                    icon: syncing
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.sync_rounded, size: 17),
                    label: Text(syncing ? 'Syncing' : 'Sync Now'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _box({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: child,
    );
  }

  Widget _card(GuitarPractice practice) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            onPressed: () => _toggle(practice),
            icon: Icon(
              practice.completed
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              color: practice.completed ? green : Colors.white54,
              size: 28,
            ),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  practice.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${practice.suggestedTime}  ·  ${practice.duration} min',
                  style: const TextStyle(color: muted),
                ),
                if (practice.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    practice.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: muted, fontSize: 13),
                  ),
                ],
                if (practice.link.trim().isNotEmpty)
                  TextButton.icon(
                    onPressed: () => _openLink(practice.link),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(
                      Icons.link_rounded,
                      color: purple,
                      size: 16,
                    ),
                    label: const Text(
                      'Open practice video',
                      style: TextStyle(
                        color: purple,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Column(
            children: [
              if (!practice.completed)
                IconButton(
                  tooltip: 'Start practice',
                  onPressed: () => _start(practice),
                  style: IconButton.styleFrom(
                    backgroundColor: green,
                    foregroundColor: bg,
                  ),
                  icon: const Icon(
                    Icons.play_arrow_rounded,
                    size: 28,
                  ),
                ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') _edit(practice);
                  if (value == 'delete') _delete(practice);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text('Edit'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _completedHeader(int count) {
    return InkWell(
      onTap: () => setState(() => completedOpen = !completedOpen),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        decoration: BoxDecoration(
          color: card,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.check_circle_outline_rounded,
              color: Colors.white70,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Completed ($count)',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ),
            Icon(
              completedOpen
                  ? Icons.keyboard_arrow_up
                  : Icons.keyboard_arrow_down,
              color: Colors.white70,
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty() {
    return _box(
      child: const Column(
        children: [
          Icon(Icons.music_note_rounded, color: muted, size: 34),
          SizedBox(height: 8),
          Text(
            'No active sessions today',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _Editor extends StatefulWidget {
  const _Editor({this.item});

  final GuitarPractice? item;

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final TextEditingController title =
      TextEditingController(text: widget.item?.title ?? '');
  late final TextEditingController time =
      TextEditingController(text: widget.item?.suggestedTime ?? '');
  late final TextEditingController duration = TextEditingController(
    text: widget.item?.duration.toString() ?? '',
  );
  late final TextEditingController dailyPracticeTime =
      TextEditingController(
    text: widget.item?.dailyPracticeTime.toString() ?? '95',
  );
  late final TextEditingController description =
      TextEditingController(text: widget.item?.description ?? '');
  late final TextEditingController link =
      TextEditingController(text: widget.item?.link ?? '');

  @override
  void dispose() {
    title.dispose();
    time.dispose();
    duration.dispose();
    dailyPracticeTime.dispose();
    description.dispose();
    link.dispose();
    super.dispose();
  }

  InputDecoration _dec(String label, IconData icon) => InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        filled: true,
        fillColor: const Color(0xFF142B35),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      );

  void _save() {
    final titleValue = title.text.trim();
    final durationValue = int.tryParse(duration.text.trim());
    final dailyValue = int.tryParse(dailyPracticeTime.text.trim());

    if (titleValue.isEmpty) {
      _msg('Enter a practice title');
      return;
    }
    if (durationValue == null || durationValue <= 0) {
      _msg('Enter a valid duration in minutes');
      return;
    }
    if (dailyValue == null || dailyValue < 0) {
      _msg('Enter a valid daily practice time');
      return;
    }

    Navigator.pop(context, {
      'title': titleValue,
      'suggestedTime': time.text.trim(),
      'duration': durationValue,
      'description': description.text.trim(),
      'dailyPracticeTime': dailyValue,
      'link': link.text.trim(),
      'completed': widget.item?.completed ?? false,
    });
  }

  void _msg(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 18, 20, bottom + 20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.item == null ? 'Add practice' : 'Edit practice',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: title,
                decoration: _dec('Session name', Icons.music_note),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: time,
                decoration: _dec(
                  'Suggested time (HH:mm)',
                  Icons.schedule,
                ),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: duration,
                keyboardType: TextInputType.number,
                decoration: _dec(
                  'Duration (minutes)',
                  Icons.timer,
                ),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: dailyPracticeTime,
                keyboardType: TextInputType.number,
                decoration: _dec(
                  'Daily practice time (minutes)',
                  Icons.flag_rounded,
                ),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: description,
                maxLines: 4,
                decoration: _dec('Description', Icons.notes),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: link,
                keyboardType: TextInputType.url,
                decoration: _dec('Practice video URL', Icons.link_rounded),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _save,
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
