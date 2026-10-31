// chess_assist | Flutter (Android) | floating HUD over the chess.com app
// flow: button -> overlay permission -> screen-capture permission -> HUD + opens chess.com -> reads the board from pixels -> local Stockfish -> best move in the HUD
// first game: start it from the START position so the piece templates get saved (after that you can join mid-game)
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stockfish/stockfish.dart';

const _ch = MethodChannel('cca/native');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MaterialApp(debugShowCheckedModeBanner: false, theme: ThemeData.dark(), home: const Home()));
}

@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(debugShowCheckedModeBanner: false, home: OverlayHud()));
}

// ===================== UI =====================
class Home extends StatelessWidget {
  const Home({super.key});
  @override
  Widget build(BuildContext context) {
    final a = Assistant.I;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Text('مساعد الشطرنج', style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 64,
                child: ElevatedButton(
                  onPressed: () => a.start(),
                  child: const Text('تشغيل المساعد في الشطرنج', style: TextStyle(fontSize: 20)),
                ),
              ),
              const SizedBox(height: 20),
              ValueListenableBuilder<String>(
                valueListenable: a.status,
                builder: (_, s, __) => Text(s, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
              ),
              const SizedBox(height: 28),
              const Text(
                'أول مرة: ابدأ لعبة (ضد لاعب أو كمبيوتر) والرقعة بوضع البداية حتى يحفظ شكل القطع.\n'
                'شاومي: فعّل "عرض نوافذ منبثقة أثناء التشغيل بالخلفية" وخلّي البطارية "بدون قيود" للتطبيق.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.white60),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class OverlayHud extends StatefulWidget {
  const OverlayHud({super.key});
  @override
  State<OverlayHud> createState() => _OverlayHudState();
}

class _OverlayHudState extends State<OverlayHud> {
  String text = 'Chess assist\nwaiting...';
  @override
  void initState() {
    super.initState();
    FlutterOverlayWindow.overlayListener.listen((e) {
      if (e is Map && e['t'] != null && mounted) setState(() => text = e['t'].toString());
    });
    FlutterOverlayWindow.shareData({'cmd': 'hello'});
  }

  Widget _btn(String t) => GestureDetector(
        onTap: () => FlutterOverlayWindow.shareData({'cmd': t}),
        child: Container(
          width: 30,
          height: 30,
          margin: const EdgeInsets.all(2),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(6)),
          child: Text(t, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          margin: const EdgeInsets.all(2),
          padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
          decoration: BoxDecoration(color: const Color(0xEE080808), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white54)),
          child: Row(children: [
            Expanded(child: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold))),
            Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Row(children: [_btn('R'), _btn('F')]),
              Row(children: [_btn('C'), _btn('X')]),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ===================== engine =====================
class Engine {
  Stockfish? sf;
  Completer<String?>? _done;
  String _score = '';

  Future<void> init() async {
    if (sf != null) return;
    final s = Stockfish();
    var t = 0;
    while (s.state.value != StockfishState.ready) {
      await Future.delayed(const Duration(milliseconds: 100));
      if (++t > 200) throw 'stockfish did not start';
    }
    s.stdout.listen(_onLine);
    sf = s;
  }

  void _onLine(String l) {
    if (l.startsWith('info')) {
      final m = RegExp(r'score (cp|mate) (-?\d+)').firstMatch(l);
      if (m != null) {
        final v = int.parse(m.group(2)!);
        _score = m.group(1) == 'cp' ? '${v >= 0 ? '+' : ''}${(v / 100).toStringAsFixed(2)}' : 'mate $v';
      }
    } else if (l.startsWith('bestmove')) {
      final p = l.split(' ');
      final d = _done;
      if (d != null && !d.isCompleted) d.complete(p.length > 1 ? p[1] : null);
    }
  }

  Future<List<String>?> best(String fen) async {
    final s = sf;
    if (s == null) return null;
    _done = Completer<String?>();
    _score = '';
    s.stdin = 'position fen $fen';
    s.stdin = 'go movetime 600';
    final mv = await _done!.future.timeout(const Duration(seconds: 6), onTimeout: () => null);
    if (mv == null || mv == '(none)') return null;
    return [mv, _score];
  }

  void dispose() {
    try { sf?.dispose(); } catch (_) {}
    sf = null;
  }
}

// ===================== assistant (runs in the main isolate, heavy pixel work goes to compute) =====================
const _names = {'p': 'Pawn', 'n': 'Knight', 'b': 'Bishop', 'r': 'Rook', 'q': 'Queen', 'k': 'King'};
const _glyph = {'p': '♟', 'n': '♞', 'b': '♝', 'r': '♜', 'q': '♛', 'k': '♚'};

class Assistant {
  static final I = Assistant._();
  Assistant._();

  final status = ValueNotifier<String>('جاهز');
  final eng = Engine();
  bool running = false;
  Map<String, List<double>>? tpl;
  List<int>? rect; // x, y, side in full-res screen pixels
  int bad = 0;
  bool? flip; // true = black at the bottom of the screen
  Map<int, String>? prev; // board squares: rank*8+file, rank 0 = rank 1
  String? place;
  String stm = 'w', rights = 'KQkq', ep = '-', _last = '';
  StreamSubscription? _sub;

  void say(String s) {
    if (s == _last) return;
    _last = s;
    status.value = s.replaceAll('\n', ' | ');
    FlutterOverlayWindow.shareData({'t': s}).catchError((_) {});
  }

  Future<void> start() async {
    if (running) {
      await _ch.invokeMethod('launchChess');
      return;
    }
    try {
      var ok = await FlutterOverlayWindow.isPermissionGranted();
      if (!ok) ok = await FlutterOverlayWindow.requestPermission() ?? false;
      if (!ok) return say('لازم تعطي صلاحية "العرض فوق التطبيقات"');
      status.value = 'وافق على تسجيل الشاشة...';
      final cap = await _ch.invokeMethod<bool>('startCapture') ?? false;
      if (!cap) return say('رفضت صلاحية تسجيل الشاشة');
      for (var i = 0; i < 30 && !(await _ch.invokeMethod<bool>('ready') ?? false); i++) {
        await Future.delayed(const Duration(milliseconds: 150));
      }
      await eng.init();
      tpl = await _loadTpl();
      await FlutterOverlayWindow.showOverlay(
        height: 100,
        width: 310,
        alignment: OverlayAlignment.topCenter,
        enableDrag: true,
        overlayTitle: 'Chess assistant',
        overlayContent: 'running',
        flag: OverlayFlag.defaultFlag,
        positionGravity: PositionGravity.none,
      );
      _sub?.cancel();
      _sub = FlutterOverlayWindow.overlayListener.listen((e) {
        if (e is Map && e['cmd'] != null) _cmd(e['cmd'].toString());
      });
      running = true;
      flip = null; prev = null; place = null; rect = null;
      say(tpl == null ? 'waiting for the start position' : 'ready. open a game');
      final opened = await _ch.invokeMethod<bool>('launchChess') ?? false;
      if (!opened) say('تطبيق chess.com مو منصب');
      _loop();
    } catch (e) {
      say('error: $e');
    }
  }

  Future<void> stop() async {
    running = false;
    _sub?.cancel();
    try { await FlutterOverlayWindow.closeOverlay(); } catch (_) {}
    try { await _ch.invokeMethod('stopCapture'); } catch (_) {}
    eng.dispose();
    status.value = 'وقف';
  }

  void _cmd(String c) {
    switch (c) {
      case 'hello':
        FlutterOverlayWindow.shareData({'t': _last}).catchError((_) {});
        break;
      case 'R':
        flip = null; prev = null; place = null; rect = null; bad = 0;
        say('reset');
        break;
      case 'F':
        if (flip != null) { flip = !flip!; prev = null; place = null; }
        break;
      case 'C':
        tpl = null; flip = null; prev = null; place = null;
        SharedPreferences.getInstance().then((p) => p.remove('tpl'));
        say('templates cleared\nwaiting for the start position');
        break;
      case 'X':
        stop();
        break;
    }
  }

  Future<void> _loop() async {
    while (running) {
      await Future.delayed(const Duration(milliseconds: 300));
      try {
        await _tick();
      } catch (e) {
        say('error: ${e.toString().split('\n').first}');
      }
    }
  }

  Future<Uint8List?> _crop() async {
    final r = rect;
    if (r == null) return null;
    final b = await _ch.invokeMethod<Uint8List>('crop', {'x': r[0], 'y': r[1], 's': r[2], 'out': 512});
    return (b != null && b.length == 512 * 512 * 4) ? b : null;
  }

  Future<void> _tick() async {
    if (rect == null) {
      final f = await _ch.invokeMethod<Map>('full', {'w': 360});
      if (f == null) return say('waiting for screen capture...');
      final w = f['w'] as int, h = f['h'] as int, fw = f['fw'] as int;
      final r = await compute(detectBoard, <dynamic>[f['px'] as Uint8List, w, h]);
      if (r == null) return say('open a game\nboard not found');
      final k = fw / w;
      rect = [(r[0] * k).round(), (r[1] * k).round(), (r[2] * k).round()];
    }
    final a = await _crop();
    if (a == null) return;
    if (tpl == null) {
      final t = await compute(calibrateJob, a);
      if (t == null) return say('waiting for the start position');
      tpl = t;
      await _saveTpl(t);
      return say('calibrated. waiting for a game...');
    }
    await Future.delayed(const Duration(milliseconds: 250));
    final b = await _crop();
    if (b == null) return;
    final res = await compute(readJob, <dynamic>[a, b, tpl!]);
    final o1 = (res[0] as Map).cast<int, String>();
    final o2 = (res[1] as Map).cast<int, String>();
    if (_key(o1) != _key(o2)) return; // a piece was still sliding
    await _process(o2);
  }

  Future<void> _process(Map<int, String> occ) async {
    final st = _startMatch(occ);
    if (st != null) {
      flip = st; prev = null; place = null; rights = 'KQkq'; ep = '-'; stm = 'w';
    } else {
      flip ??= _guessFlip(occ);
    }
    final f = flip!;
    final cur = _toMap(occ, f);
    if (!_kingsOk(cur)) {
      say("can't read board (${occ.length} pieces)\npress F or R");
      if (++bad >= 8) { rect = null; bad = 0; }
      return;
    }
    bad = 0;
    final pl = _placement(cur);
    if (pl == place) return;
    final me = f ? 'b' : 'w';
    String ns;
    if (st != null) {
      ns = 'w';
    } else if (prev == null) {
      ns = me;
    } else {
      // side to move = opposite of the colour that just ARRIVED on a square
      var whiteArrived = false, blackArrived = false;
      cur.forEach((k, p) {
        final q = prev![k];
        if (q == null || _isW(q) != _isW(p)) {
          if (_isW(p)) { whiteArrived = true; } else { blackArrived = true; }
        }
      });
      ns = (whiteArrived && !blackArrived) ? 'b' : (blackArrived && !whiteArrived) ? 'w' : me;
    }
    ep = prev == null ? '-' : _epSquare(prev!, cur, ns);
    if (prev == null && st == null) { rights = _guessRights(cur); } else { rights = _trimRights(rights, cur); }
    prev = cur; place = pl; stm = ns;
    if (ns != me) return say("opponent's turn...");
    await _suggest(cur, pl);
  }

  Future<void> _suggest(Map<int, String> cur, String pl) async {
    say('thinking...');
    final fen = '$pl $stm ${rights.isEmpty ? '-' : rights} $ep 0 1';
    final r = await eng.best(fen);
    if (r == null) return say('engine: no move');
    if (place != pl) return;
    final mv = r[0];
    final from = mv.substring(0, 2), to = mv.substring(2, 4), promo = mv.length > 4 ? ' =${mv[4].toUpperCase()}' : '';
    final sq = (from.codeUnitAt(1) - 49) * 8 + (from.codeUnitAt(0) - 97);
    final pc = cur[sq]?.toLowerCase();
    final name = pc == null ? '?' : '${_glyph[pc]} ${_names[pc]}';
    say('$name  $from → $to$promo\neval ${r[1]}');
  }

  // ---- persistence ----
  Future<void> _saveTpl(Map<String, List<double>> t) async {
    final p = await SharedPreferences.getInstance();
    final o = <String, List<int>>{};
    t.forEach((k, v) => o[k] = k == 'thr' ? [v[0].round()] : v.map((x) => (x * 255).round()).toList());
    await p.setString('tpl', jsonEncode(o));
  }

  Future<Map<String, List<double>>?> _loadTpl() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString('tpl');
    if (s == null) return null;
    final o = jsonDecode(s) as Map<String, dynamic>;
    final t = <String, List<double>>{};
    o.forEach((k, v) {
      final l = (v as List).map((x) => (x as num).toDouble()).toList();
      t[k] = k == 'thr' ? l : l.map((x) => x / 255).toList();
    });
    return t;
  }
}

// ===================== board logic (screen coords: r = row from top, c = col from left; key = r*8+c) =====================
String _key(Map<int, String> m) => (m.keys.toList()..sort()).map((k) => '$k${m[k]}').join(',');
bool _isW(String p) => p == p.toUpperCase();
String _back(bool flip) => flip ? 'rnbkqbnr' : 'rnbqkbnr'; // black at the bottom mirrors the king/queen files

Map<int, String> _startLayout(bool flip) {
  final b = _back(flip);
  final m = <int, String>{};
  for (var c = 0; c < 8; c++) {
    m[c] = flip ? b[c].toUpperCase() : b[c];
    m[8 + c] = flip ? 'P' : 'p';
    m[48 + c] = flip ? 'p' : 'P';
    m[56 + c] = flip ? b[c] : b[c].toUpperCase();
  }
  return m;
}

bool? _startMatch(Map<int, String> occ) {
  for (final f in [false, true]) {
    if (_key(occ) == _key(_startLayout(f))) return f;
  }
  return null;
}

bool _guessFlip(Map<int, String> occ) {
  // mid-game join: white pawns nearer the top of the screen = flipped (weak in endgames, F button fixes it)
  double avg(bool Function(String) t) {
    var s = 0, n = 0;
    occ.forEach((k, p) { if (t(p)) { s += k ~/ 8; n++; } });
    return n == 0 ? -1 : s / n;
  }
  final wp = avg((p) => p == 'P'), bp = avg((p) => p == 'p');
  if (wp >= 0 && bp >= 0) return wp < bp;
  final w = avg((p) => _isW(p)), b = avg((p) => !_isW(p));
  return w >= 0 && b >= 0 && w < b;
}

Map<int, String> _toMap(Map<int, String> occ, bool flip) {
  final m = <int, String>{};
  occ.forEach((k, p) {
    final r = k ~/ 8, c = k % 8;
    final file = flip ? 7 - c : c, rank = flip ? r : 7 - r; // unflipped: top row = rank 8; flipped: top row = rank 1, left col = file h
    m[rank * 8 + file] = p;
  });
  return m;
}

bool _kingsOk(Map<int, String> m) {
  var K = 0, k = 0;
  m.forEach((s, p) {
    if (p == 'K') K++;
    if (p == 'k') k++;
    if ((p == 'p' || p == 'P') && (s < 8 || s > 55)) { K += 99; }
  });
  return K == 1 && k == 1;
}

String _placement(Map<int, String> m) {
  final rows = <String>[];
  for (var rank = 7; rank >= 0; rank--) {
    var s = '', e = 0;
    for (var file = 0; file < 8; file++) {
      final p = m[rank * 8 + file];
      if (p == null) { e++; } else { if (e > 0) { s += '$e'; e = 0; } s += p; }
    }
    if (e > 0) s += '$e';
    rows.add(s);
  }
  return rows.join('/');
}

String _guessRights(Map<int, String> m) {
  var s = '';
  if (m[4] == 'K' && m[7] == 'R') s += 'K';
  if (m[4] == 'K' && m[0] == 'R') s += 'Q';
  if (m[60] == 'k' && m[63] == 'r') s += 'k';
  if (m[60] == 'k' && m[56] == 'r') s += 'q';
  return s;
}

String _trimRights(String r, Map<int, String> m) {
  final out = StringBuffer();
  for (final ch in r.split('')) {
    final keep = switch (ch) {
      'K' => m[4] == 'K' && m[7] == 'R',
      'Q' => m[4] == 'K' && m[0] == 'R',
      'k' => m[60] == 'k' && m[63] == 'r',
      'q' => m[60] == 'k' && m[56] == 'r',
      _ => false,
    };
    if (keep) out.write(ch);
  }
  return out.toString();
}

String _epSquare(Map<int, String> prev, Map<int, String> cur, String stm) {
  const files = 'abcdefgh';
  final moverWhite = stm == 'b'; // stm = side to move now, so the mover was the other colour
  for (var f = 0; f < 8; f++) {
    if (moverWhite && prev[8 + f] == 'P' && cur[8 + f] == null && cur[24 + f] == 'P') return '${files[f]}3';
    if (!moverWhite && prev[48 + f] == 'p' && cur[48 + f] == null && cur[32 + f] == 'p') return '${files[f]}6';
  }
  return '-';
}

// ===================== vision (top-level so compute() can run them in a background isolate) =====================
// finds the 8x8 board in a downscaled screenshot: 7 internal vertical + 7 horizontal square boundaries must carry strong gradient
// relative to the average gradient inside the rectangle. returns [x, y, side] in the downscaled image, or null
List<int>? detectBoard(List a) {
  final px = a[0] as Uint8List;
  final w = a[1] as int, h = a[2] as int;
  if (px.length < w * h * 4) return null;
  final L = Int32List(w * h);
  for (var i = 0; i < w * h; i++) {
    final o = i * 4;
    L[i] = (px[o] * 77 + px[o + 1] * 150 + px[o + 2] * 29) >> 8;
  }
  final colPre = Int32List(w * (h + 1)); // colPre[x*(h+1)+y] = sum of |dL/dx| in column x for rows < y
  final rowPre = Int32List(h * (w + 1));
  final integ = Int32List((w + 1) * (h + 1));
  for (var y = 0; y < h; y++) {
    var run = 0;
    for (var x = 0; x < w; x++) {
      var gx = 0, gy = 0;
      if (x > 0 && x < w - 1) gx = (L[y * w + x + 1] - L[y * w + x - 1]).abs();
      if (y > 0 && y < h - 1) gy = (L[(y + 1) * w + x] - L[(y - 1) * w + x]).abs();
      colPre[x * (h + 1) + y + 1] = colPre[x * (h + 1) + y] + gx;
      rowPre[y * (w + 1) + x + 1] = rowPre[y * (w + 1) + x] + gy;
      run += gx + gy;
      integ[(y + 1) * (w + 1) + x + 1] = integ[y * (w + 1) + x + 1] + run;
    }
  }
  double score(int x0, int y0, int s) {
    var v = 0, hh = 0;
    for (var k = 1; k < 8; k++) {
      final d = (k * s / 8).round();
      final xb = x0 + d, yb = y0 + d;
      v += colPre[xb * (h + 1) + y0 + s] - colPre[xb * (h + 1) + y0];
      hh += rowPre[yb * (w + 1) + x0 + s] - rowPre[yb * (w + 1) + x0];
    }
    final tot = integ[(y0 + s) * (w + 1) + x0 + s] - integ[y0 * (w + 1) + x0 + s] - integ[(y0 + s) * (w + 1) + x0] + integ[y0 * (w + 1) + x0];
    final mean = tot / (s * s);
    if (mean < 1) return 0;
    return (v < hh ? v : hh) / (7 * s) / mean;
  }
  var best = 0.0, bx = 0, by = 0, bs = 0;
  for (var s = (w * 0.7).round(); s <= w; s += 2) {
    for (var x0 = 0; x0 + s <= w; x0 += 2) {
      for (var y0 = 0; y0 + s <= h; y0 += 2) {
        final sc = score(x0, y0, s);
        if (sc > best) { best = sc; bx = x0; by = y0; bs = s; }
      }
    }
  }
  if (bs == 0) return null;
  var rb = best, rx = bx, ry = by, rs = bs;
  for (var s = bs - 2; s <= bs + 2; s++) {
    for (var x0 = bx - 2; x0 <= bx + 2; x0++) {
      for (var y0 = by - 2; y0 <= by + 2; y0++) {
        if (s < 16 || x0 < 0 || y0 < 0 || x0 + s > w || y0 + s > h) continue;
        final sc = score(x0, y0, s);
        if (sc > rb) { rb = sc; rx = x0; ry = y0; rs = s; }
      }
    }
  }
  if (rb < 3.0) return null;
  return [rx, ry, rs];
}

class _F {
  final double lum;
  final Float32List shape;
  _F(this.lum, this.shape);
}

Uint8List _morph(Uint8List m, int n, int k, bool dil) {
  final t = Uint8List(n * n), o = Uint8List(n * n);
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      var v = dil ? 0 : 1;
      for (var d = -k; d <= k; d++) {
        final xx = x + d;
        if (xx < 0 || xx >= n) continue;
        final q = m[y * n + xx];
        if (dil ? q == 1 : q == 0) { v = dil ? 1 : 0; break; }
      }
      t[y * n + x] = v;
    }
  }
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      var v = dil ? 0 : 1;
      for (var d = -k; d <= k; d++) {
        final yy = y + d;
        if (yy < 0 || yy >= n) continue;
        final q = t[yy * n + x];
        if (dil ? q == 1 : q == 0) { v = dil ? 1 : 0; break; }
      }
      o[y * n + x] = v;
    }
  }
  return o;
}

// silhouette (background independent) + brightness for one 64x64 cell of the 512x512 RGBA crop; null = empty square
_F? _feat(Uint8List px, int cx, int cy) {
  const n = 64;
  final r = Uint8List(n * n), g = Uint8List(n * n), b = Uint8List(n * n);
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      final o = ((cy * n + y) * 512 + cx * n + x) * 4, i = y * n + x;
      r[i] = px[o]; g[i] = px[o + 1]; b[i] = px[o + 2];
    }
  }
  int med(Uint8List ch) { // median of a 3px ring = the square's own background (light, dark or last-move highlight)
    final hist = List<int>.filled(256, 0);
    var cnt = 0;
    for (var x = 0; x < n; x++) {
      for (var t = 0; t < 3; t++) { hist[ch[t * n + x]]++; hist[ch[(n - 1 - t) * n + x]]++; cnt += 2; }
    }
    for (var y = 3; y < n - 3; y++) {
      for (var t = 0; t < 3; t++) { hist[ch[y * n + t]]++; hist[ch[y * n + n - 1 - t]]++; cnt += 2; }
    }
    var acc = 0;
    for (var v = 0; v < 256; v++) { acc += hist[v]; if (acc * 2 >= cnt) return v; }
    return 0;
  }
  final br = med(r), bg = med(g), bb = med(b);
  var m = Uint8List(n * n);
  for (var i = 0; i < n * n; i++) {
    if ((r[i] - br).abs() + (g[i] - bg).abs() + (b[i] - bb).abs() > 45) m[i] = 1;
  }
  m = _morph(_morph(m, n, 2, true), n, 2, false); // closing 5x5
  // fill holes: everything not reachable from the border through empty pixels is piece
  final reach = Uint8List(n * n);
  final q = Int32List(n * n);
  var qh = 0, qt = 0;
  void push(int i) { if (m[i] == 0 && reach[i] == 0) { reach[i] = 1; q[qt++] = i; } }
  for (var i = 0; i < n; i++) { push(i); push((n - 1) * n + i); push(i * n); push(i * n + n - 1); }
  while (qh < qt) {
    final i = q[qh++], x = i % n, y = i ~/ n;
    if (x > 0) push(i - 1);
    if (x < n - 1) push(i + 1);
    if (y > 0) push(i - n);
    if (y < n - 1) push(i + n);
  }
  final fill = Uint8List(n * n);
  for (var i = 0; i < n * n; i++) { fill[i] = reach[i] == 0 ? 1 : 0; }
  // drop small blobs (rank/file letters, move hints): connected components under 250 px
  final lab = Uint8List(n * n), keep = Uint8List(n * n);
  for (var s = 0; s < n * n; s++) {
    if (fill[s] != 1 || lab[s] != 0) continue;
    qh = 0; qt = 0;
    lab[s] = 1; q[qt++] = s;
    while (qh < qt) {
      final i = q[qh++], x = i % n, y = i ~/ n;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx, yy = y + dy;
          if (xx < 0 || yy < 0 || xx >= n || yy >= n) continue;
          final j = yy * n + xx;
          if (fill[j] == 1 && lab[j] == 0) { lab[j] = 1; q[qt++] = j; }
        }
      }
    }
    if (qt >= 250) { for (var k = 0; k < qt; k++) { keep[q[k]] = 1; } }
  }
  var area = 0;
  for (var i = 0; i < n * n; i++) { area += keep[i]; }
  if (area / (n * n) < 0.07) return null;
  var core = _morph(keep, n, 4, false);
  var cn = 0;
  for (var i = 0; i < n * n; i++) { cn += core[i]; }
  if (cn == 0) core = keep;
  double ls = 0;
  var lc = 0;
  for (var i = 0; i < n * n; i++) {
    if (core[i] == 1) { ls += 0.299 * r[i] + 0.587 * g[i] + 0.114 * b[i]; lc++; }
  }
  final shape = Float32List(32 * 32);
  for (var y = 0; y < 32; y++) {
    for (var x = 0; x < 32; x++) {
      shape[y * 32 + x] = (keep[2 * y * n + 2 * x] + keep[2 * y * n + 2 * x + 1] + keep[(2 * y + 1) * n + 2 * x] + keep[(2 * y + 1) * n + 2 * x + 1]) / 4.0;
    }
  }
  return _F(ls / lc, shape);
}

// needs the 32-piece start position in the 512x512 crop. returns templates {'Wk': shape..., 'Bp': ..., 'thr': [lum threshold]} or null
Map<String, List<double>>? calibrateJob(Uint8List px) {
  final fs = List<_F?>.generate(64, (i) => _feat(px, i % 8, i ~/ 8));
  for (var r = 2; r < 6; r++) {
    for (var c = 0; c < 8; c++) { if (fs[r * 8 + c] != null) return null; }
  }
  for (final r in [0, 1, 6, 7]) {
    for (var c = 0; c < 8; c++) { if (fs[r * 8 + c] == null) return null; }
  }
  double avg(List<int> rows) {
    var s = 0.0;
    for (final r in rows) { for (var c = 0; c < 8; c++) { s += fs[r * 8 + c]!.lum; } }
    return s / (rows.length * 8);
  }
  final top = avg([0, 1]), bot = avg([6, 7]);
  if ((top - bot).abs() < 60) return null;
  final flip = bot < top; // dark pieces at the bottom = I'm black
  final back = _back(flip);
  final acc = <String, List<Float32List>>{};
  for (var c = 0; c < 8; c++) {
    final rows = [
      [0, back[c], flip],
      [1, 'p', flip],
      [6, 'p', !flip],
      [7, back[c], !flip],
    ];
    for (final e in rows) {
      final key = ((e[2] as bool) ? 'W' : 'B') + (e[1] as String);
      acc.putIfAbsent(key, () => []).add(fs[(e[0] as int) * 8 + c]!.shape);
    }
  }
  final out = <String, List<double>>{};
  acc.forEach((k, list) {
    final m = List<double>.filled(1024, 0);
    for (final s in list) { for (var i = 0; i < 1024; i++) { m[i] += s[i]; } }
    for (var i = 0; i < 1024; i++) { m[i] /= list.length; }
    out[k] = m;
  });
  out['thr'] = [(top + bot) / 2];
  return out;
}

Map<int, String> _read(Uint8List px, Map<String, List<double>> tpl) {
  final occ = <int, String>{};
  final thr = tpl['thr']![0];
  for (var i = 0; i < 64; i++) {
    final f = _feat(px, i % 8, i ~/ 8);
    if (f == null) continue;
    final pre = f.lum > thr ? 'W' : 'B';
    var best = 0.0;
    String? bl;
    tpl.forEach((k, t) {
      if (k == 'thr' || k[0] != pre) return;
      var inter = 0, uni = 0;
      for (var j = 0; j < 1024; j++) {
        final sb = f.shape[j] > 0.5, tb = t[j] > 0.5;
        if (sb && tb) inter++;
        if (sb || tb) uni++;
      }
      final iou = inter / (uni == 0 ? 1 : uni);
      if (iou > best) { best = iou; bl = k[1]; }
    });
    if (bl != null && best > 0.5) occ[i] = pre == 'W' ? bl!.toUpperCase() : bl!;
  }
  return occ;
}

List readJob(List a) {
  final tpl = <String, List<double>>{};
  (a[2] as Map).forEach((k, v) => tpl[k as String] = (v as List).map((x) => (x as num).toDouble()).toList());
  return [_read(a[0] as Uint8List, tpl), _read(a[1] as Uint8List, tpl)];
}
