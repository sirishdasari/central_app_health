import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';

class GuitarTunerSheet extends StatefulWidget {
  const GuitarTunerSheet({super.key,this.embedded=false,this.onClose});
  final bool embedded; final VoidCallback? onClose;
  @override State<GuitarTunerSheet> createState()=>_TunerState();
}
class GuitarTunerScreen extends StatelessWidget {
  const GuitarTunerScreen({super.key});
  @override Widget build(BuildContext c)=>const Scaffold(
    backgroundColor:Color(0xFF06151D),
    body:SafeArea(child:GuitarTunerSheet(embedded:true)));
}
class _N {const _N(this.n,this.f,this.no);final String n;final double f;final int no;}
const _ns=[_N('E',82.41,6),_N('A',110,5),_N('D',146.83,4),_N('G',196,3),_N('B',246.94,2),_N('E',329.63,1)];

class _TunerState extends State<GuitarTunerSheet> with SingleTickerProviderStateMixin {
  final _r=AudioRecorder(),_p=AudioPlayer(); StreamSubscription<Uint8List>? _sub;
  late final AnimationController _a; final Set<int> _done={};
  DateTime _lastNoteSwitch=DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPitchProcess=DateTime.fromMillisecondsSinceEpoch(0);
  bool _processing=false;
  int _candidate=-1, _candidateHits=0;
  bool listen=false,has=false,ok=false,lastOk=false,busy=false; int selected=5,detected=5;
  double hz=0,cents=0,level=0;
  @override void initState(){
    super.initState();
    _a=AnimationController(vsync:this,duration:const Duration(milliseconds:900))..repeat();
    WidgetsBinding.instance.addPostFrameCallback((_)=>_start());
  }
  @override void dispose(){_stop();_a.dispose();_p.dispose();_r.dispose();super.dispose();}
  Future<void> _toggle() async=>listen?_stop():_start();
  Future<void> _start() async{
    if(!await _r.hasPermission()||!mounted)return;
    try{
      final s=await _r.startStream(const RecordConfig(encoder:AudioEncoder.pcm16bits,sampleRate:44100,numChannels:1,autoGain:false,echoCancel:false,noiseSuppress:false));
      _sub=s.listen(_pcm,onError:(_){if(mounted)setState(()=>listen=false);}); if(mounted)setState(()=>listen=true);
    }catch(_){}
  }
  Future<void> _stop() async{
    await _sub?.cancel();_sub=null;_samples.clear();try{await _r.stop();}catch(_){}
    if(mounted)setState(()=>{listen=false,has=false,ok=false,hz=0,cents=0,level=0,lastOk=false});
  }
  void _pcm(Uint8List bytes){
    for(var i=0;i+1<bytes.length;i+=2){
      final v=bytes[i]|(bytes[i+1]<<8);
      _samples.add(v>32767?v-65536:v);
    }

    // AudioRecord can deliver packets much faster than the pitch algorithm
    // can process them. The old speedometer tuner effectively behaved like
    // this: analyze a stable window, then update the UI. Throttle the work
    // so the UI/audio stream cannot be starved by overlapping autocorrelation.
    const n=4096;
    if(_samples.length<n||_processing)return;
    final now=DateTime.now();
    if(now.difference(_lastPitchProcess).inMilliseconds<90)return;
    _lastPitchProcess=now;

    if(_samples.length>n*2)_samples.removeRange(0,_samples.length-n);
    final snapshot=List<int>.from(_samples);
    _processing=true;

    try{
      final p=_pitch(snapshot);
      if(p==null)return;

      final idx=_near(p.f);
      final target=_ns[idx].f;
      final c=(1200*math.log(p.f/target)/math.ln2).clamp(-50.0,50.0).toDouble();
      final tuned=c.abs()<=5.0&&p.c>=.55;

      // Require two consistent pitch windows before changing the displayed
      // string. This prevents harmonics/noise from locking the tuner onto
      // the wrong string while still making E -> A -> D -> G -> B -> E fast.
      if(idx==_candidate){
        _candidateHits++;
      }else{
        _candidate=idx;
        _candidateHits=1;
      }
      if(_candidateHits<2&&idx!=detected)return;

      if(tuned){
        final wasDone=_done.contains(idx);
        _done.add(idx);
        if(!wasDone){
          unawaited(_chime());
        }
        lastOk=true;
      }else{
        lastOk=false;
      }

      if(mounted)setState((){
        selected=idx;
        detected=idx;
        has=true;
        ok=tuned;
        hz=p.f;
        cents=c;
        level=p.c.clamp(0.0,1.0).toDouble();
      });
    }finally{
      _processing=false;
    }
  }

  final List<int> _samples=<int>[];

  _P? _pitch(List<int> x){
    final n=x.length;
    var mean=0.0;
    for(final v in x)mean+=v;
    mean/=n;

    var energy=0.0;
    for(final v in x){final z=v-mean;energy+=z*z;}
    if(math.sqrt(energy/n)<180)return null;

    final minLag=(44100/500).round();
    final maxLag=math.min((44100/70).round(),n~/2);
    var best=0,bestC=0.0;

    for(var lag=minLag;lag<=maxLag;lag++){
      var dot=0.0,a2=0.0,b2=0.0;
      for(var i=0;i<n-lag;i+=2){
        final aa=x[i]-mean,bb=x[i+lag]-mean;
        dot+=aa*bb;a2+=aa*aa;b2+=bb*bb;
      }
      if(a2>0&&b2>0){
        final cc=dot/math.sqrt(a2*b2);
        if(cc>bestC){bestC=cc;best=lag;}
      }
    }

    // Keep the original working confidence gate.
    if(best==0||bestC<.55)return null;

    var lag=best.toDouble();
    if(best>minLag&&best<maxLag){
      final y1=_corr(x,best-1,mean),y2=_corr(x,best,mean),y3=_corr(x,best+1,mean);
      final d=y1-2*y2+y3;
      if(d.abs()>1e-9)lag+=.5*(y1-y3)/d;
    }
    return _P(44100/lag,bestC);
  }

  double _corr(List<int> x,int lag,double mean){
    var dot=0.0,a2=0.0,b2=0.0;
    for(var i=0;i<x.length-lag;i+=2){
      final aa=x[i]-mean,bb=x[i+lag]-mean;
      dot+=aa*bb;a2+=aa*aa;b2+=bb*bb;
    }
    return a2>0&&b2>0?dot/math.sqrt(a2*b2):0;
  }
  int _near(double f){var bi=0,be=1e9;for(var i=0;i<_ns.length;i++){final e=(1200*math.log(f/_ns[i].f)/math.ln2).abs();if(e<be){be=e;bi=i;}}return bi;}
  void _reset(){
    _done.clear();
    lastOk=false;
    busy=false;
    _samples.clear();
    _processing=false;
    _candidate=-1;
    _candidateHits=0;
    _lastPitchProcess=DateTime.fromMillisecondsSinceEpoch(0);
    selected=5;
    detected=5;
    has=false;
    ok=false;
    hz=0;
    cents=0;
    level=0;
    _lastNoteSwitch=DateTime.now();
    _samples.clear();
    if(mounted)setState((){});
  }
  Future<void> _chime() async{
    // Do not wait for playback on the microphone/pitch callback path.
    // Waiting here can make the tuner appear frozen immediately after a
    // successful note.
    try{
      await _p.stop();
      await _p.play(BytesSource(_wav()),volume:.65);
    }catch(_){}
  }

  Uint8List _wav(){const sr=44100,n=13230;final b=ByteData(44+n*2);void s(int o,String v){for(var i=0;i<v.length;i++)b.setUint8(o+i,v.codeUnitAt(i));}
    s(0,'RIFF');b.setUint32(4,36+n*2,Endian.little);s(8,'WAVE');s(12,'fmt ');b.setUint32(16,16,Endian.little);b.setUint16(20,1,Endian.little);b.setUint16(22,1,Endian.little);
    b.setUint32(24,sr,Endian.little);b.setUint32(28,sr*2,Endian.little);b.setUint16(32,2,Endian.little);b.setUint16(34,16,Endian.little);s(36,'data');b.setUint32(40,n*2,Endian.little);
    for(var i=0;i<n;i++){final t=i/sr,e=math.min(1,t/.015)*math.max(0,math.min(1,(.30-t)/.08));final v=(math.sin(2*math.pi*659.25*t)+.65*math.sin(2*math.pi*987.77*t))*e*.22;b.setInt16(44+i*2,(v*32767).round(),Endian.little);}
    return b.buffer.asUint8List();
  }
  Color get ac=>!has?Colors.white54:ok?const Color(0xFF19F59A):cents.abs()<=20?const Color(0xFFFFC33D):const Color(0xFFFF6E6E);
  @override Widget build(BuildContext c){
    final bg=const Color(0xFF06151D);
    return Material(color:bg,borderRadius:widget.embedded?BorderRadius.zero:const BorderRadius.vertical(top:Radius.circular(30)),clipBehavior:Clip.antiAlias,
      child:SafeArea(child:SingleChildScrollView(padding:const EdgeInsets.fromLTRB(22,12,22,22),child:Column(children:[
        if(!widget.embedded)Container(width:46,height:4,decoration:BoxDecoration(color:Colors.white24,borderRadius:BorderRadius.circular(4))),
        if(!widget.embedded)const SizedBox(height:14),
        Row(children:[const Expanded(child:Text('Guitar Tuner',style:TextStyle(color:Colors.white,fontSize:25,fontWeight:FontWeight.w800))),
          IconButton(
            tooltip:'Reset tuning',
            onPressed:_reset,
            icon:const Icon(Icons.restart_alt_rounded,color:Colors.white70),
          ),
          IconButton(onPressed:_toggle,icon:Icon(listen?Icons.mic_rounded:Icons.mic_off_rounded,color:ac)),
          if(!widget.embedded)IconButton(onPressed:widget.onClose??()=>Navigator.pop(c),icon:const Icon(Icons.close_rounded,color:Colors.white70))]),
        const Align(alignment:Alignment.centerLeft,child:Text('Play a string and tune to the center',style:TextStyle(color:Colors.white54,fontSize:14))),
        const SizedBox(height:12),
        AnimatedContainer(duration:const Duration(milliseconds:180),padding:const EdgeInsets.symmetric(horizontal:18,vertical:9),
          decoration:BoxDecoration(color:ok?const Color(0xFF103B2A):const Color(0xFF10242E),borderRadius:BorderRadius.circular(24),border:Border.all(color:ok?ac:Colors.white10)),
          child:Text(ok?'✓  In Tune!':_ns[detected].n+' string',style:TextStyle(color:ok?ac:Colors.white70,fontWeight:FontWeight.w800))),
        const SizedBox(height:5),
        AnimatedBuilder(animation:_a,builder:(_,__)=>SizedBox(height:180,width:double.infinity,child:CustomPaint(painter:_Wave(has:has,ok:ok,c:cents,p:_a.value)))),
        Text(has?_ns[detected].n:_ns[selected].n,style:TextStyle(color:ac,fontSize:82,height:.88,fontWeight:FontWeight.w900)),
        Text(has?hz.toStringAsFixed(1)+' Hz':'Listening…',style:const TextStyle(color:Colors.white70,fontSize:17,fontWeight:FontWeight.w600)),
        Text(has?(cents>=0?'+':'')+cents.toStringAsFixed(1)+' cents':'Tune until the center is reached',
          style:TextStyle(color:ac,fontSize:18,fontWeight:FontWeight.w800)),
        const SizedBox(height:8),
        SizedBox(height:74,width:double.infinity,child:CustomPaint(painter:_Ruler(c:cents,active:has,ok:ok))),
        const SizedBox(height:15),
        Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:List.generate(6,(i){
          final done=_done.contains(i),sel=i==selected;
          return GestureDetector(onTap:()=>setState(()=>selected=i),child:AnimatedContainer(duration:const Duration(milliseconds:220),width:48,height:64,
            decoration:BoxDecoration(color:done?const Color(0xFF103B2A):const Color(0xFF0C222D),borderRadius:BorderRadius.circular(15),
              border:Border.all(color:done||sel?const Color(0xFF19F59A):const Color(0xFF193642),width:done||sel?1.7:1)),
            child:Stack(clipBehavior:Clip.none,children:[
              Center(child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
                Text(_ns[i].n,style:TextStyle(color:done?const Color(0xFF19F59A):Colors.white,fontSize:22,fontWeight:FontWeight.w800)),
                Text(_ns[i].no.toString(),style:const TextStyle(color:Colors.white38,fontSize:11))])),
              if(done)Positioned(top:-9,right:-5,child:Container(width:22,height:22,decoration:const BoxDecoration(color:Color(0xFF19F59A),shape:BoxShape.circle),
                child:const Icon(Icons.check_rounded,color:Color(0xFF06151D),size:15))),
            ])));
        })),
        const SizedBox(height:12),
        Text(ok?'Green zone: ±5 cents  •  chime played':'Tune to the green center zone',
          style:TextStyle(color:ok?const Color(0xFF19F59A):Colors.white38,fontSize:13,fontWeight:FontWeight.w600)),
      ]))));
  }
}

class _Wave extends CustomPainter{
  const _Wave({required this.has,required this.ok,required this.c,required this.p});final bool has,ok;final double c,p;
  @override void paint(Canvas x,Size s){final cx=s.width/2,cy=s.height/2;
    if(has)x.drawCircle(Offset(cx,cy),55,Paint()..color=(ok?const Color(0xFF19F59A):Colors.white).withOpacity(.08)..maskFilter=const MaskFilter.blur(BlurStyle.normal,25));
    x.drawLine(Offset(cx,10),Offset(cx,s.height-8),Paint()..color=ok?const Color(0xFF19F59A):Colors.white54..strokeWidth=3..strokeCap=StrokeCap.round);
    x.drawCircle(Offset(cx,cy),ok?18:13,Paint()..color=ok?const Color(0xFF19F59A):Colors.white70);
    for(var i=0;i<17;i++){final d=22+i*16.0,n=d/278,w=has?math.sin(i*.85+p*math.pi*2+c*.035).abs():.08,h=has?28+w*(92*(1-n*.42)):12+(1-n)*8;
      final q=Paint()..color=(ok?const Color(0xFF19F59A):Colors.white54).withOpacity(has ? .28 + (1 - n) * .72 : .2)..strokeWidth=4..strokeCap=StrokeCap.round;
      x.drawLine(Offset(cx-d,cy-h/2),Offset(cx-d,cy+h/2),q);x.drawLine(Offset(cx+d,cy-h/2),Offset(cx+d,cy+h/2),q);}
  }
  @override bool shouldRepaint(covariant _Wave o)=>o.c!=c||o.has!=has||o.ok!=ok||o.p!=p;
}
class _P{const _P(this.f,this.c);final double f,c;}

class _Ruler extends CustomPainter{
  const _Ruler({required this.c,required this.active,required this.ok});final double c;final bool active,ok;
  @override void paint(Canvas x,Size s){const green=Color(0xFF19F59A),amber=Color(0xFFFFC33D),red=Color(0xFFFF6E6E);final y=30.0;
    for(var i=0;i<25;i++){final v=-50+i*100/24,px=(v+50)/100*s.width,col=v.abs()<=5?green:v.abs()<=25?amber:red;
      x.drawLine(Offset(px,y-(i%2==0?16:11)),Offset(px,y+(i%2==0?16:11)),Paint()..color=col.withOpacity(active?1:.55)..strokeWidth=i%2==0?3:2..strokeCap=StrokeCap.round);}
    final v=active?c.clamp(-50.0,50.0):0.0,px=(v+50)/100*s.width,p=Paint()..color=(ok?green:Colors.white70)..strokeWidth=3.5;
    x.drawLine(Offset(px,3),Offset(px,58),p);final path=Path()..moveTo(px-8,62)..lineTo(px+8,62)..lineTo(px,52)..close();x.drawPath(path,Paint()..color=(ok?green:Colors.white70));
    _t(x,s,'-50',0,TextAlign.left);_t(x,s,'-25',.25,TextAlign.center);_t(x,s,'-5',.45,TextAlign.center);_t(x,s,'+5',.55,TextAlign.center);_t(x,s,'+25',.75,TextAlign.center);_t(x,s,'+50',1,TextAlign.right);
  }
  void _t(Canvas x,Size s,String z,double f,TextAlign a){final q=TextPainter(text:TextSpan(text:z,style:const TextStyle(color:Colors.white54,fontSize:11)),textDirection:TextDirection.ltr)..layout();final px=f*s.width-(a==TextAlign.left?0:a==TextAlign.right?q.width:q.width/2);q.paint(x,Offset(px,63));}
  @override bool shouldRepaint(covariant _Ruler o)=>o.c!=c||o.active!=active||o.ok!=ok;
}
