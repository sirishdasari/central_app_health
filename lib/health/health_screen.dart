import 'package:flutter/material.dart';
import '../appwrite_health_service.dart';
import 'health_service.dart';
import '../auth_service.dart';

class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key, this.onLoggedOut});
  final VoidCallback? onLoggedOut;
  @override State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  final health = HealthService();
  final appwrite = AppwriteHealthService();
  HealthSummary? summary;
  bool loading = true;
  bool syncing = false;
  String? error;

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      if (!await health.ensurePermissions()) {
        throw Exception('Health Connect read permission was not granted.');
      }
      final result = await health.readToday();
      if (!mounted) return;
      setState(() { summary = result; loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { error = e.toString().replaceFirst('Exception: ', ''); loading = false; });
    }
  }

  Future<void> _sync() async {
    final s = summary;
    if (s == null) return;
    setState(() => syncing = true);
    try {
      await appwrite.upsertDailyHealth(s);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Health data synced to MyDaily')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sync failed: ' + e.toString())));
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  @override Widget build(BuildContext context) {
    final s = summary;
    final steps = s?.steps ?? 0;
    final progress = (steps / 10000).clamp(0.0, 1.0);
    return Scaffold(
      backgroundColor: const Color(0xFF06131A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text('Health', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [IconButton(icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SyncSettingsScreen(onLoggedOut: widget.onLoggedOut))))],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(20,4,20,32), children: [
          _status(),
          const SizedBox(height: 18),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('Today', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
            Text(_date(), style: const TextStyle(color: Colors.white54)),
          ]),
          const SizedBox(height: 12),
          if (loading) const SizedBox(height: 420, child: Center(child: CircularProgressIndicator()))
          else if (error != null) _error()
          else ...[
            _steps(steps, progress),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _metric(Icons.favorite_rounded, 'Heart rate', s?.heartRateAvg == null ? '--' : s!.heartRateAvg!.round().toString() + ' bpm')),
              const SizedBox(width: 12),
              Expanded(child: _metric(Icons.local_fire_department_rounded, 'Active calories', s?.activeCalories == null ? '--' : s!.activeCalories!.round().toString() + ' kcal')),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _metric(Icons.nightlight_round, 'Sleep', _sleep(s?.sleepMinutes ?? 0))),
              const SizedBox(width: 12),
              Expanded(child: _metric(Icons.water_drop_rounded, 'Blood oxygen', s?.bloodOxygenAvg == null ? '--' : s!.bloodOxygenAvg!.round().toString() + '%')),
            ]),
            const SizedBox(height: 18),
            FilledButton.icon(onPressed: syncing ? null : _sync, icon: syncing ? const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)) : const Icon(Icons.sync_rounded), label: Text(syncing ? 'Syncing…' : 'Sync to MyDaily')),
            const SizedBox(height: 10),
            OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ActivityDetailsScreen(summary: s!))), icon: const Icon(Icons.insights_rounded), label: const Text('View activity details')),
          ],
        ]),
      ),
    );
  }

  Widget _status() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: const Color(0xFF102820), borderRadius: BorderRadius.circular(18)),
    child: const Row(children: [
      CircleAvatar(radius:23, backgroundColor:Color(0xFF45E88F), child:Icon(Icons.check_rounded,color:Color(0xFF062015))),
      SizedBox(width:14),
      Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('Health Connect linked',style:TextStyle(color:Colors.white,fontWeight:FontWeight.w700)),
        SizedBox(height:4),
        Text('Read and background access are requested when available.',style:TextStyle(color:Colors.white70,fontSize:12)),
      ])),
    ]),
  );

  Widget _steps(int value,double progress)=>Container(
    padding:const EdgeInsets.all(20),
    decoration:BoxDecoration(color:const Color(0xFF0D202A),borderRadius:BorderRadius.circular(22)),
    child:Column(children:[
      const Align(alignment:Alignment.centerLeft,child:Text('Activity',style:TextStyle(color:Colors.white70))),
      const SizedBox(height:12),
      SizedBox(width:190,height:190,child:Stack(alignment:Alignment.center,children:[
        CircularProgressIndicator(value:progress,strokeWidth:14,backgroundColor:const Color(0xFF21363F),color:const Color(0xFF45E88F)),
        Column(mainAxisSize:MainAxisSize.min,children:[
          const Icon(Icons.directions_walk_rounded,color:Color(0xFF45E88F),size:30),
          const SizedBox(height:5),
          Text(value.toString(),style:const TextStyle(color:Colors.white,fontSize:34,fontWeight:FontWeight.w800)),
          const Text('steps',style:TextStyle(color:Colors.white70)),
          const Text('of 10,000',style:TextStyle(color:Colors.white38,fontSize:12)),
        ]),
      ])),
      const SizedBox(height:12),
      Text((progress*100).round().toString() + '% of your daily goal',style:const TextStyle(color:Colors.white70)),
    ]),
  );

  Widget _metric(IconData icon,String title,String value)=>Container(
    height:118,padding:const EdgeInsets.all(14),
    decoration:BoxDecoration(color:const Color(0xFF0D202A),borderRadius:BorderRadius.circular(18)),
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Icon(icon,color:const Color(0xFF45E88F),size:23),const Spacer(),
      Text(value,style:const TextStyle(color:Colors.white,fontSize:20,fontWeight:FontWeight.w700)),
      Text(title,style:const TextStyle(color:Colors.white54,fontSize:12)),
    ]),
  );

  Widget _error()=>Container(
    padding:const EdgeInsets.all(18),
    decoration:BoxDecoration(color:const Color(0xFF2A171A),borderRadius:BorderRadius.circular(18)),
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(error!,style:const TextStyle(color:Colors.white)),const SizedBox(height:12),
      FilledButton(onPressed:_load,child:const Text('Grant access')),
    ]),
  );

  String _sleep(int m)=>m<=0?'--':(m~/60).toString()+'h '+(m%60).toString()+'m';
  String _date(){final n=DateTime.now();return n.day.toString()+'/'+n.month.toString()+'/'+n.year.toString();}
}

class ActivityDetailsScreen extends StatelessWidget {
  const ActivityDetailsScreen({super.key,required this.summary});
  final HealthSummary summary;

  @override Widget build(BuildContext context)=>Scaffold(
    backgroundColor:const Color(0xFF06131A),
    appBar:AppBar(title:const Text('Activity'),backgroundColor:Colors.transparent,foregroundColor:Colors.white),
    body:ListView(padding:const EdgeInsets.all(20),children:[
      _item('Steps',summary.steps.toString(),Icons.directions_walk_rounded),
      _item('Heart rate average',summary.heartRateAvg==null?'--':summary.heartRateAvg!.round().toString()+' bpm',Icons.favorite_rounded),
      _item('Active calories',summary.activeCalories==null?'--':summary.activeCalories!.round().toString()+' kcal',Icons.local_fire_department_rounded),
      _item('Sleep',(summary.sleepMinutes~/60).toString()+'h '+(summary.sleepMinutes%60).toString()+'m',Icons.nightlight_round),
      _item('Blood oxygen',summary.bloodOxygenAvg==null?'--':summary.bloodOxygenAvg!.round().toString()+'%',Icons.water_drop_rounded),
    ]),
  );

  Widget _item(String title,String value,IconData icon)=>Container(
    margin:const EdgeInsets.only(bottom:12),padding:const EdgeInsets.all(18),
    decoration:BoxDecoration(color:const Color(0xFF0D202A),borderRadius:BorderRadius.circular(18)),
    child:Row(children:[Icon(icon,color:const Color(0xFF45E88F)),const SizedBox(width:14),Expanded(child:Text(title,style:const TextStyle(color:Colors.white70))),Text(value,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w700))]),
  );
}

class SyncSettingsScreen extends StatefulWidget {
  const SyncSettingsScreen({super.key, this.onLoggedOut});
  final VoidCallback? onLoggedOut;

  @override
  State<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends State<SyncSettingsScreen> {
  final health = HealthService();
  final auth = AppwriteAuthService();
  bool history = false;
  bool background = false;
  bool busyHistory = false;
  bool busyBackground = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final h = await health.isHistoryAuthorized();
      final b = await health.isBackgroundAuthorized();
      if (mounted) setState(() { history = h; background = b; });
    } catch (_) {}
  }

  Future<void> _historyAccess() async {
    setState(() => busyHistory = true);
    try {
      final granted = await health.requestHistoryAccess();
      if (mounted) setState(() => history = granted);
      if (mounted) _message(granted ? 'Historical health access enabled.' : 'Historical access was not granted.');
    } catch (e) {
      if (mounted) _message('Could not configure historical access: $e');
    } finally {
      if (mounted) setState(() => busyHistory = false);
    }
  }

  Future<void> _backgroundAccess() async {
    setState(() => busyBackground = true);
    try {
      final granted = await health.requestBackgroundAccess();
      if (mounted) setState(() => background = granted);
      if (mounted) _message(granted ? 'Background health read enabled.' : 'Background read was not granted.');
    } catch (e) {
      if (mounted) _message('Could not configure background access: $e');
    } finally {
      if (mounted) setState(() => busyBackground = false);
    }
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('Health Connect permissions will remain on this device, but MyDaily sync will stop until you sign in again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Log out')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await auth.logout();
      if (!mounted) return;
      Navigator.pop(context);
      widget.onLoggedOut?.call();
    } catch (e) {
      if (mounted) _message('Logout failed: $e');
    }
  }

  void _message(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF06131A),
    appBar: AppBar(
      title: const Text('Settings'),
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(color: const Color(0xFF102820), borderRadius: BorderRadius.circular(18)),
          child: const Row(children: [
            Icon(Icons.cloud_done_rounded, color: Color(0xFF45E88F), size: 30),
            SizedBox(width: 14),
            Expanded(child: Text('MyDaily Health syncs your Samsung Health data through Health Connect.', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
          ]),
        ),
        const SizedBox(height: 22),
        const Text('Health access', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        _permissionTile(
          'Read health data',
          'Steps, heart rate, sleep, calories and blood oxygen',
          Icons.favorite_outline,
          true,
          null,
        ),
        _permissionTile(
          'Historical health data',
          'Allow MyDaily to read health records older than the default 30-day window.',
          Icons.history_rounded,
          history,
          busyHistory ? null : _historyAccess,
        ),
        _permissionTile(
          'Background read',
          'Allow automatic health sync while MyDaily is not open.',
          Icons.sync_rounded,
          background,
          busyBackground ? null : _backgroundAccess,
        ),
        const SizedBox(height: 22),
        const Text('Sync', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        _infoRow('Sync frequency', 'About once per hour'),
        _infoRow('Appwrite updates', 'Only when health values change'),
        _infoRow('Source', 'Samsung Health via Health Connect'),
        const SizedBox(height: 22),
        const Text('Privacy', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        const Text('Only the daily health summary is sent to Appwrite. Raw Health Connect records remain on your device.', style: TextStyle(color: Colors.white60, height: 1.5)),
        const SizedBox(height: 30),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, side: const BorderSide(color: Colors.redAccent)),
          onPressed: _logout,
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Log out'),
        ),
      ],
    ),
  );

  Widget _permissionTile(String title, String subtitle, IconData icon, bool enabled, VoidCallback? onPressed) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(color: const Color(0xFF0D202A), borderRadius: BorderRadius.circular(16)),
    child: Row(children: [
      Icon(icon, color: enabled ? const Color(0xFF45E88F) : Colors.white54),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        const SizedBox(height: 3),
        Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ])),
      if (onPressed != null)
        TextButton(onPressed: onPressed, child: Text(enabled ? 'Manage' : 'Enable'))
      else
        Icon(enabled ? Icons.check_circle_rounded : Icons.hourglass_top_rounded, color: enabled ? const Color(0xFF45E88F) : Colors.white38, size: 22),
    ]),
  );

  Widget _infoRow(String title, String value) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(color: const Color(0xFF0D202A), borderRadius: BorderRadius.circular(16)),
    child: Row(children: [
      Expanded(child: Text(title, style: const TextStyle(color: Colors.white70))),
      Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
    ]),
  );
}
