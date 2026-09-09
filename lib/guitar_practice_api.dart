import 'dart:convert';
import 'package:http/http.dart' as http;

class GuitarPractice {
  const GuitarPractice({required this.id,required this.title,required this.completed,required this.suggestedTime,required this.duration,required this.description,required this.dailyPracticeTime});
  final String id,title,suggestedTime,description; final bool completed; final int duration,dailyPracticeTime;
  factory GuitarPractice.fromJson(Map<String,dynamic> j)=>GuitarPractice(id:j['id']?.toString()??'',title:j['title']?.toString()??'',completed:j['completed']==true,suggestedTime:j['suggestedTime']?.toString()??'',duration:(j['duration'] as num?)?.toInt()??0,description:j['description']?.toString()??'',dailyPracticeTime:(j['dailyPracticeTime'] as num?)?.toInt()??0);
}
class GuitarPracticeResponse { const GuitarPracticeResponse({required this.date,required this.dailyPracticeTime,required this.practices}); final String date; final int dailyPracticeTime; final List<GuitarPractice> practices;
 factory GuitarPracticeResponse.fromJson(Map<String,dynamic> j)=>GuitarPracticeResponse(date:j['date']?.toString()??'',dailyPracticeTime:(j['dailyPracticeTime'] as num?)?.toInt()??0,practices:((j['practices'] as List?)??const[]).whereType<Map>().map((e)=>GuitarPractice.fromJson(Map<String,dynamic>.from(e))).toList()); }
class GuitarPracticeApi { static const endpoint='https://6a954d3a002d833b3121.fra.appwrite.run/';
 Future<GuitarPracticeResponse> list() async { final r=await http.get(Uri.parse(endpoint)); _check(r); return GuitarPracticeResponse.fromJson(jsonDecode(r.body)); }
 Future<void> create(Map<String,dynamic> v) async { final r=await http.post(Uri.parse(endpoint),headers:{'Content-Type':'application/json'},body:jsonEncode(v)); _check(r); }
 Future<void> update(String id,Map<String,dynamic> v) async { final b=Map<String,dynamic>.from(v)..['id']=id; final r=await http.put(Uri.parse(endpoint),headers:{'Content-Type':'application/json'},body:jsonEncode(b)); _check(r); }
 Future<void> delete(String id) async { final r=await http.delete(Uri.parse(endpoint),headers:{'Content-Type':'application/json'},body:jsonEncode({'id':id})); _check(r); }
 void _check(http.Response r){if(r.statusCode<200||r.statusCode>=300)throw Exception('Guitar Practice API '+r.statusCode.toString()+': '+r.body);}}