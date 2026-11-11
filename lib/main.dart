import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

// Set to false for the original landscape layout.
const bool kPortrait = true;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations(kPortrait
      ? [DeviceOrientation.portraitUp]
      : [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: SnowBored(),
  ));
}

// ---------------------------------------------------------------- sprites
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

// ---------------------------------------------------------------- game
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
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final Random _rng = Random();
  Duration _last = Duration.zero;

  // layout (logical pixel-art units)
  double u = 2.5; // screen px per logical px
  double W = 160, H = 300;

  bool holding = false;
  bool dead = false;
  bool started = false;
  double deadTimer = 0;
  double t = 0;

  double py = 90;
  double vy = 0;
  double dist = 0;
  double best = 0;
  double ridgeScroll = 0;
  double nextSpawn = 140;
  double gc = 100;
  final List<Obstacle> obs = [];
  final List<Offset> trail = [];

  static const double maxVy = 70;
  double get px => W * 0.22;
  int get score => (dist / 12).floor();

  double topRidge(double wx) => 7 + 4 * _tri(wx / 22) + 2 * _tri(wx / 9);
  double bottomRidge(double wx) =>
      H - 8 - 4 * _tri((wx + 11) / 24) - 2 * _tri((wx + 3) / 10);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    double dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt > 0.05) dt = 0.05;
    _update(dt);
    setState(() {});
  }

  void _reset() {
    py = H * 0.3;
    vy = 0;
    dist = 0;
    nextSpawn = 140;
    gc = py + 7;
    obs.clear();
    trail.clear();
    dead = false;
    started = true;
    deadTimer = 0;
  }

  void _spawnColumn() {
    gc = (gc + (_rng.nextDouble() * 80 - 40)).clamp(44.0, H - 44.0).toDouble();
    final n = (H / 60).round() + _rng.nextInt(2);
    for (int i = 0; i < n; i++) {
      final y = 14 + _rng.nextDouble() * (H - 14 - 30);
      if (y + 16 > gc - 24 && y < gc + 24) continue;
      obs.add(Obstacle(W + 16 + _rng.nextDouble() * 16 - 8, y));
    }
  }

  void _crash() {
    dead = true;
    deadTimer = 0;
    vy = 0;
    if (score > best) best = score.toDouble();
  }

  void _update(double dt) {
    t += dt;
    if (dead) {
      deadTimer += dt;
      return;
    }
    if (!started) return;

    final target = holding ? -maxVy : maxVy;
    vy += (target - vy) * min(1.0, dt * 6);
    py += vy * dt;

    final speed = min(135.0, 75 + dist * 0.004);
    final move = speed * dt;
    dist += move;
    ridgeScroll += move;

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
      nextSpawn = max(46.0, 62 - dist * 0.003);
    }

    final pl = Rect.fromLTWH(px + 2, py + 3, 7, 11);
    for (final o in obs) {
      final tr = Rect.fromLTWH(o.x + 3, o.y + 6, 7, 10);
      if (pl.overlaps(tr)) {
        _crash();
        return;
      }
    }
    final wx = ridgeScroll + px + 5;
    if (py + 3 < topRidge(wx) - 1 || py + 14 > bottomRidge(wx) + 1) {
      _crash();
    }
  }

  void _down() {
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

  // ------------------------------------------------------------ UI
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

  Widget _outlined(String s) {
    return Stack(children: [
      Text(s,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            decoration: TextDecoration.none,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 4
              ..color = const Color(0xFF2A3350),
          )),
      Text(s,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            decoration: TextDecoration.none,
            color: Colors.white,
          )),
    ]);
  }

  Widget _banner(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Container(
      height: top + 42,
      padding: EdgeInsets.fromLTRB(12, top, 12, 0),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
            colors: [Color(0xFF7B88A6), Color(0xFFC8D1E3)]),
        border: Border(bottom: BorderSide(color: Color(0xFF66738F), width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: _outlined('SnowBored'))),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_dateStr(),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2A3350),
                    decoration: TextDecoration.none,
                  )),
              const SizedBox(height: 3),
              CustomPaint(size: const Size(60, 11), painter: _StatusPainter()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _msg(String title, String body) {
    const shadow = [Shadow(color: Colors.white, blurRadius: 6)];
    return Positioned.fill(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title,
                style: const TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF223344),
                  decoration: TextDecoration.none,
                  shadows: shadow,
                )),
            const SizedBox(height: 12),
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF334455),
                  decoration: TextDecoration.none,
                  shadows: shadow,
                )),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F3FA),
      body: Column(
        children: [
          _banner(context),
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => _down(),
              onPointerUp: (_) => _up(),
              onPointerCancel: (_) => _up(),
              child: LayoutBuilder(builder: (context, box) {
                final fw = box.maxWidth;
                final fh = box.maxHeight;
                u = kPortrait ? fw / 160 : fh / 130;
                W = fw / u;
                H = fh / u;
                return Stack(
                  children: [
                    Positioned.fill(
                        child: CustomPaint(painter: _Painter(this))),
                    Positioned(
                      top: 10,
                      right: 12,
                      child: Text('Score: $score',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF223344),
                            decoration: TextDecoration.none,
                          )),
                    ),
                    if (!started)
                      _msg('Drop in!',
                          'Hold to go up\nRelease to go down\n\nTap to start'),
                    if (dead)
                      _msg('Wipeout!',
                          'Score: $score\nBest: ${best.floor()}\n\nTap to retry'),
                  ],
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPainter extends CustomPainter {
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()..color = const Color(0xFF2A3350);
    for (int i = 0; i < 4; i++) {
      final h = 3.0 + i * 2.5;
      c.drawRect(Rect.fromLTWH(i * 5.0, s.height - h, 3, h), p);
    }
    const bx = 30.0;
    c.drawRect(
        Rect.fromLTWH(bx, 1, 26, s.height - 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0xFF2A3350));
    c.drawRect(Rect.fromLTWH(bx + 2, 3, 20, s.height - 6), p);
    c.drawRect(Rect.fromLTWH(bx + 26, 4, 2, s.height - 8), p);
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
    final W = s.W;
    final H = s.H;
    c.save();
    c.scale(s.u);
    c.clipRect(Rect.fromLTWH(0, 0, W, H));

    final p = Paint()..isAntiAlias = false;

    // snow
    p.color = const Color(0xFFF1F3FA);
    c.drawRect(Rect.fromLTWH(0, 0, W, H), p);
    p.color = const Color(0xFFE6EAF5);
    for (double y = 0; y < H; y += 3) {
      c.drawRect(Rect.fromLTWH(0, y, W, 1), p);
    }

    // ridges (top + bottom)
    final topFill = Path()..moveTo(0, 0);
    final topLine = Path();
    final botFill = Path()..moveTo(0, H);
    final botLine = Path();
    final topLine2 = Path();
    final botLine2 = Path();
    bool first = true;
    for (double x = 0; x <= W + 2; x += 2) {
      final wx = s.ridgeScroll + x;
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
      ..lineTo(W, 0)
      ..close();
    botFill
      ..lineTo(W, H)
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
