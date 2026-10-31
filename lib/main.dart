import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

void main() => runApp(const MaterialApp(
    debugShowCheckedModeBanner: false, home: HomeScreen()));

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
        backgroundColor: const Color(0xFF1B1B1B),
        body: Center(
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                backgroundColor: const Color(0xFF81B64C)),
            icon: const Icon(Icons.sports_esports, color: Colors.white),
            label: const Text('تشغيل مساعد الشطرنج',
                style: TextStyle(fontSize: 20, color: Colors.white)),
            onPressed: () => Navigator.push(
                c, MaterialPageRoute(builder: (_) => const ChessScreen())),
          ),
        ),
      );
}

class ChessScreen extends StatefulWidget {
  const ChessScreen({super.key});
  @override
  State<ChessScreen> createState() => _ChessScreenState();
}

class _ChessScreenState extends State<ChessScreen> {
  late final WebViewController wv;
  String status = 'ادخل لعبة وبعدين اضغط ⚪ أو ⚫';
  bool busy = false;
  String side = 'w';

  // chess.com: pieces = ".piece.wp.square-52" (file,rank 1-8). coords are absolute (not flipped)
  static const _readJs = r'''
(function(){
 var b=document.querySelector('wc-chess-board')||document.querySelector('chess-board');
 if(!b){Chan.postMessage('ERR');return;}
 var g=[];for(var i=0;i<8;i++)g.push(['','','','','','','','']);
 b.querySelectorAll('.piece').forEach(function(p){
  var m=p.className.match(/square-(\d)(\d)/),t=p.className.match(/\b([wb])([pnbrqk])\b/);
  if(m&&t){g[8-parseInt(m[2])][parseInt(m[1])-1]=t[1]=='w'?t[2].toUpperCase():t[2];}
 });
 Chan.postMessage(g.map(function(r){var s='',e=0;
  r.forEach(function(x){if(x==''){e++}else{if(e){s+=e;e=0}s+=x}});
  return s+(e?e:'')}).join('/'));
})();
''';

  @override
  void initState() {
    super.initState();
    wv = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('Chan', onMessageReceived: (m) => _onBoard(m.message))
      ..loadRequest(Uri.parse('https://www.chess.com/play/online'));
  }

  void _ask(String s) {
    if (busy) return;
    side = s;
    setState(() => status = 'جاري قراءة اللوحة...');
    wv.runJavaScript(_readJs);
  }

  String _castling(String p) {
    final rows = p.split('/');
    String expand(String r) => r.replaceAllMapped(
        RegExp(r'\d'), (m) => '.' * int.parse(m[0]!));
    final top = expand(rows[0]), bot = expand(rows[7]);
    var c = '';
    if (bot[4] == 'K' && bot[7] == 'R') c += 'K';
    if (bot[4] == 'K' && bot[0] == 'R') c += 'Q';
    if (top[4] == 'k' && top[7] == 'r') c += 'k';
    if (top[4] == 'k' && top[0] == 'r') c += 'q';
    return c.isEmpty ? '-' : c;
  }

  Future<void> _onBoard(String placement) async {
    if (placement == 'ERR' || placement.split('/').length != 8) {
      setState(() => status = 'ما لكيت لوحة، ادخل لعبة اول');
      return;
    }
    busy = true;
    final fen = '$placement $side ${_castling(placement)} - 0 1';
    setState(() => status = 'يفكر...');
    try {
      final mv = await _best(fen);
      _highlight(mv);
      setState(() => status =
          '${side == 'w' ? '⚪' : '⚫'}  أفضل حركة:  ${mv.substring(0, 2)} → ${mv.substring(2, 4)}');
    } catch (e) {
      setState(() => status = 'فشل: $e');
    } finally {
      busy = false;
    }
  }

  Future<String> _best(String fen) async {
    final q = Uri.encodeQueryComponent(fen);
    try {
      final r = await http
          .get(Uri.parse('https://stockfish.online/api/s/v2.php?fen=$q&depth=13'))
          .timeout(const Duration(seconds: 20));
      final j = jsonDecode(r.body);
      if (j['success'] == true) {
        return (j['bestmove'] as String).split(' ')[1]; // "bestmove e2e4 ponder ..."
      }
    } catch (_) {}
    // fallback: lichess cloud eval (only cached positions)
    final r = await http.get(
        Uri.parse('https://lichess.org/api/cloud-eval?fen=$q&multiPv=1'));
    if (r.statusCode != 200) throw 'ما كدرت احسب الموقف';
    return (jsonDecode(r.body)['pvs'][0]['moves'] as String).split(' ')[0];
  }

  void _highlight(String mv) {
    String sq(String s) => '${s.codeUnitAt(0) - 96}${s[1]}';
    wv.runJavaScript('''
(function(){
 var b=document.querySelector('wc-chess-board')||document.querySelector('chess-board');
 if(!b)return;
 b.querySelectorAll('.amr-hl').forEach(function(e){e.remove()});
 ['${sq(mv.substring(0, 2))}','${sq(mv.substring(2, 4))}'].forEach(function(s,i){
  var d=document.createElement('div');
  d.className='amr-hl highlight square-'+s;
  d.style.cssText='background:'+(i?'rgba(0,255,80,.65)':'rgba(255,200,0,.6)')+';pointer-events:none';
  b.appendChild(d);
 });
})();
''');
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(
            title: const Text('مساعد الشطرنج'),
            backgroundColor: const Color(0xFF262421),
            foregroundColor: Colors.white),
        body: Column(children: [
          Expanded(child: WebViewWidget(controller: wv)),
          Container(
            color: const Color(0xFF262421),
            padding: const EdgeInsets.all(10),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(status,
                  style: const TextStyle(color: Colors.white, fontSize: 17)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                    child: ElevatedButton(
                        onPressed: () => _ask('w'),
                        child: const Text('⚪ ابيض'))),
                const SizedBox(width: 10),
                Expanded(
                    child: ElevatedButton(
                        onPressed: () => _ask('b'),
                        child: const Text('⚫ اسود'))),
              ]),
            ]),
          ),
        ]),
      );
}