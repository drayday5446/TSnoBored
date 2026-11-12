import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ------------------------------------------------------------ tuning
const double kH = 128; // game height in logical pixel-art units
const double kTop = 38; // top of the playable mountain (below the sky)
const double kJumpTime = 0.55;

// Screen rectangle inside the lid (thin Sidekick bezel), relative to lid height.
Rect _screenRect(double lw, double lh) =>
    Rect.fromLTRB(0.075 * lh, 0.030 * lh, lw - 0.050 * lh, lh - 0.062 * lh);

double _cl(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
double _wrap(double v, double m) => ((v % m) + m) % m;
double _tanh(double x) {
  final v = x.clamp(-8.0, 8.0).toDouble();
  final e = exp(2 * v);
  return (e - 1) / (e + 1);
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: SnowBored(),
  ));
}

// ------------------------------------------------------------ audio synth
Uint8List _genMusic(int _) => Synth.music();

class Synth {
  static const int sr = 22050;

  static double _hz(int m) => 440.0 * pow(2, (m - 69) / 12.0);
  static double _sq(double ph, double duty) => (ph % 1.0) < duty ? 1.0 : -1.0;
  static double _tw(double ph) => 4 * ((ph % 1.0) - 0.5).abs() - 1.0;

  static Uint8List wav(List<double> s, [int rate = sr]) {
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
    b.setUint32(24, rate, Endian.little);
    b.setUint32(28, rate * 2, Endian.little);
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

  // Rock loop: distorted power chords, bass guitar, lead guitar, drum kit.
  static Uint8List music() {
    const rate = 44100;
    const roots = [40, 48, 43, 50, 40, 48, 43, 50];
    const lead = [
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      76, 0, 79, 76, 83, 0, 81, 79, 84, 0, 83, 81, 79, 0, 76, 79,
      79, 0, 83, 79, 86, 0, 83, 79, 78, 0, 81, 78, 86, 0, 85, 81,
    ];
    final spn = (0.1 * rate).round(); // one sixteenth at 150 bpm
    const steps = 128;
    final total = spn * steps;
    final out = List<double>.filled(total, 0.0);
    final rng = Random(11);
    double gp1 = 0, gp2 = 0, gp3 = 0, bp = 0, lp = 0, glp = 0, prevN = 0;
    for (int i = 0; i < total; i++) {
      final st = i ~/ spn;
      final bar = st ~/ 16;
      final sb = st % 16;
      final t = (i % spn) / rate;
      final e = st ~/ 2;
      final eb = e % 8;
      final tt = (i % (spn * 2)) / rate;
      final root = roots[bar];
      final n = rng.nextDouble() * 2 - 1;
      final hp = n - prevN;
      prevN = n;

      // rhythm guitar (palm-muted chugs, accents ring out)
      gp1 += _hz(root) / rate;
      gp2 += _hz(root + 7) / rate;
      gp3 += _hz(root + 12) / rate;
      final raw = ((gp1 % 1) * 2 - 1) +
          0.8 * ((gp2 % 1) * 2 - 1) +
          0.6 * ((gp3 % 1) * 2 - 1);
      final accent = (eb == 0 || eb == 4);
      final genv = accent ? exp(-tt * 3.5) : exp(-tt * 16);
      final driven = _tanh(raw * 1.4);
      glp += (driven - glp) * 0.3;
      double v = glp * genv * 0.5;

      // bass guitar
      bp += _hz(root - 12) / rate;
      v += (0.6 * _tw(bp) + 0.4 * ((bp % 1) * 2 - 1)) *
          0.3 *
          (0.4 + 0.6 * exp(-tt * 6));

      // lead guitar with vibrato (second half of the loop)
      final lm = lead[e];
      if (lm > 0) {
        lp += _hz(lm) * (1 + 0.012 * sin(2 * pi * 5.5 * i / rate)) / rate;
        v += _tanh(((lp % 1) * 2 - 1) * 3) * 0.18 * exp(-tt * 2.2);
      }

      // drums
      if (sb == 0 || sb == 8 || sb == 10) {
        v += 0.55 *
            sin(2 * pi * (50 * t + (120 / 25) * (1 - exp(-25 * t)))) *
            exp(-t * 11);
      }
      if (sb == 4 || sb == 12) {
        v += n * 0.35 * exp(-t * 14) + sin(2 * pi * 190 * t) * 0.22 * exp(-t * 22);
      }
      if (sb % 2 == 0) v += hp * 0.10 * exp(-t * 55);
      if (sb == 14) v += hp * 0.09 * exp(-t * 20);
      if (bar % 4 == 0) {
        final tb = (i % (spn * 16)) / rate;
        v += hp * 0.12 * exp(-tb * 2.6);
      }
      out[i] = v;
    }
    double peak = 0;
    for (final v in out) {
      if (v.abs() > peak) peak = v.abs();
    }
    final g = peak > 0 ? 0.88 / peak : 1.0;
    for (int i = 0; i < total; i++) {
      out[i] *= g;
    }
    return wav(out, rate);
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

  // quick rising blip for hitting a jump
  static Uint8List jump() {
    final n = (0.28 * sr).round();
    final out = List<double>.filled(n, 0.0);
    double ph = 0;
    for (int i = 0; i < n; i++) {
      final t = i / sr;
      ph += (260 + 900 * (t / 0.28)) / sr;
      out[i] = _sq(ph, 0.25) * 0.3 * (1 - t / 0.28);
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
  'N': Color(0xFFA0723E),
  'c': Color(0xFFD9B382),
  'S': Color(0xFFA9C1E6),
  'E': Color(0xFF9DB5E0),
  'O': Color(0xFFE8601C),
  'K': Color(0xFFF2C9A0),
  'B': Color(0xFF2F6FD0),
  'b': Color(0xFF1F4F9A),
  'P': Color(0xFF3A3F66),
  'Y': Color(0xFFE8B030),
  'R': Color(0xFFB86A10),
  'X': Color(0xFF222222),
  'M': Color(0xFF7A828C),
  'm': Color(0xFF555C66),
  'h': Color(0xFFA5ADB8),
  'F': Color(0xFFE8302C),
  'f': Color(0xFFF4B820),
  'p': Color(0xFF55555C),
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

const List<String> _rock = [
  '...hhh...',
  '..hhMMM..',
  '.hMMMMMM.',
  'hMMMMMMmm',
  'MMMMMMmmm',
  '.mmmmmmm.',
];

const List<String> _log = [
  '.TTTTTTTTTTTT.',
  'cNNNNNNNNNNNNT',
  'cNNNNNNNNNNNNT',
  '.TTTTTTTTTTTT.',
];

const List<String> _mound = [
  '.....EEEEEE.....',
  '...EEWWWWWWEE...',
  '..EWWWWWWWWWWE..',
  '.EWWWWWWWWWWWWE.',
  'ESSSSSSSSSSSSSSE',
];

List<String> _flag(String ch) => [
      'p$ch$ch$ch$ch',
      'p$ch$ch$ch.',
      'p$ch$ch..',
      'p....',
      'p....',
      'p....',
      'p....',
      'p....',
    ];

final List<List<String>> _flags = [_flag('F'), _flag('f'), _flag('B')];

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

List<String> _spriteFor(int kind) {
  switch (kind) {
    case 1:
      return _rock;
    case 2:
      return _log;
    case 3:
      return _mound;
    default:
      return _tree;
  }
}

double _kh(int kind) => _spriteFor(kind).length.toDouble();

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
  int kind; // 0 tree, 1 rock, 2 log, 3 jump mound
  Obstacle(this.x, this.y, this.kind);
}

class Decor {
  double wx; // world x
  int kind;
  Decor(this.wx, this.kind);
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
  Uint8List? _musicBytes;
  late final Uint8List _startBytes;
  late final Uint8List _crashBytes;
  late final Uint8List _jumpBytes;
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
  double u = 6; // screen px per logical px
  double W = 256; // logical width (depends on screen shape)

  // state
  bool holding = false;
  bool dead = false;
  bool started = false;
  int menu = 0; // 0 none, 1 pause, 2 settings
  double deadTimer = 0;
  double t = 0;

  double py = 70;
  double vy = 0;
  double dist = 0;
  double airT = 0;
  int bonus = 0;
  int flatCols = 0;
  double best = 0;
  double nextSpawn = 90;
  double gc = 77;
  final List<Obstacle> obs = [];
  final List<Decor> decor = [];
  final List<Offset> trail = [];

  static const double maxVy = 58;
  double get px => W * 0.18;
  int get score => (dist / 12).floor() + bonus;

  // mountain narrows quickly: tight by ~200 points
  double narrowAt(double wx) => min(18.0, max(0.0, wx / 12 - 60) * 0.12);
  double topRidge(double wx) =>
      kTop + narrowAt(wx) + 3 * _tri(wx / 26) + 1.5 * _tri(wx / 10);
  double bottomRidge(double wx) =>
      kH -
      6 -
      narrowAt(wx) -
      3 * _tri((wx + 11) / 24) -
      1.5 * _tri((wx + 3) / 10);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startBytes = Synth.start();
    _crashBytes = Synth.crash();
    _jumpBytes = Synth.jump();
    compute(_genMusic, 0).then((b) {
      _musicBytes = b;
      _musicSync();
    });
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

  // One orientation each way so the real camera lines up with the lid camera.
  void _applyOrientation() {
    SystemChrome.setPreferredOrientations(portraitPref
        ? [DeviceOrientation.portraitUp]
        : [DeviceOrientation.landscapeRight]);
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
          final mb = _musicBytes;
          if (mb == null) return;
          await _music.setReleaseMode(ReleaseMode.loop);
          await _music.setVolume(0.5);
          await _music.play(BytesSource(mb, mimeType: 'audio/wav'));
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
    py = 70;
    vy = 0;
    dist = 0;
    airT = 0;
    bonus = 0;
    flatCols = 0;
    nextSpawn = 90;
    gc = py + 7;
    obs.clear();
    decor.clear();
    trail.clear();
    dead = false;
    started = true;
    deadTimer = 0;
    _musicRestart().then((_) => _musicSync());
    _playSfx(_startBytes);
  }

  void _spawnColumn() {
    final sc = dist / 12;
    final pd = _cl((sc - 30) / 190); // tree density: full by ~220
    final pn = _cl((sc - 60) / 150); // tighter gap
    final nar = narrowAt(dist + W + 16);
    final gapHalf = 22 - 4 * pn;
    final gMin = kTop + nar + gapHalf + 2;
    final gMax = kH - 6 - nar - gapHalf - 2;
    if (flatCols > 0) {
      flatCols--;
    } else {
      gc = gc + _rng.nextDouble() * 70 - 35;
    }
    gc = gc.clamp(gMin, gMax).toDouble();

    final want = 1 + (pd * 6).round() + (_rng.nextDouble() < 0.35 ? 1 : 0);
    final rockP = _cl((sc - 90) / 150) * 0.35;
    final logP = _cl((sc - 130) / 120) * 0.2;
    final ys = <double>[];
    int attempts = 0;
    while (ys.length < want && attempts < 40) {
      attempts++;
      final r = _rng.nextDouble();
      final kind = r < logP ? 2 : (r < logP + rockP ? 1 : 0);
      final hk = _kh(kind);
      final yMin = kTop + nar + 4;
      final yMax = kH - 6 - nar - hk - 4;
      final y = yMin + _rng.nextDouble() * (yMax - yMin);
      if (y + hk > gc - gapHalf && y < gc + gapHalf) continue;
      if (ys.any((o) => (o - y).abs() < 13)) continue;
      ys.add(y);
      obs.add(Obstacle(W + 16 + _rng.nextDouble() * 14 - 7, y, kind));
    }

    // little snow hills that launch you (locks steering for a moment)
    final moundP = sc < 40 ? 0.0 : (0.22 + 0.18 * pd);
    if (_rng.nextDouble() < moundP) {
      final lo = kTop + nar + 4;
      final hi = kH - 6 - nar - 5 - 4;
      final my = (gc - 3 + _rng.nextDouble() * 14 - 7).clamp(lo, hi).toDouble();
      obs.add(Obstacle(W + 16 + 22 + _rng.nextDouble() * 10, my, 3));
      flatCols = 2; // keep the path straight after a jump
    }

    // little flags on the far snow
    if (_rng.nextDouble() < 0.28) {
      decor.add(Decor(dist + W + 20 + _rng.nextDouble() * 40, _rng.nextInt(3)));
    }
  }

  void _crash() {
    dead = true;
    deadTimer = 0;
    vy = 0;
    airT = 0;
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

    final sc = dist / 12;
    final air = airT > 0;
    if (air) {
      airT -= dt;
      vy -= vy * min(1.0, dt * 2.0);
    } else {
      final target = holding ? -maxVy : maxVy;
      vy += (target - vy) * min(1.0, dt * 6);
    }
    py += vy * dt;

    final speed = 68 + min(70.0, sc * 0.12);
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
    obs.removeWhere((o) => o.x < -24);
    decor.removeWhere((d) => d.wx - dist < -12);
    nextSpawn -= move;
    if (nextSpawn <= 0) {
      _spawnColumn();
      nextSpawn = max(40.0, 72 - 30 * _cl((sc - 30) / 190));
    }

    // hit boxes are small: only the part that visibly touches counts
    final pl = Rect.fromLTWH(px + 3, py + 8, 5, 6);
    final flying = airT > 0;
    for (final o in obs) {
      Rect tr;
      switch (o.kind) {
        case 1:
          if (flying) continue;
          tr = Rect.fromLTWH(o.x + 1, o.y + 2, 7, 4);
          break;
        case 2:
          if (flying) continue;
          tr = Rect.fromLTWH(o.x, o.y + 0.5, 14, 3);
          break;
        case 3:
          if (flying) continue;
          tr = Rect.fromLTWH(o.x + 2, o.y + 1, 12, 4);
          if (pl.overlaps(tr)) {
            airT = kJumpTime;
            bonus += 5;
            _playSfx(_jumpBytes);
          }
          continue;
        default:
          tr = Rect.fromLTWH(o.x + 4, o.y + 10, 5, 5);
      }
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

  Widget _pauseButton() {
    return Positioned(
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
    u = sh / kH;
    W = sw / u;
    return SizedBox(
      width: sw,
      height: sh,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(child: CustomPaint(painter: _Painter(this))),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Stack(
                children: [
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
                    _msg('Drop in!',
                        'Hold to go up\nRelease to go down\n\nTap anywhere to start'),
                  if (dead)
                    _msg('Wipeout!',
                        'Score: $score\nBest: ${best.floor()}\n\nTap to retry'),
                ],
              ),
            ),
          ),
          _pauseButton(),
          if (menu != 0) _menuPanel(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final portrait = MediaQuery.of(context).orientation == Orientation.portrait;
    Widget lid = LayoutBuilder(builder: (context, cs) {
      final lw = cs.maxWidth;
      final lh = cs.maxHeight;
      final r = _screenRect(lw, lh);
      return Stack(
        children: [
          // the whole lid (bezel included) is the touch surface
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => _down(),
              onPointerUp: (_) => _up(),
              onPointerCancel: (_) => _up(),
              child: IgnorePointer(child: CustomPaint(painter: _LidPainter())),
            ),
          ),
          Positioned.fromRect(
            rect: r,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(lh * 0.008),
              child: _screen(r.width, r.height),
            ),
          ),
        ],
      );
    });
    if (portrait) {
      lid = RotatedBox(quarterTurns: 3, child: lid);
    }
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0E),
      body: SizedBox.expand(child: lid),
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
    for (int i = 0; i < 4; i++) {
      final h = 1.8 + i * 1.3;
      c.drawRect(
          Rect.fromLTWH(8 + i * 2.6, 6 - h, 1.8, h), i < bars ? ink : dim);
    }
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
    final lw = s.width;
    final lh = s.height;
    final rect = Offset.zero & s;
    final rimW = lh * 0.008;

    // thin silver sliver
    c.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(lh * 0.05)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFE2E5EA), Color(0xFFA2A7AE), Color(0xFFC9CDD3)],
        ).createShader(rect),
    );

    // black glossy bezel
    c.drawRRect(
      RRect.fromLTRBR(rimW, rimW, lw - rimW, lh - rimW, Radius.circular(lh * 0.042)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF26262B), Color(0xFF0B0B0D), Color(0xFF141417)],
        ).createShader(rect),
    );

    // screen rim
    final sr = _screenRect(lw, lh);
    final rim = RRect.fromRectAndRadius(
        sr.inflate(lh * 0.004), Radius.circular(lh * 0.012));
    c.drawRRect(rim, Paint()..color = const Color(0xFF050507));
    c.drawRRect(
        rim,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = lh * 0.002
          ..color = const Color(0xFF3A3A42));

    // camera dot (right edge, center)
    final cam = Offset(lw - lh * 0.027, lh * 0.5);
    c.drawCircle(cam, lh * 0.012, Paint()..color = const Color(0xFF55555C));
    c.drawCircle(cam, lh * 0.0092, Paint()..color = const Color(0xFF1B1B20));
    c.drawCircle(cam.translate(-lh * 0.003, -lh * 0.003), lh * 0.0028,
        Paint()..color = const Color(0xFF8A8A95));

    // T-Mobile on the left bezel (reads top to bottom)
    final tm = TextSpan(children: [
      TextSpan(
          text: 'T',
          style: TextStyle(
              fontSize: lh * 0.030,
              fontWeight: FontWeight.w700,
              color: const Color(0xFFE20074))),
      TextSpan(
          text: ' · · Mobile ·',
          style: TextStyle(
              fontSize: lh * 0.030,
              fontWeight: FontWeight.w500,
              color: const Color(0xFFD7D7DC))),
    ]);
    _text(c, tm, Offset(lh * 0.040, lh * 0.5), pi / 2);

    // small sidekick logos on the bottom bezel
    TextSpan logo() => TextSpan(
        text: 'sidekick',
        style: TextStyle(
            fontSize: lh * 0.028,
            fontWeight: FontWeight.w800,
            letterSpacing: lh * 0.001,
            color: const Color(0xFFD0D0D6)));
    final by = lh - (lh * 0.062 + rimW) / 2 - rimW * 0.4;
    _text(c, logo(), Offset(lw * 0.74, by), 0);
    _text(c, logo(), Offset(lw * 0.26, by), pi);
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

  void _mtn(Canvas c, double w, double off, double base, double a1, double a2,
      Color col) {
    final pth = Path()..moveTo(0, 70);
    for (double x = 0; x <= w + 2; x += 2) {
      final wx = off + x;
      pth.lineTo(x, base + a1 * _tri(wx / 46) + a2 * _tri(wx / 17 + 0.3));
    }
    pth
      ..lineTo(w + 2, 70)
      ..close();
    c.drawPath(pth, Paint()..color = col);
  }

  @override
  void paint(Canvas c, Size size) {
    final W = s.W;
    c.save();
    c.scale(s.u);
    c.clipRect(Rect.fromLTWH(0, 0, W, kH));

    final p = Paint()..isAntiAlias = false;

    // snow field
    p.color = const Color(0xFFF1F3FA);
    c.drawRect(Rect.fromLTWH(0, 0, W, kH), p);
    p.color = const Color(0xFFE6EAF5);
    for (double y = 0; y < kH; y += 3) {
      c.drawRect(Rect.fromLTWH(0, y, W, 1), p);
    }

    // ridge samples
    final xs = <double>[];
    final tops = <double>[];
    final bots = <double>[];
    for (double x = 0; x <= W + 2; x += 2) {
      xs.add(x);
      tops.add(s.topRidge(s.dist + x));
      bots.add(s.bottomRidge(s.dist + x));
    }

    // ---- sky above the far mountain edge
    final skyPath = Path()..moveTo(0, 0);
    for (int i = 0; i < xs.length; i++) {
      skyPath.lineTo(xs[i], tops[i] - 7);
    }
    skyPath
      ..lineTo(xs.last, 0)
      ..close();
    c.drawPath(
      skyPath,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF9CC4F2), Color(0xFFE4EFFC)],
        ).createShader(Rect.fromLTWH(0, 0, W, 60)),
    );
    c.save();
    c.clipPath(skyPath);
    // distant mountains (parallax)
    _mtn(c, W, s.dist * 0.2, 22, 6, 3, const Color(0xFFD5E2F6));
    _mtn(c, W, s.dist * 0.4 + 30, 26, 5, 2.5, const Color(0xFFC1D1EC));
    // clouds
    final cp = Paint()
      ..color = const Color(0xE6FFFFFF)
      ..isAntiAlias = false;
    for (int k = 0; k < 5; k++) {
      final cx = _wrap(k * 71.0 + 40 - s.dist * 0.15 - s.t * 2, W + 80) - 40;
      final cy = 19.0 + ((k * 5) % 9);
      c.drawRect(Rect.fromLTWH(cx - 10, cy + 1, 20, 3), cp);
      c.drawRect(Rect.fromLTWH(cx - 6, cy - 1, 12, 3), cp);
      c.drawRect(Rect.fromLTWH(cx - 2, cy - 2.5, 6, 2), cp);
    }
    // ski lift
    final off = s.dist * 0.55;
    final cable = Paint()
      ..color = const Color(0xFF5E6674)
      ..strokeWidth = 0.8;
    c.drawLine(Offset(0, 22), Offset(W, 22), cable);
    for (int k = (off / 100).floor(); k <= ((off + W) / 100).ceil() + 1; k++) {
      final x = k * 100.0 - off + 50;
      if (x < -6 || x > W + 6) continue;
      p.color = const Color(0xFF4A4F57);
      c.drawRect(Rect.fromLTWH(x - 0.6, 22, 1.2, 16), p);
      c.drawRect(Rect.fromLTWH(x - 3, 21.4, 6, 1.1), p);
    }
    for (int i = 0; i < 7; i++) {
      final x = _wrap(i * 37.0 - off - s.t * 12, W + 30) - 15;
      p.color = const Color(0xFF4A4F57);
      c.drawRect(Rect.fromLTWH(x - 0.3, 22.4, 0.6, 4.6), p);
      c.drawRect(Rect.fromLTWH(x - 2.5, 24.5, 0.9, 2.5), p);
      p.color = i.isEven ? const Color(0xFFE8302C) : const Color(0xFF2F6FD0);
      c.drawRect(Rect.fromLTWH(x - 2.5, 27, 5, 1.6), p);
    }
    c.restore();

    // ---- snowy far slope band (flags stand on its top edge)
    final band = Path()..moveTo(0, tops[0] - 7);
    for (int i = 0; i < xs.length; i++) {
      band.lineTo(xs[i], tops[i] - 7);
    }
    for (int i = xs.length - 1; i >= 0; i--) {
      band.lineTo(xs[i], tops[i]);
    }
    band.close();
    c.drawPath(band, Paint()..color = const Color(0xFFEAF1FC));
    final edge = Path()..moveTo(xs[0], tops[0] - 7);
    for (int i = 1; i < xs.length; i++) {
      edge.lineTo(xs[i], tops[i] - 7);
    }
    c.drawPath(
        edge,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9
          ..color = const Color(0xFFBBD0F0));

    // flags
    for (final d in s.decor) {
      final sx = d.wx - s.dist;
      final gy = s.topRidge(d.wx) - 7 + 1;
      _sprite(c, _flags[d.kind], sx, gy - 8, p);
    }

    // ---- near ridges (play-area limits)
    final botFill = Path()..moveTo(0, kH);
    final topLine = Path();
    final botLine = Path();
    final topLine2 = Path();
    final botLine2 = Path();
    for (int i = 0; i < xs.length; i++) {
      botFill.lineTo(xs[i], bots[i]);
      if (i == 0) {
        topLine.moveTo(xs[i], tops[i]);
        botLine.moveTo(xs[i], bots[i]);
        topLine2.moveTo(xs[i], tops[i] + 2.5);
        botLine2.moveTo(xs[i], bots[i] - 2.5);
      } else {
        topLine.lineTo(xs[i], tops[i]);
        botLine.lineTo(xs[i], bots[i]);
        topLine2.lineTo(xs[i], tops[i] + 2.5);
        botLine2.lineTo(xs[i], bots[i] - 2.5);
      }
    }
    botFill
      ..lineTo(W, kH)
      ..close();
    c.drawPath(botFill, Paint()..color = const Color(0xFFDCE6F7));
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

    // obstacles + rider, depth-sorted
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
      } else if (s.airT > 0) {
        final f = _cl(1 - s.airT / kJumpTime);
        final rise = sin(pi * f) * 12;
        c.drawOval(
            Rect.fromCenter(
                center: Offset(s.px + 5.5, s.py + 15),
                width: 10 - rise * 0.3,
                height: 2),
            Paint()..color = const Color(0x331A2A5A));
        c.save();
        c.translate(s.px + 5.5, s.py + 7 - rise);
        c.rotate(-f * 2 * pi);
        _sprite(c, _rider, -5.5, -7, p);
        c.restore();
      } else {
        _sprite(c, _rider, s.px, s.py, p);
      }
      riderDrawn = true;
    }

    for (final o in sorted) {
      if (!riderDrawn && o.y + _kh(o.kind) > riderBase) drawRider();
      _sprite(c, _spriteFor(o.kind), o.x, o.y, p);
    }
    if (!riderDrawn) drawRider();

    c.restore();
  }

  @override
  bool shouldRepaint(covariant _Painter old) => true;
}
