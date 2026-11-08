import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------- constants
const cats = ['Fitness', 'Productivity', 'Health', 'Mind', 'Finance'];
const freqs = ['Daily', 'Weekly', 'Monthly'];
const swatches = [
  Color(0xFFD9481C), Color(0xFF2F7D5B), Color(0xFF2563A8), Color(0xFFB4478A),
  Color(0xFFC9921A), Color(0xFF5B5BD6), Color(0xFF0F8B8D), Color(0xFF6B5B4E),
];
const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
  'August', 'September', 'October', 'November', 'December'];
const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

String ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ------------------------------------------------------------------ palette
class P {
  final Color bg, card, fg, mut, bd, hv, ac;
  const P(this.bg, this.card, this.fg, this.mut, this.bd, this.hv, this.ac);
  static const light = P(Color(0xFFF3EFE7), Color(0xFFFBF9F4), Color(0xFF1B1A17),
      Color(0xFF7D786C), Color(0xFFE0D9CA), Color(0xFFEBE5D8), Color(0xFFD9481C));
  static const dark = P(Color(0xFF11100E), Color(0xFF1A1916), Color(0xFFEFEADF),
      Color(0xFF8F8A7D), Color(0xFF2B2924), Color(0xFF232019), Color(0xFFFF6D3F));
  static P of(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? dark : light;
}

TextStyle serif(double size, Color c) => TextStyle(
    fontFamily: 'Georgia',
    fontFamilyFallback: const ['Times New Roman', 'serif'],
    fontSize: size,
    fontWeight: FontWeight.w500,
    color: c,
    letterSpacing: -size * 0.02);

Widget eyebrow(String t, P p) => Text(t.toUpperCase(),
    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5, color: p.mut));

Widget card(P p, Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
        color: p.card, borderRadius: BorderRadius.circular(22), border: Border.all(color: p.bd)),
    child: child);

// -------------------------------------------------------------------- model
class Habit {
  final String id, title, note, cat, freq;
  final int ci, times;
  Habit({required this.id, required this.title, this.note = '', this.cat = 'Health',
      this.ci = 0, this.freq = 'Daily', this.times = 1});

  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'note': note, 'cat': cat, 'ci': ci, 'freq': freq, 'times': times};

  factory Habit.fromJson(Map<String, dynamic> j) => Habit(
      id: j['id'] as String,
      title: j['title'] as String,
      note: (j['note'] ?? '') as String,
      cat: cats.contains(j['cat']) ? j['cat'] as String : 'Health',
      ci: ((j['ci'] ?? 0) as int) % swatches.length,
      freq: freqs.contains(j['freq']) ? j['freq'] as String : 'Daily',
      times: math.max(1, math.min(31, (j['times'] ?? 1) as int)));
}

// -------------------------------------------------------------------- store
class HabitStore extends ChangeNotifier {
  List<Habit> habits = [];
  Map<String, Set<String>> logs = {}; // date -> habit ids completed
  ThemeMode mode = ThemeMode.system;
  late SharedPreferences _p;

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    mode = ThemeMode.values[math.max(0, math.min(2, _p.getInt('mode') ?? 0))];
    final raw = _p.getString('hf');
    if (raw != null) importJson(raw, notify: false);
  }

  void _save() => _p.setString('hf', toJsonString());

  String toJsonString() => jsonEncode({
        'habits': [for (final h in habits) h.toJson()],
        'logs': {for (final e in logs.entries) e.key: e.value.toList()},
      });

  bool importJson(String text, {bool notify = true}) {
    try {
      final j = jsonDecode(text);
      final hs = <Habit>[for (final h in j['habits']) Habit.fromJson(h as Map<String, dynamic>)];
      final ids = hs.map((h) => h.id).toSet();
      final lg = <String, Set<String>>{};
      for (final e in (j['logs'] as Map).entries) {
        final s = <String>{for (final x in e.value as List) if (ids.contains(x)) x as String};
        if (s.isNotEmpty) lg[e.key as String] = s;
      }
      habits = hs;
      logs = lg;
      if (notify) {
        _save();
        notifyListeners();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  bool done(String id, String date) => logs[date]?.contains(id) ?? false;

  void toggle(String id, String date) {
    final s = logs.putIfAbsent(date, () => <String>{});
    if (!s.remove(id)) s.add(id);
    if (s.isEmpty) logs.remove(date);
    _save();
    notifyListeners();
  }

  void upsert(Habit h) {
    final i = habits.indexWhere((x) => x.id == h.id);
    if (i >= 0) {
      habits[i] = h;
    } else {
      habits.add(h);
    }
    _save();
    notifyListeners();
  }

  void remove(String id) {
    habits.removeWhere((h) => h.id == id);
    for (final s in logs.values) {
      s.remove(id);
    }
    logs.removeWhere((_, s) => s.isEmpty);
    _save();
    notifyListeners();
  }

  void reset() {
    habits = [];
    logs = {};
    _save();
    notifyListeners();
  }

  void setMode(ThemeMode m) {
    mode = m;
    _p.setInt('mode', m.index);
    notifyListeners();
  }

  // (current streak, best streak) counted in consecutive days
  (int, int) streak(String id) {
    final ds = logs.entries.where((e) => e.value.contains(id)).map((e) => e.key).toList()..sort();
    if (ds.isEmpty) return (0, 0);
    DateTime u(String s) {
      final d = DateTime.parse(s);
      return DateTime.utc(d.year, d.month, d.day);
    }

    int gap(String a, String b) => u(b).difference(u(a)).inDays;
    var best = 1, run = 1;
    for (var i = 1; i < ds.length; i++) {
      if (gap(ds[i - 1], ds[i]) == 1) {
        run++;
        if (run > best) best = run;
      } else {
        run = 1;
      }
    }
    final now = DateTime.now();
    var cur = 0;
    if (ds.last == ymd(now) || ds.last == ymd(DateTime(now.year, now.month, now.day - 1))) {
      cur = 1;
      for (var i = ds.length - 1; i > 0; i--) {
        if (gap(ds[i - 1], ds[i]) == 1) {
          cur++;
        } else {
          break;
        }
      }
    }
    return (cur, best);
  }

  // completions this week / month for non-daily habits
  int? count(Habit h) {
    if (h.freq == 'Daily') return null;
    final n = DateTime.now();
    var d = h.freq == 'Weekly'
        ? DateTime(n.year, n.month, n.day - (n.weekday - 1))
        : DateTime(n.year, n.month, 1);
    var c = 0;
    while (!d.isAfter(n)) {
      if (done(h.id, ymd(d))) c++;
      d = DateTime(d.year, d.month, d.day + 1);
    }
    return c;
  }
}

// --------------------------------------------------------------------- main
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final s = HabitStore();
  await s.init();
  runApp(App(s));
}

ThemeData buildTheme(Brightness b) {
  final p = b == Brightness.dark ? P.dark : P.light;
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    scaffoldBackgroundColor: p.bg,
    colorScheme: ColorScheme.fromSeed(seedColor: p.ac, brightness: b),
    navigationBarTheme: NavigationBarThemeData(backgroundColor: p.bg, indicatorColor: p.hv),
    navigationRailTheme: NavigationRailThemeData(backgroundColor: p.bg, indicatorColor: p.hv),
  );
}

class App extends StatelessWidget {
  final HabitStore s;
  const App(this.s, {super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: s,
      builder: (_, __) => MaterialApp(
          title: 'HabitFlow',
          debugShowCheckedModeBanner: false,
          themeMode: s.mode,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          home: Home(s)));
}

class Home extends StatefulWidget {
  final HabitStore s;
  const Home(this.s, {super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int i = 0;

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final s = widget.s;
    final pages = <Widget>[TodayPage(s), MonthPage(s), StatsPage(s), SettingsPage(s)];
    final body = AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        switchInCurve: Curves.easeOutCubic,
        child: KeyedSubtree(
            key: ValueKey(i),
            child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: (i == 0 || i == 3) ? 660 : 920),
                    child: pages[i]))));
    const icons = [
      [Icons.check_circle_outline, Icons.check_circle],
      [Icons.calendar_month_outlined, Icons.calendar_month],
      [Icons.bar_chart_outlined, Icons.bar_chart],
      [Icons.tune_outlined, Icons.tune],
    ];
    const labels = ['Today', 'Month', 'Stats', 'Settings'];
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 720;
      return Scaffold(
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: i,
                  onDestinationSelected: (v) => setState(() => i = v),
                  destinations: [
                    for (var k = 0; k < 4; k++)
                      NavigationDestination(
                          icon: Icon(icons[k][0]), selectedIcon: Icon(icons[k][1]), label: labels[k])
                  ]),
          body: SafeArea(
              child: wide
                  ? Row(children: [
                      NavigationRail(
                          selectedIndex: i,
                          onDestinationSelected: (v) => setState(() => i = v),
                          labelType: NavigationRailLabelType.all,
                          leading: const Padding(
                              padding: EdgeInsets.only(top: 24, bottom: 16), child: LogoMark(44)),
                          destinations: [
                            for (var k = 0; k < 4; k++)
                              NavigationRailDestination(
                                  icon: Icon(icons[k][0]),
                                  selectedIcon: Icon(icons[k][1]),
                                  label: Text(labels[k]))
                          ]),
                      VerticalDivider(width: 1, color: p.bd),
                      Expanded(child: body),
                    ])
                  : Column(children: [
                      Padding(
                          padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
                          child: Row(children: [
                            const LogoMark(34),
                            const SizedBox(width: 10),
                            Text.rich(TextSpan(style: serif(22, p.fg), children: [
                              const TextSpan(text: 'HabitFlow'),
                              TextSpan(text: '.', style: TextStyle(color: p.ac)),
                            ])),
                          ])),
                      Expanded(child: body),
                    ])));
    });
  }
}

// ------------------------------------------------------------ small widgets
class Rise extends StatelessWidget {
  final int i;
  final Widget child;
  const Rise(this.i, this.child, {super.key});
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: 450 + i * 80),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (_, v, ch) => Opacity(
          opacity: v, child: Transform.translate(offset: Offset(0, 16 * (1 - v)), child: ch)));
}

class LogoMark extends StatelessWidget {
  final double size;
  const LogoMark(this.size, {super.key});
  @override
  Widget build(BuildContext context) =>
      SizedBox(width: size, height: size, child: CustomPaint(painter: _LogoPainter()));
}

class _LogoPainter extends CustomPainter {
  @override
  void paint(Canvas c, Size s) {
    final k = s.width / 1024;
    c.drawRRect(RRect.fromRectAndRadius(Offset.zero & s, Radius.circular(230 * k)),
        Paint()..color = const Color(0xFF1B1A17));
    final r = Rect.fromCircle(center: Offset(512 * k, 512 * k), radius: 270 * k);
    Paint stroke(Color col) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 56 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = col;
    c.drawArc(r, 0, 6.2832, false, stroke(const Color(0xFF3A362F)));
    c.drawArc(r, -1.5708, 4.7124, false, stroke(const Color(0xFFEE5A2C)));
    final t = Path()
      ..moveTo(410 * k, 522 * k)
      ..lineTo(486 * k, 598 * k)
      ..lineTo(624 * k, 432 * k);
    c.drawPath(t, stroke(const Color(0xFFF3EFE7)));
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class RingPainter extends CustomPainter {
  final double v;
  final Color track, bar;
  RingPainter(this.v, this.track, this.bar);
  @override
  void paint(Canvas c, Size s) {
    final r = Rect.fromCircle(center: s.center(Offset.zero), radius: s.width / 2 - 5);
    Paint stroke(Color col) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round
      ..color = col;
    c.drawArc(r, 0, 6.2832, false, stroke(track));
    if (v > 0) c.drawArc(r, -1.5708, 6.2832 * v, false, stroke(bar));
  }

  @override
  bool shouldRepaint(RingPainter o) => o.v != v || o.track != track || o.bar != bar;
}

class BarsPainter extends CustomPainter {
  final List<int> v;
  final double t;
  final Color color;
  BarsPainter(this.v, this.t, this.color);
  @override
  void paint(Canvas c, Size s) {
    final w = s.width / v.length;
    final paint = Paint()..color = color;
    for (var i = 0; i < v.length; i++) {
      final h = s.height * (math.max(2, v[i]) / 100) * t;
      c.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(i * w + w * 0.15, s.height - h, w * 0.7, h), Radius.circular(w * 0.35)),
          paint);
    }
  }

  @override
  bool shouldRepaint(BarsPainter o) => o.t != t || o.v != v || o.color != color;
}

// -------------------------------------------------------------------- today
class TodayPage extends StatelessWidget {
  final HabitStore s;
  const TodayPage(this.s, {super.key});

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final now = DateTime.now();
    final t = ymd(now);
    final n = s.habits.where((h) => s.done(h.id, t)).length;
    final pct = s.habits.isEmpty ? 0.0 : n / s.habits.length;
    final best = s.habits.fold<int>(0, (a, h) => math.max(a, s.streak(h.id).$1));
    return ListView(padding: const EdgeInsets.fromLTRB(22, 28, 22, 40), children: [
      Rise(
          0,
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            eyebrow('${weekdays[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}', p),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Today', style: serif(48, p.fg)),
              FilledButton(
                  onPressed: () => openForm(context, s),
                  style: FilledButton.styleFrom(backgroundColor: p.fg, foregroundColor: p.bg),
                  child: const Text('New habit')),
            ]),
          ])),
      const SizedBox(height: 30),
      Rise(
          1,
          Row(children: [
            TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: pct),
                duration: const Duration(milliseconds: 900),
                curve: Curves.easeOutCubic,
                builder: (_, v, __) => SizedBox(
                    width: 104,
                    height: 104,
                    child: CustomPaint(
                        painter: RingPainter(v, p.hv, p.ac),
                        child: Center(child: Text('${(v * 100).round()}%', style: serif(26, p.fg)))))),
            const SizedBox(width: 22),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$n of ${s.habits.length} done', style: serif(22, p.fg)),
              const SizedBox(height: 4),
              Text(best > 0 ? 'Longest running streak: $best days' : 'Tap a habit to check it off',
                  style: TextStyle(fontSize: 13, color: p.mut)),
            ])),
          ])),
      const SizedBox(height: 10),
      if (s.habits.isEmpty)
        Rise(
            2,
            Padding(
                padding: const EdgeInsets.only(top: 40),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('A clean slate.', style: serif(26, p.fg)),
                  const SizedBox(height: 6),
                  Text('Add your first habit to begin.', style: TextStyle(color: p.mut)),
                ])))
      else
        for (var k = 0; k < s.habits.length; k++)
          Rise(k + 2, HabitTile(s, s.habits[k]), key: ValueKey(s.habits[k].id)),
    ]);
  }
}

class HabitTile extends StatelessWidget {
  final HabitStore s;
  final Habit h;
  const HabitTile(this.s, this.h, {super.key});

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    final t = ymd(DateTime.now());
    final ok = s.done(h.id, t);
    final st = s.streak(h.id);
    final c = s.count(h);
    final col = swatches[h.ci];
    return InkWell(
        onTap: () => s.toggle(h.id, t),
        child: Container(
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.bd))),
            child: Row(children: [
              AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ok ? col : Colors.transparent,
                      border: Border.all(color: ok ? col : p.mut, width: 1.5)),
                  child: AnimatedScale(
                      scale: ok ? 1 : 0,
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutBack,
                      child: const Icon(Icons.check, size: 20, color: Colors.white))),
              const SizedBox(width: 16),
              Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 300),
                    style: serif(21, ok ? p.mut : p.fg).copyWith(
                        decoration: ok ? TextDecoration.lineThrough : TextDecoration.none,
                        decorationColor: p.mut),
                    child: Text(h.title)),
                const SizedBox(height: 2),
                Text.rich(TextSpan(style: TextStyle(fontSize: 13, color: p.mut), children: [
                  TextSpan(text: h.cat),
                  if (st.$1 > 0)
                    TextSpan(
                        text: ' · ${st.$1} day streak',
                        style: TextStyle(color: p.ac, fontWeight: FontWeight.w700)),
                  if (c != null)
                    TextSpan(
                        text: ' · $c of ${h.times} this ${h.freq == 'Weekly' ? 'week' : 'month'}'),
                  if (h.note.isNotEmpty) TextSpan(text: ' · ${h.note}'),
                ])),
              ])),
              TextButton(
                  onPressed: () => openForm(context, s, h),
                  child: Text('Edit', style: TextStyle(color: p.mut))),
            ])));
  }
}

void openForm(BuildContext context, HabitStore s, [Habit? h]) {
  showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: P.of(context).card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => HabitForm(s, h));
}

class HabitForm extends StatefulWidget {
  final HabitStore s;
  final Habit? h;
  const HabitForm(this.s, this.h, {super.key});
  @override
  State<HabitForm> createState() => _HabitFormState();
}

class _HabitFormState extends State<HabitForm> {
  late final title = TextEditingController(text: widget.h?.title ?? '');
  late final note = TextEditingController(text: widget.h?.note ?? '');
  late String cat = widget.h?.cat ?? 'Health';
  late String freq = widget.h?.freq ?? 'Daily';
  late int ci = widget.h?.ci ?? 0;
  late int times = widget.h?.times ?? 1;

  @override
  void dispose() {
    title.dispose();
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    return Padding(
        padding: EdgeInsets.fromLTRB(24, 26, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.h == null ? 'New habit' : 'Edit habit', style: serif(34, p.fg)),
          const SizedBox(height: 14),
          TextField(
              controller: title,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'Title', counterText: '')),
          TextField(
              controller: note,
              maxLength: 120,
              decoration: const InputDecoration(labelText: 'Note (optional)', counterText: '')),
          const SizedBox(height: 18),
          eyebrow('Category', p),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in cats)
              ChoiceChip(label: Text(c), selected: cat == c, onSelected: (_) => setState(() => cat = c))
          ]),
          const SizedBox(height: 18),
          eyebrow('Colour', p),
          const SizedBox(height: 10),
          Wrap(spacing: 12, runSpacing: 12, children: [
            for (var k = 0; k < swatches.length; k++)
              GestureDetector(
                  onTap: () => setState(() => ci = k),
                  child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                          color: swatches[k],
                          shape: BoxShape.circle,
                          border: Border.all(color: ci == k ? p.fg : Colors.transparent, width: 3))))
          ]),
          const SizedBox(height: 18),
          eyebrow('Repeat', p),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final f in freqs)
              ChoiceChip(label: Text(f), selected: freq == f, onSelected: (_) => setState(() => freq = f)),
            IconButton(
                onPressed: () => setState(() => times = math.max(1, times - 1)),
                icon: const Icon(Icons.remove)),
            Text('$times×', style: serif(20, p.fg)),
            IconButton(
                onPressed: () => setState(() => times = math.min(31, times + 1)),
                icon: const Icon(Icons.add)),
          ]),
          const SizedBox(height: 24),
          Row(children: [
            if (widget.h != null)
              TextButton(
                  onPressed: () {
                    widget.s.remove(widget.h!.id);
                    Navigator.pop(context);
                  },
                  child: const Text('Delete', style: TextStyle(color: Color(0xFFD33333)))),
            const Spacer(),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: p.fg, foregroundColor: p.bg),
                onPressed: () {
                  final t = title.text.trim();
                  if (t.isEmpty) return;
                  widget.s.upsert(Habit(
                      id: widget.h?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
                      title: t,
                      note: note.text.trim(),
                      cat: cat,
                      ci: ci,
                      freq: freq,
                      times: times));
                  Navigator.pop(context);
                },
                child: const Text('Save')),
          ]),
        ])));
  }
}

// -------------------------------------------------------------------- month
class MonthPage extends StatefulWidget {
  final HabitStore s;
  const MonthPage(this.s, {super.key});
  @override
  State<MonthPage> createState() => _MonthPageState();
}

class _MonthPageState extends State<MonthPage> {
  late DateTime mon = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final p = P.of(context);
    final y = mon.year, m = mon.month;
    final n = DateTime(y, m + 1, 0).day;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final last = (y == now.year && m == now.month)
        ? now.day
        : (DateTime(y, m + 1, 0).isBefore(today) ? n : 0);
    var tot = 0;
    final per = <(Habit, int)>[];
    for (final h in s.habits) {
      var c = 0;
      for (var d = 1; d <= n; d++) {
        if (s.done(h.id, ymd(DateTime(y, m, d)))) c++;
      }
      tot += c;
      per.add((h, c));
    }
    final pct = (s.habits.isEmpty || last == 0)
        ? 0
        : math.min(100, (tot / (s.habits.length * last) * 100).round());
    final top = ([...per]..sort((a, b) => b.$2.compareTo(a.$2))).where((e) => e.$2 > 0).take(3).toList();

    Widget stat(String label, String value) => card(
        p, Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          eyebrow(label, p),
          const SizedBox(height: 4),
          Text(value, style: serif(34, p.fg)),
        ]));

    return ListView(padding: const EdgeInsets.fromLTRB(22, 28, 22, 40), children: [
      Rise(
          0,
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Month', style: serif(48, p.fg)),
            Row(children: [
              IconButton(
                  onPressed: () => setState(() => mon = DateTime(y, m - 1)),
                  icon: const Icon(Icons.chevron_left)),
              Text('${months[m - 1].substring(0, 3)} $y', style: serif(18, p.fg)),
              IconButton(
                  onPressed: () => setState(() => mon = DateTime(y, m + 1)),
                  icon: const Icon(Icons.chevron_right)),
            ]),
          ])),
      const SizedBox(height: 22),
      Rise(1, Row(children: [
        Expanded(child: stat('Completion', '$pct%')),
        const SizedBox(width: 14),
        Expanded(child: stat('Check-ins', '$tot')),
      ])),
      const SizedBox(height: 14),
      Rise(
          2,
          card(
              p,
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                eyebrow('Top habits', p),
                const SizedBox(height: 8),
                if (top.isEmpty) Text('None yet', style: TextStyle(color: p.mut)),
                for (final e in top)
                  Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('${e.$1.title}  ·  ${e.$2}', style: TextStyle(color: p.fg))),
              ]))),
      const SizedBox(height: 14),
      Rise(
          3,
          card(
              p,
              s.habits.isEmpty
                  ? Text('Add habits to see your heatmap.', style: TextStyle(color: p.mut))
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          const SizedBox(width: 120),
                          for (var d = 1; d <= n; d++)
                            SizedBox(
                                width: 24,
                                child: Center(
                                    child: Text('$d', style: TextStyle(fontSize: 10, color: p.mut)))),
                        ]),
                        for (final e in per)
                          Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Row(children: [
                                SizedBox(
                                    width: 120,
                                    child: Text(e.$1.title,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontSize: 13, color: p.fg))),
                                for (var d = 1; d <= n; d++)
                                  Padding(
                                      padding: const EdgeInsets.all(2),
                                      child: AnimatedContainer(
                                          duration: const Duration(milliseconds: 250),
                                          width: 20,
                                          height: 20,
                                          decoration: BoxDecoration(
                                              color: s.done(e.$1.id, ymd(DateTime(y, m, d)))
                                                  ? swatches[e.$1.ci]
                                                  : p.hv,
                                              borderRadius: BorderRadius.circular(6)))),
                              ])),
                      ])))),
    ]);
  }
}

// -------------------------------------------------------------------- stats
class StatsPage extends StatelessWidget {
  final HabitStore s;
  const StatsPage(this.s, {super.key});

  @override
  Widget build(BuildContext context) {
    final p = P.of(context);
    if (s.habits.isEmpty) {
      return ListView(padding: const EdgeInsets.fromLTRB(22, 28, 22, 40), children: [
        Text('Stats', style: serif(48, p.fg)),
        const SizedBox(height: 18),
        Text('Add habits to see your patterns.', style: TextStyle(color: p.mut)),
      ]);
    }
    final now = DateTime.now();
    final pcts = <int>[
      for (var i = 29; i >= 0; i--)
        (s.habits.where((h) => s.done(h.id, ymd(DateTime(now.year, now.month, now.day - i)))).length /
                s.habits.length *
                100)
            .round()
    ];
    final totals = {
      for (final c in cats)
        c: s.habits
            .where((h) => h.cat == c)
            .fold<int>(0, (a, h) => a + s.logs.values.where((x) => x.contains(h.id)).length)
    }..removeWhere((_, v) => v == 0);
    final mx = totals.values.fold<int>(1, math.max);
    final best = s.habits.fold<int>(0, (a, h) => math.max(a, s.streak(h.id).$2));

    return ListView(padding: const EdgeInsets.fromLTRB(22, 28, 22, 40), children: [
      Rise(0, Text('Stats', style: serif(48, p.fg))),
      const SizedBox(height: 22),
      Rise(
          1,
          card(
              p,
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                eyebrow('Last 30 days', p),
                const SizedBox(height: 16),
                TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 900),
                    curve: Curves.easeOutCubic,
                    builder: (_, v, __) => SizedBox(
                        height: 150,
                        width: double.infinity,
                        child: CustomPaint(painter: BarsPainter(pcts, v, p.ac)))),
              ]))),
      const SizedBox(height: 14),
      Rise(
          2,
          card(
              p,
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                eyebrow('Streaks · now / best', p),
                for (final h in s.habits)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(children: [
                        Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(color: swatches[h.ci], shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(h.title,
                                overflow: TextOverflow.ellipsis, style: TextStyle(color: p.fg))),
                        Text('${s.streak(h.id).$1}', style: serif(20, p.fg)),
                        Text(' / ${s.streak(h.id).$2}', style: TextStyle(color: p.mut)),
                      ])),
              ]))),
      const SizedBox(height: 14),
      Rise(
          3,
          card(
              p,
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                eyebrow('By category', p),
                if (totals.isEmpty)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('No check-ins yet.', style: TextStyle(color: p.mut))),
                for (final e in totals.entries)
                  Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Column(children: [
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text(e.key, style: TextStyle(color: p.fg)),
                          Text('${e.value}', style: TextStyle(color: p.mut)),
                        ]),
                        const SizedBox(height: 6),
                        TweenAnimationBuilder<double>(
                            tween: Tween<double>(begin: 0, end: e.value / mx),
                            duration: const Duration(milliseconds: 900),
                            curve: Curves.easeOutCubic,
                            builder: (_, v, __) => ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: LinearProgressIndicator(
                                    value: v, minHeight: 8, backgroundColor: p.hv, color: p.ac))),
                      ])),
              ]))),
      const SizedBox(height: 14),
      Rise(
          4,
          card(
              p,
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                eyebrow('Milestones', p),
                const SizedBox(height: 14),
                Row(children: [
                  for (final n in [7, 30, 100])
                    Expanded(
                        child: AnimatedContainer(
                            duration: const Duration(milliseconds: 400),
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            decoration: BoxDecoration(
                                color: best >= n ? p.ac : Colors.transparent,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(color: best >= n ? p.ac : p.bd)),
                            child: Column(children: [
                              Text('$n', style: serif(34, best >= n ? Colors.white : p.mut)),
                              Text('day streak',
                                  style: TextStyle(fontSize: 12, color: best >= n ? Colors.white : p.mut)),
                            ]))),
                ]),
              ]))),
    ]);
  }
}

// ----------------------------------------------------------------- settings
class SettingsPage extends StatefulWidget {
  final HabitStore s;
  const SettingsPage(this.s, {super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool danger = false;

  void restore() {
    final c = TextEditingController();
    showDialog(
        context: context,
        builder: (dc) => AlertDialog(
                title: const Text('Restore backup'),
                content: TextField(
                    controller: c, maxLines: 6, decoration: const InputDecoration(hintText: 'Paste backup JSON')),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(dc), child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () {
                        final ok = widget.s.importJson(c.text);
                        Navigator.pop(dc);
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text(ok ? 'Backup restored' : 'Invalid backup')));
                      },
                      child: const Text('Restore')),
                ]));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final p = P.of(context);
    return ListView(padding: const EdgeInsets.fromLTRB(22, 28, 22, 40), children: [
      Rise(0, Text('Settings', style: serif(48, p.fg))),
      const SizedBox(height: 22),
      Rise(
          1,
          card(
              p,
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                eyebrow('Appearance', p),
                const SizedBox(height: 12),
                SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                      ButtonSegment(value: ThemeMode.system, label: Text('System')),
                      ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                    ],
                    selected: {s.mode},
                    onSelectionChanged: (v) => s.setMode(v.first)),
              ]))),
      const SizedBox(height: 14),
      Rise(
          2,
          card(
              p,
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                eyebrow('Backup', p),
                const SizedBox(height: 8),
                Text('Data is stored on this device only. Copy a backup, or paste one to restore.',
                    style: TextStyle(fontSize: 13, color: p.mut)),
                const SizedBox(height: 12),
                Wrap(spacing: 10, children: [
                  FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: p.fg, foregroundColor: p.bg),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: s.toJsonString()));
                        ScaffoldMessenger.of(context)
                            .showSnackBar(const SnackBar(content: Text('Backup copied to clipboard')));
                      },
                      child: const Text('Copy backup')),
                  OutlinedButton(onPressed: restore, child: const Text('Restore')),
                ]),
              ]))),
      const SizedBox(height: 14),
      Rise(
          3,
          card(
              p,
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('DANGER ZONE',
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5, color: Color(0xFFD33333))),
                const SizedBox(height: 8),
                Text('Delete all habits and history.', style: TextStyle(fontSize: 13, color: p.mut)),
                const SizedBox(height: 12),
                OutlinedButton(
                    onPressed: () {
                      if (!danger) {
                        setState(() => danger = true);
                        Future.delayed(const Duration(seconds: 4), () {
                          if (mounted) setState(() => danger = false);
                        });
                      } else {
                        s.reset();
                        setState(() => danger = false);
                      }
                    },
                    child: Text(danger ? 'Tap again to confirm' : 'Reset all data',
                        style: const TextStyle(color: Color(0xFFD33333)))),
              ]))),
    ]);
  }
}
