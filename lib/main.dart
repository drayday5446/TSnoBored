import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ------------------------------------------------------------ tuning
const double kW = 192; // game canvas, 3:2 like the Sidekick screen
const double kH = 128;
const double kLidAspect = 1.59; // Sidekick lid width / height
const double kScreenLeft = 0.193; // screen position inside the lid
const double kScreenTop = 0.11;
const double kScreenW = 0.633;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: SnowBored(),
  ));
}

// ------------------------------------------------------------ audio synth
class Synth {
  static const int sr = 22050;

  static double _hz(int m) => 440.0 * pow(2, (m - 69) / 12.0);
  static double _sq(double ph, double duty) => (ph % 1.0) < duty ? 1.0 : -1.0;
  static double _tw(double ph) => 4 * ((ph % 1.0) - 0.5).abs() - 1.0;

  static Uint8List wav(List<double> s) {
    final n = s.length;
    final b = ByteData(44 + n * 2);
    void str(int o, String t) {
      for (int i = 0; i < t.length; i++) {
        b.setUint8(o + i, t.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    b.setUint32(4, 36 + n * 2, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little);
    b.setUint16(22, 1, Endian.little);
    b.setUint32(24, sr, Endian.little);
    b.setUint32(28, sr * 2, Endian.little);
    b.setUint16(32, 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    str(36, 'data');
    b.setUint32(40, n * 2, Endian.little);
    for (int i = 0; i < n; i++) {
      final v = (s[i].clamp(-1.0, 1.0) * 32767).round();
      b.setInt16(44 + i * 2, v, Endian.little);
    }
    return b.buffer.asUint8List();
  }

  // 16-bit style loop: square lead, triangle bass, kick/snare/hat
  static Uint8List music() {
    const mel = [
      72, 76, 79, 76, 74, 77, 81, 77,
      72, 76, 79, 84, 83, 79, 76, 74,
      71, 74, 77, 74, 72, 76, 79, 76,
      74, 77, 81, 86, 84, 0, 79, 0,
    ];
    const bass = [48, 50, 48, 43, 43, 48, 53, 43];
    final spn = (0.2 * sr).round();
    final total = spn * 32;
    final out = List<double>.filled(total, 0.0);
    final rng = Random(7);
    double mph = 0, bph = 0;
    for (int i = 0; i < total; i++) {
      final st = i ~/ spn;
      final pos = (i % spn) / spn;
      final t = (i % spn) / sr;
      double v = 0;
      final m = mel[st];
      if (m > 0) {
        mph += _hz(m) / sr;
        double env = 1.0 - 0.45 * pos;
        if (pos > 0.85) env *= (1 - pos) / 0.15;
        v += 0.17 * _sq(mph, 0.25) * env;
      }
      bph += _hz(bass[st ~/ 4]) / sr;
      v += 0.25 * _tw(bph) * (0.55 + 0.45 * (1 - pos));
      if (st % 4 == 0) {
        v += 0.45 *
            sin(2 * pi * (45 * t + (110 / 18) * (1 - exp(-18 * t)))) *
            exp(-t * 14);
      } else if (st % 4 == 2) {
        v += (rng.nextDouble() * 2 - 1) * 0.18 * exp(-t * 22);
      }
      if (st % 2 == 1) {
        v += (rng.nextDouble() * 2 - 1) * 0.07 * exp(-t * 70);
      }
      out[i] = v * 0.8;
    }
    return wav(out);
  }

  // snow whoosh + thump
  static Uint8List start() {
    final n = (0.45 * sr).round();
    final out = List<double>.filled(n, 0.0);
    final rng = Random(3);
    double lp = 0;
    for (int i = 0; i < n; i++) {
      final t = i / sr;
      final nz = rng.nextDouble() * 2 - 1;
      lp += (nz - lp) * (0.08 + 0.6 * t);
      final env = (1 - exp(-t * 90)) * exp(-t * 6);
      double v = lp * env * 1.6;
      v += sin(2 * pi * (80 - 60 * t) * t) * exp(-t * 14) * 0.6;
      out[i] = v * 0.7;
    }
    return wav(out);
  }

  // falling square sweep, then dizzy pings
  static Uint8List crash() {
    final n = (1.6 * sr).round();
    final out = List<double>.filled(n, 0.0);
    final rng = Random(5);
    double ph = 0;
    for (int i = 0; i < n; i++) {
      final t = i / sr;
      double v = 0;
      if (t < 0.12) {
        v += (rng.nextDouble() * 2 - 1) * 0.5 * exp(-t * 30);
      }
      if (t < 0.75) {
        final f = 900 * exp(-t * 2.6) + 90 + 25 * sin(t * 40);
        ph += f / sr;
        v += _sq(ph, 0.5) * 0.32 * (1 - t / 0.75);
      }
      for (int k = 0; k < 4; k++) {
        final tt = t - (0.85 + k * 0.18);
        if (tt >= 0 && tt < 0.14) {
          final f = k.isEven ? 1568.0 : 1175.0;
          v += _tw(f * tt) * 0.28 * (1 - tt / 0.14);
        }
      }
      out[i] = v * 0.85;
    }
    return wav(out);
  }
}

// ------------------------------------------------------------ sprites
const Map<String, Color> _pal = {
  'G': Color(0xFF3A8A52),
  'D': Color(0xFF1F5A38),
  'L': Color(0xFF74B982),
  'W': Color(0xFFFFFFFF),
  'T': Color(0xFF6B4423),
  'S': Color(0xFFA9C1E6),
  'O': Color(0xFFE8601C),
  'K': Color(0xFFF2C9A0),
  'B': Color(0xFF2F6FD0),
  'b': Color(0xFF1F4F9A),
  'P': Color(0xFF3A3F66),
  'Y': Color(0xFFE8B030),
  'R': Color(0xFFB86A10),
  'X': Color(0xFF222222),
};

const List<String> _tree = [
  '......D......',
  '.....DGD.....',
  '....DGLGD....',
  '.....GWG.....',
  '....DGLGGD...',
  '...DGLWGLGD..',
  '....GGWGGG...',
  '...DGLGWLGD..',
  '..DGLWGGLGGD.',
  '...GGLGWGGG..',
  '..DGLGGLWGGD.',
  '.DGGLWGGGLGGD',
  '..DDGGLGGGDD.',
  '.....TTT.....',
  '.....TTT.....',
  '..SSSSSSSSS..',
];

const List<String> _rider = [
  '...OOOO....',
  '..OOOOOO...',
  '..OKKKKO...',
  '..OKKXK....',
  '...KKKK....',
  '..BBBBBB...',
  '.KBBBBBBK..',
  '.KBBbBBBK..',
  '..BBBBBB...',
  '..PPPPPP...',
  '..PP..PP...',
  '..PP..PP...',
  'YYYYYYYYYYY',
  '.RRRRRRRRR.',
];

const List<String> _crashed = [
  '.OOO............',
  'OOKKBBBBBPPP....',
  'OKXKBBbBBPPPPYY.',
  '.KKKBBBBBPPPYYYY',
  '..........RRRR..',
];

void _sprite(Canvas c, List<String> rows, double x, double y, Paint p) {
  final ix = x.roundToDouble();
  final iy = y.roundToDouble();
  for (int r = 0; r < rows.length; r++) {
    final row = rows[r];
    int i = 0;
    while (i < row.length) {
      final ch = row[i];
      int j = i;
      while (j < row.length && row[j] == ch) {
        j++;
      }
      final col = _pal[ch];
      if (col != null) {
        p.color = col;
        c.drawRect(
            Rect.fromLTWH(ix + i, iy + r, (j - i).toDouble() + 0.03, 1.03), p);
      }
      i = j;
    }
  }
}

double _tri(double t) => ((t - t.floorToDouble()) - 0.5).abs() * 2;

// ------------------------------------------------------------ game
class Obstacle {
  double x;
  double y;
  Obstacle(this.x, this.y);
}

class SnowBored extends StatefulWidget {
  const SnowBored({super.key});
  @override
  State<SnowBored> createState() => _SnowBoredState();
}

class _SnowBoredState extends State<SnowBored>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  final Random _rng = Random();
  Duration _last = Duration.zero;

  // audio
  final AudioPlayer _music = AudioPlayer();
  final AudioPlayer _sfx = AudioPlayer();
  late final Uint8List _musicBytes;
  late final Uint8List _startBytes;
  late final Uint8List _crashBytes;
  bool musicLoaded = false;
  bool musicPlaying = false;

  // settings
  bool musicOn = true;
  bool sfxOn = true;
  bool portraitPref = true;

  // status banner
  final Battery _battery = Battery();
  int batteryLevel = 100;
  int bars = 4;
  Timer? _statusTimer;

  // layout
  double u = 3; // screen px per logical px

  // state
  bool holding = false;
  bool dead = false;
  bool started = false;
  int menu = 0; // 0 none, 1 pause, 2 settings
  double deadTimer = 0;
  double t = 0;

  double py = 60;
  double vy = 0;
  double dist = 0;
  double best = 0;
  double nextSpawn = 90;
  double gc = 70;
  final List<Obstacle> obs = [];
  final List<Offset> trail = [];

  static const double maxVy = 58;
  double get px => kW * 0.2;
  int get score => (dist / 12).floor();

  // mountain narrows as the score climbs (world x = distance travelled)
  double narrowAt(double wx) =>
      min(20.0, max(0.0, wx / 12 - 150) * 0.017);
  double topRidge(double wx) =>
      30 + narrowAt(wx) + 3 * _tri(wx / 26) + 1.5 * _tri(wx / 10);
  double bottomRidge(double wx) =>
      kH - 6 - narrowAt(wx) - 3 * _tri((wx + 11) / 24) - 1.5 * _tri((wx + 3) / 10);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _musicBytes = Synth.music();
    _startBytes = Synth.start();
    _crashBytes = Synth.crash();
    _applyOrientation();
    _loadPrefs();
    _refreshStatus();
    _statusTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _refreshStatus());
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _ticker.dispose();
    _music.dispose();
    _sfx.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && started && !dead && menu == 0) {
      _openMenu();
    }
  }

  Future<void> _loadPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      musicOn = p.getBool('music') ?? true;
      sfxOn = p.getBool('sfx') ?? true;
      portraitPref = p.getBool('portrait') ?? true;
      _applyOrientation();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('music', musicOn);
      await p.setBool('sfx', sfxOn);
      await p.setBool('portrait', portraitPref);
    } catch (_) {}
  }

  void _applyOrientation() {
    SystemChrome.setPreferredOrientations(portraitPref
        ? [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]
        : [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }

  Future<void> _refreshStatus() async {
    try {
      batteryLevel = await _battery.batteryLevel;
    } catch (_) {}
    try {
      final r = await Connectivity().checkConnectivity();
      if (r.contains(ConnectivityResult.wifi) ||
          r.contains(ConnectivityResult.ethernet)) {
        bars = 4;
      } else if (r.contains(ConnectivityResult.mobile)) {
        bars = 3;
      } else if (r.contains(ConnectivityResult.none)) {
        bars = 0;
      } else {
        bars = 2;
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------- audio helpers
  Future<void> _musicSync() async {
    final want = musicOn && started && !dead && menu == 0;
    try {
      if (want && !musicPlaying) {
        if (musicLoaded) {
          await _music.resume();
        } else {
          await _music.setReleaseMode(ReleaseMode.loop);
          await _music.setVolume(0.45);
          await _music.play(BytesSource(_musicBytes, mimeType: 'audio/wav'));
          musicLoaded = true;
        }
        musicPlaying = true;
      } else if (!want && musicPlaying) {
        await _music.pause();
        musicPlaying = false;
      }
    } catch (_) {}
  }

  Future<void> _musicRestart() async {
    try {
      await _music.stop();
    } catch (_) {}
    musicLoaded = false;
    musicPlaying = false;
  }

  Future<void> _playSfx(Uint8List bytes) async {
    if (!sfxOn) return;
    try {
      await _sfx.stop();
      await _sfx.setVolume(0.9);
      await _sfx.play(BytesSource(bytes, mimeType: 'audio/wav'));
    } catch (_) {}
  }

  // ---------------------------------------------------------- menu actions
  void _openMenu() {
    menu = 1;
    _musicSync();
    setState(() {});
  }

  void _closeMenu() {
    menu = 0;
    _musicSync();
    setState(() {});
  }

  void _setMusic(bool v) {
    musicOn = v;
    _savePrefs();
    _musicSync();
    setState(() {});
  }

  void _setSfx(bool v) {
    sfxOn = v;
    _savePrefs();
    setState(() {});
  }

  void _setPortrait(bool v) {
    portraitPref = v;
    _savePrefs();
    _applyOrientation();
    setState(() {});
  }

  // ---------------------------------------------------------- game logic
  void _onTick(Duration elapsed) {
    double dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt > 0.05) dt = 0.05;
    _update(dt);
    setState(() {});
  }

  void _reset() {
    py = 60;
    vy = 0;
    dist = 0;
    nextSpawn = 90;
    gc = py + 7;
    obs.clear();
    trail.clear();
    dead = false;
    started = true;
    deadTimer = 0;
    _musicRestart().then((_) => _musicSync());
    _playSfx(_startBytes);
  }

  void _spawnColumn() {
    final sc = dist / 12;
    final pd = ((sc - 100) / 1400).clamp(0.0, 1.0).toDouble();
    final pn = ((sc - 150) / 1200).clamp(0.0, 1.0).toDouble();
    final nar = narrowAt(dist + kW + 16);
    final yMin = 30 + nar + 4;
    final yMax = kH - 6 - nar - 20;
    final gapHalf = 22 - 4 * pn;
    final gMin = 30 + nar + gapHalf + 2;
    final gMax = kH - 6 - nar - gapHalf - 2;
    gc = (gc + _rng.nextDouble() * 70 - 35).clamp(gMin, gMax).toDouble();
    final want = 1 + (pd * 6).round() + (_rng.nextDouble() < 0.35 ? 1 : 0);
    final ys = <double>[];
    int attempts = 0;
    while (ys.length < want && attempts < 40) {
      attempts++;
      final y = yMin + _rng.nextDouble() * (yMax - yMin);
      if (y + 16 > gc - gapHalf && y < gc + gapHalf) continue;
      if (ys.any((o) => (o - y).abs() < 13)) continue;
      ys.add(y);
      obs.add(Obstacle(kW + 16 + _rng.nextDouble() * 14 - 7, y));
    }
  }

  void _crash() {
    dead = true;
    deadTimer = 0;
    vy = 0;
    if (score > best) best = score.toDouble();
    _musicSync();
    _playSfx(_crashBytes);
  }

  void _update(double dt) {
    t += dt;
    if (dead) {
      deadTimer += dt;
      return;
    }
    if (!started || menu != 0) return;

    final target = holding ? -maxVy : maxVy;
    vy += (target - vy) * min(1.0, dt * 6);
    py += vy * dt;

    final pd = ((score - 100) / 1400).clamp(0.0, 1.0).toDouble();
    final speed = 68 + min(60.0, score * 0.04);
    final move = speed * dt;
    dist += move;

    trail.add(Offset(px + 2, py + 14));
    for (int i = 0; i < trail.length; i++) {
      trail[i] = Offset(trail[i].dx - move, trail[i].dy);
    }
    trail.removeWhere((p) => p.dx < -4);

    for (final o in obs) {
      o.x -= move;
    }
    obs.removeWhere((o) => o.x < -20);
    nextSpawn -= move;
    if (nextSpawn <= 0) {
      _spawnColumn();
      nextSpawn = max(40.0, 72 - 30 * pd);
    }

    // smaller hit boxes: rider's board vs. the tree trunk only
    final pl = Rect.fromLTWH(px + 3, py + 8, 5, 6);
    for (final o in obs) {
      final tr = Rect.fromLTWH(o.x + 4, o.y + 10, 5, 5);
      if (pl.overlaps(tr)) {
        _crash();
        return;
      }
    }
    final wx = dist + px + 5;
    if (py + 5 < topRidge(wx) - 1 || py + 14 > bottomRidge(wx) + 1) {
      _crash();
    }
  }

  void _down() {
    if (menu != 0) return;
    if (dead) {
      if (deadTimer > 0.8) _reset();
      return;
    }
    if (!started) _reset();
    holding = true;
  }

  void _up() {
    holding = false;
  }

  // ---------------------------------------------------------- UI pieces
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String _dateStr() {
    final n = DateTime.now();
    final h = n.hour % 12 == 0 ? 12 : n.hour % 12;
    final m = n.minute.toString().padLeft(2, '0');
    return '${_months[n.month - 1]} ${n.day}, $h:$m ${n.hour < 12 ? 'am' : 'pm'}';
  }

  Widget _outlined(String s, double fs) {
    return Stack(children: [
      Text(s,
          style: TextStyle(
            fontSize: fs,
            fontWeight: FontWeight.w900,
            decoration: TextDecoration.none,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = fs * 0.28
              ..strokeJoin = StrokeJoin.round
              ..color = const Color(0xFF2A3350),
          )),
      Text(s,
          style: TextStyle(
            fontSize: fs,
            fontWeight: FontWeight.w900,
            decoration: TextDecoration.none,
            color: Colors.white,
          )),
    ]);
  }

  Widget _banner() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: 17 * u,
      child: Container(
        color: const Color(0xFF93A9EE),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              width: 48 * u,
              height: 15 * u,
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFF5568C8),
                  borderRadius:
                      BorderRadius.only(bottomRight: Radius.circular(5 * u)),
                ),
                child: _outlined('SnowBored', 7.2 * u),
              ),
            ),
            Positioned(
              left: 52 * u,
              top: 2.2 * u,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _openMenu,
                child: Container(
                  width: 12 * u,
                  height: 12 * u,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF5568C8),
                    borderRadius: BorderRadius.circular(2.5 * u),
                    border: Border.all(color: Colors.white70, width: 0.6 * u),
                  ),
                  child: Icon(Icons.pause, size: 8 * u, color: Colors.white),
                ),
              ),
            ),
            Positioned(
              right: 3 * u,
              top: 1.2 * u,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_dateStr(),
                      style: TextStyle(
                        fontSize: 5.2 * u,
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF1F2A6B),
                        decoration: TextDecoration.none,
                      )),
                  SizedBox(height: 0.8 * u),
                  CustomPaint(
                    size: Size(40 * u, 6 * u),
                    painter: _StatusPainter(bars, batteryLevel, u),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _msg(String title, String body) {
    const shadow = [Shadow(color: Colors.white, blurRadius: 6)];
    return Positioned.fill(
      child: Padding(
        padding: EdgeInsets.only(top: 20 * u),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: TextStyle(
                    fontSize: 12 * u,
                    fontWeight: FontWeight.w900,
                    color: const Color(0xFF223344),
                    decoration: TextDecoration.none,
                    shadows: shadow,
                  )),
              SizedBox(height: 3 * u),
              Text(body,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 6.5 * u,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF334455),
                    decoration: TextDecoration.none,
                    shadows: shadow,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _btn(String label, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        height: 10 * u,
        margin: EdgeInsets.only(bottom: 2 * u),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF5568C8),
          borderRadius: BorderRadius.circular(2 * u),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 5.6 * u,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              decoration: TextDecoration.none,
            )),
      ),
    );
  }

  Widget _menuPanel() {
    final items = <Widget>[];
    String title;
    if (menu == 1) {
      title = 'PAUSED';
      items.add(_btn('Resume', _closeMenu));
      items.add(_btn('Settings', () => setState(() => menu = 2)));
    } else {
      title = 'SETTINGS';
      items.add(_btn('Music: ${musicOn ? 'ON' : 'OFF'}', () => _setMusic(!musicOn)));
      items.add(_btn('Sound FX: ${sfxOn ? 'ON' : 'OFF'}', () => _setSfx(!sfxOn)));
      items.add(_btn('Screen: ${portraitPref ? 'Portrait' : 'Landscape'}',
          () => _setPortrait(!portraitPref)));
      items.add(_btn('Back', () => setState(() => menu = 1)));
    }
    return Positioned.fill(
      child: Container(
        color: const Color(0x66000000),
        child: Center(
          child: Container(
            width: 120 * u,
            padding: EdgeInsets.all(5 * u),
            decoration: BoxDecoration(
              color: const Color(0xFFEAF0FF),
              borderRadius: BorderRadius.circular(4 * u),
              border: Border.all(color: const Color(0xFF5568C8), width: 1.2 * u),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: TextStyle(
                      fontSize: 7.5 * u,
                      fontWeight: FontWeight.w900,
                      color: const Color(0xFF1F2A6B),
                      decoration: TextDecoration.none,
                    )),
                SizedBox(height: 3 * u),
                ...items,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _screen(double sw, double sh) {
    u = sw / kW;
    return SizedBox(
      width: sw,
      height: sh,
      child: Stack(
        children: [
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => _down(),
              onPointerUp: (_) => _up(),
              onPointerCancel: (_) => _up(),
              child: CustomPaint(painter: _Painter(this)),
            ),
          ),
          Positioned(
            top: 19 * u,
            right: 4 * u,
            child: Text('Score: $score',
                style: TextStyle(
                  fontSize: 6.5 * u,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF3A3F4F),
                  decoration: TextDecoration.none,
                )),
          ),
          _banner(),
          if (!started)
            _msg('Drop in!', 'Hold to go up\nRelease to go down\n\nTap to start'),
          if (dead)
            _msg('Wipeout!',
                'Score: $score\nBest: ${best.floor()}\n\nTap to retry'),
          if (menu != 0) _menuPanel(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final portrait = MediaQuery.of(context).orientation == Orientation.portrait;
    Widget lid = AspectRatio(
      aspectRatio: kLidAspect,
      child: LayoutBuilder(builder: (context, cs) {
        final lw = cs.maxWidth;
        final lh = cs.maxHeight;
        final sw = lw * kScreenW;
        final sh = sw / 1.5;
        return Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _LidPainter())),
            Positioned(
              left: lw * kScreenLeft,
              top: lh * kScreenTop,
              width: sw,
              height: sh,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(lh * 0.01),
                child: _screen(sw, sh),
              ),
            ),
          ],
        );
      }),
    );
    if (portrait) {
      lid = RotatedBox(quarterTurns: 3, child: lid);
    }
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0E),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Center(child: lid),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ painters
class _StatusPainter extends CustomPainter {
  final int bars;
  final int battery;
  final double u;
  _StatusPainter(this.bars, this.battery, this.u);

  @override
  void paint(Canvas c, Size s) {
    c.save();
    c.scale(u);
    const inkC = Color(0xFF1F2A6B);
    final ink = Paint()..color = inkC;
    final dim = Paint()..color = const Color(0x551F2A6B);
    // "7" glyph
    final g = Paint()
      ..color = inkC
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    c.drawPath(
        Path()
          ..moveTo(1, 1.2)
          ..lineTo(5, 1.2)
          ..lineTo(2.6, 5.6),
        g);
    // signal bars
    for (int i = 0; i < 4; i++) {
      final h = 1.8 + i * 1.3;
      c.drawRect(
          Rect.fromLTWH(8 + i * 2.6, 6 - h, 1.8, h), i < bars ? ink : dim);
    }
    // battery
    const bx = 21.0;
    c.drawRect(
        Rect.fromLTWH(bx, 0.8, 15, 4.8),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = inkC);
    final segs = min(5, (battery / 20).ceil());
    for (int i = 0; i < 5; i++) {
      c.drawRect(Rect.fromLTWH(bx + 1.2 + i * 2.6, 1.9, 2.0, 2.6),
          i < segs ? ink : dim);
    }
    c.drawRect(Rect.fromLTWH(bx + 15, 2.2, 1.2, 2.0), ink);
    c.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

class _LidPainter extends CustomPainter {
  void _text(Canvas c, TextSpan span, Offset at, double rot) {
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout();
    c.save();
    c.translate(at.dx, at.dy);
    c.rotate(rot);
    tp.paint(c, Offset(-tp.width / 2, -tp.height / 2));
    c.restore();
  }

  @override
  void paint(Canvas c, Size s) {
    final w = s.width;
    final h = s.height;
    final rect = Offset.zero & s;

    // silver shell
    c.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(h * 0.07)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFE2E5EA), Color(0xFFA2A7AE), Color(0xFFC9CDD3)],
        ).createShader(rect),
    );

    // black glossy bezel
    final inner =
        RRect.fromLTRBR(w * 0.012, h * 0.055, w * 0.988, h * 0.884, Radius.circular(h * 0.045));
    c.drawRRect(
      inner,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF26262B), Color(0xFF0B0B0D), Color(0xFF141417)],
        ).createShader(rect),
    );
    // bottom lip highlight
    c.drawLine(
        Offset(w * 0.03, h * 0.89),
        Offset(w * 0.97, h * 0.89),
        Paint()
          ..color = const Color(0xAAFFFFFF)
          ..strokeWidth = h * 0.004);

    // screen rim
    final sl = w * kScreenLeft;
    final st = h * kScreenTop;
    final sw = w * kScreenW;
    final sh = sw / 1.5;
    final rim = RRect.fromLTRBR(sl - h * 0.008, st - h * 0.008,
        sl + sw + h * 0.008, st + sh + h * 0.008, Radius.circular(h * 0.016));
    c.drawRRect(rim, Paint()..color = const Color(0xFF050507));
    c.drawRRect(
        rim,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = h * 0.003
          ..color = const Color(0xFF3A3A42));

    // camera dot
    final cam = Offset(w * 0.897, h * 0.43);
    c.drawCircle(cam, w * 0.013, Paint()..color = const Color(0xFF55555C));
    c.drawCircle(cam, w * 0.010, Paint()..color = const Color(0xFF1B1B20));
    c.drawCircle(cam.translate(-w * 0.003, -w * 0.003), w * 0.003,
        Paint()..color = const Color(0xFF8A8A95));

    // T-Mobile (reads top to bottom)
    final tm = TextSpan(children: [
      TextSpan(
          text: 'T',
          style: TextStyle(
              fontSize: h * 0.085,
              fontWeight: FontWeight.w700,
              color: const Color(0xFFE20074))),
      TextSpan(
          text: ' · · Mobile ·',
          style: TextStyle(
              fontSize: h * 0.085,
              fontWeight: FontWeight.w500,
              color: const Color(0xFFD7D7DC))),
    ]);
    _text(c, tm, Offset(w * 0.095, h * 0.46), pi / 2);

    // sidekick logos (right normal, left upside-down like the real lid)
    TextSpan logo() => TextSpan(
        text: 'sidekick',
        style: TextStyle(
            fontSize: h * 0.05,
            fontWeight: FontWeight.w800,
            letterSpacing: h * 0.002,
            color: const Color(0xFFD0D0D6)));
    _text(c, logo(), Offset(w * 0.77, h * 0.815), 0);
    _text(c, logo(), Offset(w * 0.27, h * 0.815), pi);

    // thin trim line under the screen
    final trim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = h * 0.004
      ..color = const Color(0xFF55555C);
    c.drawPath(
        Path()
          ..moveTo(w * 0.19, h * 0.862)
          ..lineTo(w * 0.5, h * 0.862)
          ..lineTo(w * 0.54, h * 0.835)
          ..lineTo(w * 0.81, h * 0.835),
        trim);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _Painter extends CustomPainter {
  final _SnowBoredState s;
  _Painter(this.s);

  void _star(Canvas c, double x, double y, Color col) {
    final p = Paint()
      ..color = col
      ..isAntiAlias = false;
    c.drawRect(Rect.fromLTWH(x - 1, y, 3, 1), p);
    c.drawRect(Rect.fromLTWH(x, y - 1, 1, 3), p);
  }

  @override
  void paint(Canvas c, Size size) {
    c.save();
    c.scale(s.u);
    c.clipRect(const Rect.fromLTWH(0, 0, kW, kH));

    final p = Paint()..isAntiAlias = false;

    // snow
    p.color = const Color(0xFFF1F3FA);
    c.drawRect(const Rect.fromLTWH(0, 0, kW, kH), p);
    p.color = const Color(0xFFE6EAF5);
    for (double y = 0; y < kH; y += 3) {
      c.drawRect(Rect.fromLTWH(0, y, kW, 1), p);
    }

    // ridges (top + bottom), narrowing with distance
    final topFill = Path()..moveTo(0, 0);
    final botFill = Path()..moveTo(0, kH);
    final topLine = Path();
    final botLine = Path();
    final topLine2 = Path();
    final botLine2 = Path();
    bool first = true;
    for (double x = 0; x <= kW + 2; x += 2) {
      final wx = s.dist + x;
      final ty = s.topRidge(wx);
      final by = s.bottomRidge(wx);
      topFill.lineTo(x, ty);
      botFill.lineTo(x, by);
      if (first) {
        topLine.moveTo(x, ty);
        botLine.moveTo(x, by);
        topLine2.moveTo(x, ty + 2.5);
        botLine2.moveTo(x, by - 2.5);
        first = false;
      } else {
        topLine.lineTo(x, ty);
        botLine.lineTo(x, by);
        topLine2.lineTo(x, ty + 2.5);
        botLine2.lineTo(x, by - 2.5);
      }
    }
    topFill
      ..lineTo(kW, 0)
      ..close();
    botFill
      ..lineTo(kW, kH)
      ..close();
    final fill = Paint()..color = const Color(0xFFDCE6F7);
    c.drawPath(topFill, fill);
    c.drawPath(botFill, fill);
    final light = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFF9DBCEF);
    final blue = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFF2C7BE5);
    c.drawPath(topLine2, light);
    c.drawPath(botLine2, light);
    c.drawPath(topLine, blue);
    c.drawPath(botLine, blue);

    // board trail
    if (s.trail.length > 1) {
      final tp = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = const Color(0xFFBCC8E0);
      final path = Path()..moveTo(s.trail[0].dx, s.trail[0].dy);
      for (int i = 1; i < s.trail.length; i++) {
        path.lineTo(s.trail[i].dx, s.trail[i].dy);
      }
      c.drawPath(path, tp);
    }

    // trees + rider, depth-sorted
    final sorted = [...s.obs]..sort((a, b) => a.y.compareTo(b.y));
    final riderBase = s.py + 14;
    bool riderDrawn = false;
    void drawRider() {
      if (s.dead) {
        _sprite(c, _crashed, s.px - 2, s.py + 8, p);
        for (int k = 0; k < 3; k++) {
          final a = s.t * 5 + k * 2.1;
          _star(c, s.px + 3 + cos(a) * 7, s.py + 4 + sin(a) * 2.5,
              k.isEven ? const Color(0xFFE060A0) : const Color(0xFFE8B030));
        }
      } else {
        _sprite(c, _rider, s.px, s.py, p);
      }
      riderDrawn = true;
    }

    for (final o in sorted) {
      if (!riderDrawn && o.y + 16 > riderBase) drawRider();
      _sprite(c, _tree, o.x, o.y, p);
    }
    if (!riderDrawn) drawRider();

    c.restore();
  }

  @override
  bool shouldRepaint(covariant _Painter old) => true;
}
