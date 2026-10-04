import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Sync.init();
  await Profiles.load();
  runApp(const DopTepApp());
}

const kUnknown = 'Белгісіз';
const kSportName = {'football': 'Футбол', 'basketball': 'Баскетбол', 'volleyball': 'Волейбол'};
const kSportIcon = {'football': '⚽', 'basketball': '🏀', 'volleyball': '🏐'};
const kAppName = 'Алаң'; // ← қосымша атауы (бір жерде ауыстырсаңыз жеткілікті)

String matchStatus(MatchData m) => m.finished
    ? 'Аяқталды'
    : m.sets != null
        ? '${m.sets!.length + 1}-сет'
        : m.quarter > 0
            ? '${m.quarter}-тоқсан'
            : m.onBreak
                ? 'Перерыв'
                : '${m.half}-тайм';

Widget sportBar(String value, void Function(String) onChanged) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: SegmentedButton<String>(
        segments: [
          for (final k in kSportName.keys)
            ButtonSegment(
                value: k,
                label: Text('${kSportIcon[k]} ${kSportName[k]}',
                    style: const TextStyle(fontSize: 12))),
        ],
        selected: {value},
        onSelectionChanged: (s) => onChanged(s.first),
      ),
    );

// ===================== МОДЕЛЬДЕР =====================
class Goal {
  final String team, player;
  final int minute; // 0 = белгісіз
  final String assist; // '' = ассистсіз
  final int pts; // футбол: 1, баскетбол: 1/2/3
  final int quarter; // баскетбол тоқсаны
  Goal(this.team, this.player,
      [this.minute = 0, this.assist = '', this.pts = 1, this.quarter = 0]);
  Map<String, dynamic> toJson() => {
        'team': team,
        'player': player,
        'minute': minute,
        'assist': assist,
        'pts': pts,
        'quarter': quarter
      };
  factory Goal.fromJson(Map<String, dynamic> j) => Goal(j['team'], j['player'],
      j['minute'] ?? 0, j['assist'] ?? '', j['pts'] ?? 1, j['quarter'] ?? 0);
}

class VSet {
  int a, b;
  String w; // сетті алған команда
  VSet(this.a, this.b, this.w);
  Map<String, dynamic> toJson() => {'a': a, 'b': b, 'w': w};
  factory VSet.fromJson(Map<String, dynamic> j) => VSet(j['a'], j['b'], j['w']);
}

class MatchData {
  String a, b;
  List<Goal> goals;
  bool finished;
  int seconds;
  int half; // 1-тайм / 2-тайм
  bool onBreak; // перерыв
  List<VSet>? sets; // волейбол: аяқталған сеттер (null = волейбол емес)
  int ca, cb; // волейбол: ағымдағы сет ұпайы
  int quarter; // баскетбол: тоқсан (0 = баскетбол емес)
  MatchData(this.a, this.b,
      {this.sets,
      this.ca = 0,
      this.cb = 0,
      this.quarter = 0,
      List<Goal>? goals,
      this.finished = false,
      this.seconds = 0,
      this.half = 1,
      this.onBreak = false})
      : goals = goals ?? [];
  int score(String t) => sets != null
      ? sets!.where((s) => s.w == t).length
      : goals.where((g) => g.team == t).fold<int>(0, (a, g) => a + g.pts);
  Map<String, dynamic> toJson() => {
        'a': a,
        'b': b,
        'finished': finished,
        'seconds': seconds,
        'half': half,
        'onBreak': onBreak,
        'sets': sets?.map((x) => x.toJson()).toList(),
        'ca': ca,
        'cb': cb,
        'quarter': quarter,
        'goals': goals.map((g) => g.toJson()).toList(),
      };
  factory MatchData.fromJson(Map<String, dynamic> j) => MatchData(
        j['a'],
        j['b'],
        finished: j['finished'] ?? false,
        seconds: j['seconds'] ?? 0,
        half: j['half'] ?? 1,
        onBreak: j['onBreak'] ?? false,
        sets: j['sets'] == null
            ? null
            : (j['sets'] as List).map((e) => VSet.fromJson(e)).toList(),
        ca: j['ca'] ?? 0,
        cb: j['cb'] ?? 0,
        quarter: j['quarter'] ?? 0,
        goals: (j['goals'] as List).map((e) => Goal.fromJson(e)).toList(),
      );
}

class GameDay {
  String id, date;
  List<String> teams;
  Map<String, List<String>> players;
  List<MatchData> matches;
  int updated; // соңғы өзгерген уақыт (синхрондау үшін)
  String sport = 'football'; // football / basketball / volleyball
  GameDay(this.id, this.date, this.teams, this.players, this.matches,
      [this.updated = 0]);

  /// Объектіні ауыстырмай, ішін жаңартады (ашық экрандар үзілмеу үшін).
  void copyFrom(GameDay o) {
    date = o.date;
    sport = o.sport;
    teams = o.teams;
    players = o.players;
    updated = o.updated;
    for (var i = 0; i < o.matches.length; i++) {
      if (i < matches.length) {
        final m = matches[i], n = o.matches[i];
        m.a = n.a; m.b = n.b; m.goals = n.goals; m.finished = n.finished;
        m.seconds = n.seconds; m.half = n.half; m.onBreak = n.onBreak;
        m.sets = n.sets; m.ca = n.ca; m.cb = n.cb; m.quarter = n.quarter;
      } else {
        matches.add(o.matches[i]);
      }
    }
    if (matches.length > o.matches.length) {
      matches.removeRange(o.matches.length, matches.length);
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date,
        'updated': updated,
        'sport': sport,
        'teams': teams,
        'players': players,
        'matches': matches.map((m) => m.toJson()).toList(),
      };
  factory GameDay.fromJson(Map<String, dynamic> j) => GameDay(
        j['id'],
        j['date'],
        List<String>.from(j['teams']),
        (j['players'] as Map).map(
            (k, v) => MapEntry(k as String, List<String>.from(v as List))),
        (j['matches'] as List).map((e) => MatchData.fromJson(e)).toList(),
        j['updated'] ?? 0,
      )..sport = j['sport'] ?? 'football';
}

// ===================== ЕСЕПТЕУ =====================
class TeamRow {
  final String name;
  int p = 0, w = 0, d = 0, l = 0, gf = 0, ga = 0, pts = 0;
  int days = 0, dayWins = 0; // маусымдық рейтинг үшін
  TeamRow(this.name);
  int get gd => gf - ga;
}

List<TeamRow> computeStandings(GameDay day) {
  final st = {for (final t in day.teams) t: TeamRow(t)};
  final win = day.sport == 'football' ? 3 : 2;
  for (final m in day.matches.where((m) => m.finished)) {
    final sa = m.score(m.a), sb = m.score(m.b);
    final A = st[m.a]!, B = st[m.b]!;
    A.p++; B.p++;
    A.gf += sa; A.ga += sb; B.gf += sb; B.ga += sa;
    if (sa > sb) { A.w++; B.l++; A.pts += win; }
    else if (sa < sb) { B.w++; A.l++; B.pts += win; }
    else { A.d++; B.d++; A.pts++; B.pts++; }
  }
  final rows = st.values.toList()
    ..sort((x, y) {
      final c = y.pts.compareTo(x.pts);
      if (c != 0) return c;
      final g = y.gd.compareTo(x.gd);
      return g != 0 ? g : y.gf.compareTo(x.gf);
    });
  return rows;
}

class PlayerStat {
  final String name;
  String team = '';
  int goals = 0, assists = 0, matches = 0, days = 0;
  PlayerStat(this.name);
  double get perMatch => matches == 0 ? 0 : goals / matches;
}

/// Бір немесе бірнеше ойын күні бойынша ойыншылар статистикасы.
List<PlayerStat> computeStats(Iterable<GameDay> days) {
  final map = <String, PlayerStat>{};
  PlayerStat of(String n) =>
      map.putIfAbsent(n.trim().toLowerCase(), () => PlayerStat(n.trim()));
  for (final d in days) {
    final fin = d.matches.where((m) => m.finished).toList();
    for (final e in d.players.entries) {
      final games = fin.where((m) => m.a == e.key || m.b == e.key).length;
      for (final p in e.value) {
        final s = of(p);
        s.days++;
        s.matches += games;
        s.team = e.key;
      }
    }
    for (final m in d.matches) {
      for (final g in m.goals) {
        if (g.assist.isNotEmpty) {
          final a = of(g.assist);
          a.assists++;
          a.team = g.team;
        }
        if (g.player == kUnknown) continue;
        final s = of(g.player);
        s.goals += g.pts;
        s.team = g.team;
      }
    }
  }
  return map.values.toList()
    ..sort((a, b) {
      final c = b.goals.compareTo(a.goals);
      if (c != 0) return c;
      final c2 = b.assists.compareTo(a.assists);
      return c2 != 0 ? c2 : a.matches.compareTo(b.matches);
    });
}

// ===================== ОНЛАЙН СИНХРОНДАУ (Firebase) =====================
final syncTick = ValueNotifier<int>(0); // қашықтан өзгеріс келгенде экрандарды жаңартады
List<GameDay> allDaysRef = []; // барлық ойын күндері (профиль экраны үшін)
List<String> knownNames = []; // автотолықтыру үшін бұрынғы ойыншылар

void refreshKnown(List<GameDay> days) {
  knownNames = computeStats(days).map((s) => s.name).toList();
}

class Sync {
  static bool ready = false; // Firebase бапталған ба
  static String room = '';
  static StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;

  static bool get active => ready && room.isNotEmpty;

  static CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('rooms').doc(room).collection('days');

  static Future<void> init() async {
    try {
      await Firebase.initializeApp();
      ready = true;
    } catch (_) {
      ready = false;
    }
    final p = await SharedPreferences.getInstance();
    room = p.getString('room') ?? '';
  }

  static Future<void> setRoom(String r) async {
    room = r.trim().toLowerCase().replaceAll('/', '-');
    final p = await SharedPreferences.getInstance();
    await p.setString('room', room);
  }

  static Future<void> push(GameDay d) async {
    if (!active) return;
    try {
      await _col.doc(d.id).set({'data': jsonEncode(d.toJson()), 'updated': d.updated});
    } catch (_) {}
  }

  static Future<void> remove(String id) async {
    if (!active) return;
    try {
      await _col.doc(id).delete();
    } catch (_) {}
  }

  static void listen(List<GameDay> days, VoidCallback onRemote) {
    _sub?.cancel();
    _sub = null;
    if (!active) return;
    _sub = _col.snapshots().listen((snap) {
      var changed = false;
      for (final c in snap.docChanges) {
        final id = c.doc.id;
        if (c.type == DocumentChangeType.removed) {
          final n = days.length;
          days.removeWhere((x) => x.id == id);
          if (days.length != n) changed = true;
          continue;
        }
        final data = c.doc.data();
        if (data == null) continue;
        try {
          final remote = GameDay.fromJson(jsonDecode(data['data']));
          remote.updated = data['updated'] ?? 0;
          final i = days.indexWhere((x) => x.id == id);
          if (i < 0) {
            days.add(remote);
            changed = true;
          } else if (remote.updated > days[i].updated) {
            days[i].copyFrom(remote);
            changed = true;
          }
        } catch (_) {}
      }
      if (changed) {
        days.sort((a, b) => b.id.compareTo(a.id));
        onRemote();
      }
    }, onError: (_) {});
  }
}

// ===================== САҚТАУ =====================
Future<List<GameDay>> loadDays() async {
  final p = await SharedPreferences.getInstance();
  final raw = p.getString('days');
  if (raw == null) return [];
  return (jsonDecode(raw) as List).map((e) => GameDay.fromJson(e)).toList();
}

Future<void> saveDays(List<GameDay> days) async {
  final p = await SharedPreferences.getInstance();
  await p.setString('days', jsonEncode(days.map((d) => d.toJson()).toList()));
}

// ===================== ҚОСЫМША =====================
class DopTepApp extends StatelessWidget {
  const DopTepApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: kAppName,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F5F7),
      ),
      home: const HomeScreen(),
    );
  }
}

// ===================== БАСТЫ ЭКРАН =====================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<GameDay> days = [];

  @override
  void initState() {
    super.initState();
    loadDays().then((d) {
      setState(() => days = d);
      allDaysRef = days;
      refreshKnown(days);
      Sync.listen(days, _remote);
    });
  }

  Future<void> _changed(GameDay d) async {
    d.updated = DateTime.now().millisecondsSinceEpoch;
    refreshKnown(days);
    await saveDays(days);
    Sync.push(d);
  }

  void _remote() {
    refreshKnown(days);
    saveDays(days);
    if (mounted) setState(() {});
    syncTick.value++;
  }

  Future<void> _cloud() async {
    final c = TextEditingController(text: Sync.room);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Онлайн синхрондау'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!Sync.ready)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Firebase бапталмаған (google-services.json қосыңыз).',
                  style: TextStyle(color: Colors.red)),
            ),
          const Text('Бөлме коды. Достарыңызға да дәл осы кодты беріңіз:'),
          const SizedBox(height: 8),
          TextField(
            controller: c,
            decoration: const InputDecoration(
                hintText: 'мыс. aktobe-futbol-7k2', border: OutlineInputBorder()),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Сөндіру')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Қосу')),
        ],
      ),
    );
    if (r == null) return;
    await Sync.setRoom(r);
    Sync.listen(days, _remote);
    for (final d in days) {
      Sync.push(d);
    }
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    final d = await Navigator.push<GameDay>(
        context,
        MaterialPageRoute(
            builder: (_) =>
                NewDayScreen(previous: days.isEmpty ? null : days.first)));
    if (d != null) {
      setState(() => days.insert(0, d));
      await _changed(d);
      _open(d);
    }
  }

  void _open(GameDay d) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => DayScreen(day: d, onChanged: () => _changed(d))));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('$kAppName — Футбол есебі',
            style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Маусым рейтингі',
            icon: const Icon(Icons.emoji_events),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => SeasonScreen(days: days))),
          ),
          IconButton(
            tooltip: 'Онлайн синхрондау',
            icon: Icon(Sync.active ? Icons.cloud_done : Icons.cloud_off),
            onPressed: _cloud,
          ),
          IconButton(
            tooltip: 'Жалпы статистика',
            icon: const Icon(Icons.bar_chart),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => StatsScreen(days: days))),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Жаңа ойын күні'),
      ),
      body: days.isEmpty
          ? const Center(child: Text('Ойын күні жоқ. «Жаңа ойын күні» басыңыз.'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: days.length,
              itemBuilder: (_, i) {
                final d = days[i];
                return Card(
                  elevation: 3,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  child: ListTile(
                    leading: Text(kSportIcon[d.sport] ?? '⚽', style: const TextStyle(fontSize: 32)),
                    title: Text(d.date, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('${d.teams.length} команда • ${d.matches.length} матч'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        if (!await confirmDialog(
                            context, '${d.date} ойын күні толық өшеді.')) return;
                        setState(() => days.removeAt(i));
                        Sync.remove(d.id);
                        refreshKnown(days);
                        await saveDays(days);
                      },
                    ),
                    onTap: () => _open(d),
                  ),
                );
              },
            ),
    );
  }
}

// ===================== ОЙЫНШЫ ПРОФИЛІ =====================
class Profiles {
  static Map<String, Map<String, String>> _m = {};
  static String key(String n) => n.trim().toLowerCase();

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('profiles');
    if (raw == null) return;
    try {
      _m = (jsonDecode(raw) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, Map<String, String>.from(v as Map)));
    } catch (_) {}
  }

  static Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('profiles', jsonEncode(_m));
  }

  static String? field(String n, String f) => _m[key(n)]?[f];

  static String? photo(String n) {
    final p = field(n, 'photo');
    return (p != null && File(p).existsSync()) ? p : null;
  }

  static Future<void> setField(String n, String f, String? v) async {
    final m = _m.putIfAbsent(key(n), () => {});
    if (v == null || v.isEmpty) {
      m.remove(f);
    } else {
      m[f] = v;
    }
    await _save();
  }

  static Future<void> pickPhoto(String n, ImageSource src) async {
    final x = await ImagePicker().pickImage(source: src, maxWidth: 600, imageQuality: 80);
    if (x == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final dest = '${dir.path}/player_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(x.path).copy(dest);
    final old = field(n, 'photo');
    await setField(n, 'photo', dest);
    if (old != null) {
      try { File(old).deleteSync(); } catch (_) {}
    }
  }
}

class PlayerAvatar extends StatelessWidget {
  final String name;
  final double radius;
  const PlayerAvatar({super.key, required this.name, this.radius = 20});
  @override
  Widget build(BuildContext context) {
    final ph = Profiles.photo(name);
    final t = name.trim();
    return CircleAvatar(
      radius: radius,
      backgroundColor: Colors.indigo.shade100,
      backgroundImage: ph != null ? FileImage(File(ph)) : null,
      child: ph == null
          ? Text(t.isEmpty ? '?' : t[0].toUpperCase(),
              style: TextStyle(
                  fontSize: radius * 0.9, fontWeight: FontWeight.bold, color: Colors.indigo))
          : null,
    );
  }
}

class PlayerScreen extends StatefulWidget {
  final String name;
  final List<GameDay> days;
  const PlayerScreen({super.key, required this.name, required this.days});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  String get n => widget.name;

  Future<void> _photo() async {
    final act = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Камера'),
              onTap: () => Navigator.pop(ctx, 'cam')),
          ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Галерея'),
              onTap: () => Navigator.pop(ctx, 'gal')),
          if (Profiles.photo(n) != null)
            ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Фотоны өшіру'),
                onTap: () => Navigator.pop(ctx, 'del')),
        ]),
      ),
    );
    if (act == null) return;
    try {
      if (act == 'del') {
        await Profiles.setField(n, 'photo', null);
      } else {
        await Profiles.pickPhoto(n, act == 'cam' ? ImageSource.camera : ImageSource.gallery);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Қате: $e')));
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _editInfo() async {
    final numC = TextEditingController(text: Profiles.field(n, 'number') ?? '');
    final pos = TextEditingController(text: Profiles.field(n, 'pos') ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Профиль'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: numC,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Нөмірі', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextField(
              controller: pos,
              decoration: const InputDecoration(
                  labelText: 'Орны (қорғаушы, шабуылшы...)', border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Бас тарту')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сақтау')),
        ],
      ),
    );
    if (ok == true) {
      await Profiles.setField(n, 'number', numC.text.trim());
      await Profiles.setField(n, 'pos', pos.text.trim());
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    PlayerStat? st;
    for (final s in computeStats(widget.days)) {
      if (Profiles.key(s.name) == Profiles.key(n)) st = s;
    }
    // күн бойынша голдар
    final perDay = <MapEntry<String, int>>[];
    for (final d in widget.days) {
      var g = 0;
      for (final m in d.matches) {
        for (final x in m.goals) {
          if (Profiles.key(x.player) == Profiles.key(n)) g++;
        }
      }
      final attended = d.players.values.any((l) => l.any((p) => Profiles.key(p) == Profiles.key(n)));
      if (g > 0 || attended) perDay.add(MapEntry(d.date, g));
    }
    final best = perDay.fold<int>(0, (a, e) => e.value > a ? e.value : a);
    final number = Profiles.field(n, 'number');
    final pos = Profiles.field(n, 'pos');

    Widget stat(String label, String v) => Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Column(children: [
                Text(v, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.indigo)),
                Text(label, style: const TextStyle(fontSize: 12)),
              ]),
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(
        title: Text(n),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.edit), onPressed: _editInfo)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Stack(children: [
              PlayerAvatar(name: n, radius: 60),
              Positioned(
                right: 0,
                bottom: 0,
                child: CircleAvatar(
                  backgroundColor: Colors.indigo,
                  child: IconButton(
                      icon: const Icon(Icons.photo_camera, color: Colors.white),
                      onPressed: _photo),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              [if (number != null) '№$number', n].join('  '),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
          ),
          if (pos != null) Center(child: Text(pos, style: const TextStyle(color: Colors.black54))),
          if (st != null && st.team.isNotEmpty)
            Center(child: Text(st.team, style: const TextStyle(color: Colors.black54))),
          const SizedBox(height: 16),
          Row(children: [
            stat('Гол', '${st?.goals ?? 0}'),
            stat('Матч', '${st?.matches ?? 0}'),
            stat('Күн', '${st?.days ?? 0}'),
          ]),
          Row(children: [
            stat('Матчқа гол', (st?.perMatch ?? 0).toStringAsFixed(2)),
            stat('Рекорд (бір күнде)', '$best'),
            stat('Ассист', '${st?.assists ?? 0}'),
          ]),
          const SizedBox(height: 12),
          const Text('Ойын күндері', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          if (perDay.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Дерек жоқ')),
          for (final e in perDay)
            ListTile(
              dense: true,
              leading: const Icon(Icons.calendar_today, size: 18),
              title: Text(e.key),
              trailing: Text('⚽ ${e.value}', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          const SizedBox(height: 8),
          const Text('Фото құрылғыда ғана сақталады (онлайн синхрондалмайды).',
              style: TextStyle(fontSize: 12, color: Colors.black45)),
        ],
      ),
    );
  }
}

// ===================== МАУСЫМ БОЙЫНША КОМАНДАЛАР РЕЙТИНГІ =====================
class SeasonScreen extends StatefulWidget {
  final List<GameDay> days;
  const SeasonScreen({super.key, required this.days});
  @override
  State<SeasonScreen> createState() => _SeasonScreenState();
}

class _SeasonScreenState extends State<SeasonScreen> {
  String sport = 'football';
  String? year;
  List<GameDay> get _sd => widget.days.where((d) => d.sport == sport).toList();
  List<String> get years => (_sd.map((d) => d.date.split('.').last).toSet().toList()
    ..sort((a, b) => b.compareTo(a)));

  List<TeamRow> _rows() {
    final agg = <String, TeamRow>{};
    for (final day in _sd.where((d) => d.date.split('.').last == year)) {
      final st = computeStandings(day);
      for (final r in st) {
        if (r.p == 0) continue;
        final a = agg.putIfAbsent(r.name, () => TeamRow(r.name));
        a.days++; a.p += r.p; a.w += r.w; a.d += r.d; a.l += r.l;
        a.gf += r.gf; a.ga += r.ga; a.pts += r.pts;
      }
      if (st.isNotEmpty && st.first.p > 0) agg[st.first.name]!.dayWins++;
    }
    return agg.values.toList()
      ..sort((x, y) {
        final c = y.pts.compareTo(x.pts);
        if (c != 0) return c;
        final g = y.gd.compareTo(x.gd);
        return g != 0 ? g : y.gf.compareTo(x.gf);
      });
  }

  @override
  Widget build(BuildContext context) {
    if (year == null || !years.contains(year)) {
      year = years.isEmpty ? null : years.first;
    }
    final rows = year == null ? <TeamRow>[] : _rows();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Маусым рейтингі'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: Column(children: [
        sportBar(sport, (v) => setState(() {
              sport = v;
              year = null;
            })),
        Expanded(
          child: year == null
          ? const Center(child: Text('Дерек жоқ'))
          : Column(children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  const Text('Маусым: ', style: TextStyle(fontSize: 16)),
                  DropdownButton<String>(
                    value: year,
                    items: years.map((y) => DropdownMenuItem(value: y, child: Text(y))).toList(),
                    onChanged: (v) => setState(() => year = v),
                  ),
                ]),
              ),
              if (rows.isEmpty)
                const Expanded(child: Center(child: Text('Аяқталған матч жоқ')))
              else
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SingleChildScrollView(
                      child: DataTable(
                        columnSpacing: 16,
                        columns: const [
                          DataColumn(label: Text('#')),
                          DataColumn(label: Text('Команда')),
                          DataColumn(label: Text('Күн')),
                          DataColumn(label: Text('О')),
                          DataColumn(label: Text('Ж')),
                          DataColumn(label: Text('Т')),
                          DataColumn(label: Text('Жғ')),
                          DataColumn(label: Text('Гол')),
                          DataColumn(label: Text('Ұпай')),
                          DataColumn(label: Text('🏆')),
                        ],
                        rows: [
                          for (var i = 0; i < rows.length; i++)
                            DataRow(cells: [
                              DataCell(Text(i < 3 ? ['🥇', '🥈', '🥉'][i] : '${i + 1}')),
                              DataCell(Text(rows[i].name,
                                  style: const TextStyle(fontWeight: FontWeight.bold))),
                              DataCell(Text('${rows[i].days}')),
                              DataCell(Text('${rows[i].p}')),
                              DataCell(Text('${rows[i].w}')),
                              DataCell(Text('${rows[i].d}')),
                              DataCell(Text('${rows[i].l}')),
                              DataCell(Text('${rows[i].gf}-${rows[i].ga}')),
                              DataCell(Text('${rows[i].pts}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold, color: Colors.indigo))),
                              DataCell(Text('${rows[i].dayWins}')),
                            ]),
                        ],
                      ),
                    ),
                  ),
                ),
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Командалар аты бойынша біріктіріледі, сондықтан апта сайын бірдей атау қолданыңыз. 🏆 — ойын күнін бірінші аяқтаған саны.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
            ])),
      ]),
    );
  }
}

// ===================== ЖАЛПЫ СТАТИСТИКА (барлық апта) =====================
class StatsScreen extends StatefulWidget {
  final List<GameDay> days;
  const StatsScreen({super.key, required this.days});
  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  String sport = 'football';

  @override
  Widget build(BuildContext context) {
    final days = widget.days.where((d) => d.sport == sport).toList();
    final stats = computeStats(days);
    final total = days.fold<int>(
        0,
        (s, d) =>
            s + d.matches.fold<int>(0, (a, m) => a + m.goals.fold<int>(0, (x, g) => x + g.pts)));
    final unit = sport == 'football' ? 'гол' : 'ұпай';
    return Scaffold(
      appBar: AppBar(
        title: const Text('Жалпы статистика'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: Column(children: [
        sportBar(sport, (v) => setState(() => sport = v)),
        if (stats.isEmpty)
          const Expanded(child: Center(child: Text('Дерек жоқ')))
        else ...[
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('Ойын күні: ${days.length}  •  Барлық $unit: $total',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: stats.length,
              itemBuilder: (_, i) {
                final s = stats[i];
                return ListTile(
                  leading: PlayerAvatar(name: s.name, radius: 22),
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => PlayerScreen(name: s.name, days: days))),
                  title: Text('${i + 1}. ${s.name}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                      'Күн: ${s.days} • Матч: ${s.matches}${sport == 'football' ? ' • Ассист: ${s.assists}' : ''} • Матчқа: ${s.perMatch.toStringAsFixed(2)} $unit'),
                  trailing: Text('${kSportIcon[sport]} ${s.goals}',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                );
              },
            ),
          ),
        ],
      ]),
    );
  }
}

// ===================== ЖАҢА ОЙЫН КҮНІ =====================
class PlayersField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  const PlayersField(
      {super.key, required this.controller, required this.label, this.hint});
  @override
  State<PlayersField> createState() => _PlayersFieldState();
}

class _PlayersFieldState extends State<PlayersField> {
  void _r() => setState(() {});
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_r);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_r);
    super.dispose();
  }

  List<String> get _suggestions {
    final text = widget.controller.text;
    final i = text.lastIndexOf(',');
    final token = text.substring(i + 1).trim().toLowerCase();
    final used = parsePlayers(i < 0 ? '' : text.substring(0, i))
        .map((e) => e.toLowerCase())
        .toSet();
    return knownNames.where((n) {
      final l = n.toLowerCase();
      return !used.contains(l) && l != token && (token.isEmpty || l.contains(token));
    }).take(8).toList();
  }

  void _pick(String name) {
    final c = widget.controller;
    final i = c.text.lastIndexOf(',');
    final head = i < 0 ? '' : '${c.text.substring(0, i + 1)} ';
    c.text = '$head$name, ';
    c.selection = TextSelection.collapsed(offset: c.text.length);
  }

  @override
  Widget build(BuildContext context) {
    final sug = _suggestions;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: widget.controller,
        maxLines: null,
        decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            border: const OutlineInputBorder()),
      ),
      if (sug.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(spacing: 6, runSpacing: 0, children: [
            for (final n in sug)
              ActionChip(label: Text(n), onPressed: () => _pick(n)),
          ]),
        ),
    ]);
  }
}

Future<bool> confirmDialog(BuildContext context, String text) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Растайсыз ба?'),
      content: Text(text),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Жоқ')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Иә, өшіру')),
      ],
    ),
  );
  return r == true;
}

class NewDayScreen extends StatefulWidget {
  final GameDay? previous;
  const NewDayScreen({super.key, this.previous});
  @override
  State<NewDayScreen> createState() => _NewDayScreenState();
}

List<String> parsePlayers(String s) =>
    s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

class _NewDayScreenState extends State<NewDayScreen> {
  int count = 2;
  String sport = 'football';
  final names = List.generate(4, (i) => TextEditingController(text: 'Команда ${i + 1}'));
  final plrs = List.generate(4, (_) => TextEditingController());

  void _copyPrevious() {
    final p = widget.previous!;
    setState(() {
      count = p.teams.length.clamp(2, 4);
      sport = p.sport;
      for (var i = 0; i < count; i++) {
        names[i].text = p.teams[i];
        plrs[i].text = (p.players[p.teams[i]] ?? []).join(', ');
      }
    });
  }

  void _create() {
    final teams = <String>[];
    final players = <String, List<String>>{};
    for (var i = 0; i < count; i++) {
      var n = names[i].text.trim();
      if (n.isEmpty) n = 'Команда ${i + 1}';
      teams.add(n);
      players[n] = parsePlayers(plrs[i].text);
    }
    final now = DateTime.now();
    final date =
        '${now.day.toString().padLeft(2, '0')}.${now.month.toString().padLeft(2, '0')}.${now.year}';
    Navigator.pop(context,
        GameDay(now.millisecondsSinceEpoch.toString(), date, teams, players, [],
            now.millisecondsSinceEpoch)
          ..sport = sport);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Жаңа ойын күні'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.previous != null) ...[
            OutlinedButton.icon(
              onPressed: _copyPrevious,
              icon: const Icon(Icons.copy),
              label: Text('Өткен күннен көшіру (${widget.previous!.date})'),
            ),
            const SizedBox(height: 16),
          ],
          const Text('Спорт түрі:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              for (final k in kSportName.keys)
                ButtonSegment(
                    value: k,
                    label: Text('${kSportIcon[k]} ${kSportName[k]}',
                        style: const TextStyle(fontSize: 12))),
            ],
            selected: {sport},
            onSelectionChanged: (v) => setState(() => sport = v.first),
          ),
          const SizedBox(height: 16),
          const Text('Командалар саны:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 2, label: Text('2')),
              ButtonSegment(value: 3, label: Text('3')),
              ButtonSegment(value: 4, label: Text('4')),
            ],
            selected: {count},
            onSelectionChanged: (s) => setState(() => count = s.first),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < count; i++) ...[
            TextField(
              controller: names[i],
              decoration: InputDecoration(
                  labelText: '${i + 1}-команда атауы', border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            if (sport != 'volleyball')
              PlayersField(
              controller: plrs[i],
              label: 'Ойыншылар (үтір арқылы)',
              hint: 'Алмас, Ержан, Нұрлан',
            ),
            const SizedBox(height: 20),
          ],
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15)),
            onPressed: _create,
            icon: const Icon(Icons.check),
            label: const Text('Бастау', style: TextStyle(fontSize: 18)),
          ),
        ],
      ),
    );
  }
}

// ===================== ОЙЫНШЫЛАРДЫ ӨҢДЕУ =====================
class EditPlayersScreen extends StatefulWidget {
  final GameDay day;
  final VoidCallback onChanged;
  const EditPlayersScreen({super.key, required this.day, required this.onChanged});
  @override
  State<EditPlayersScreen> createState() => _EditPlayersScreenState();
}

class _EditPlayersScreenState extends State<EditPlayersScreen> {
  late final Map<String, TextEditingController> ctrls = {
    for (final t in widget.day.teams)
      t: TextEditingController(text: (widget.day.players[t] ?? []).join(', '))
  };

  void _save() {
    for (final t in widget.day.teams) {
      widget.day.players[t] = parsePlayers(ctrls[t]!.text);
    }
    widget.onChanged();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ойыншыларды өңдеу'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [IconButton(icon: const Icon(Icons.check), onPressed: _save)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Ескерту: бұрын соғылған голдардағы аттар өзгермейді. Ойыншының атын түзетсеңіз, ескі голдар ескі атпен қалады.',
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 16),
          for (final t in widget.day.teams) ...[
            PlayersField(
              controller: ctrls[t]!,
              label: '$t — ойыншылар (үтір арқылы)',
            ),
            const SizedBox(height: 16),
          ],
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15)),
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('Сақтау', style: TextStyle(fontSize: 18)),
          ),
        ],
      ),
    );
  }
}

// ===================== ЕСЕП КАРТАСЫ (сурет / PDF үшін) =====================
class ReportCard extends StatelessWidget {
  final GameDay day;
  const ReportCard({super.key, required this.day});

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Text(t,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.indigo)),
      );

  Widget _cell(String t, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
        child: Text(t,
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
      );

  @override
  Widget build(BuildContext context) {
    final rows = computeStandings(day);
    final scorers = computeStats([day]).where((s) => s.goals > 0 || s.assists > 0).toList();
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('⚽ $kAppName',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.indigo)),
          Text('Ойын күні: ${day.date}', style: const TextStyle(fontSize: 16)),
          _h('Матчтар'),
          if (day.matches.isEmpty) const Text('—'),
          for (final m in day.matches)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text('${m.a}  ${m.score(m.a)} : ${m.score(m.b)}  ${m.b}',
                  style: const TextStyle(fontSize: 16)),
            ),
          _h('Кесте'),
          Table(
            columnWidths: const {0: FlexColumnWidth(3)},
            defaultColumnWidth: const FlexColumnWidth(1),
            children: [
              TableRow(
                decoration: BoxDecoration(color: Colors.indigo.shade50),
                children: ['Команда', 'О', 'Ж', 'Т', 'Жғ', 'Гол', 'Ұпай']
                    .map((e) => _cell(e, bold: true))
                    .toList(),
              ),
              for (final r in rows)
                TableRow(children: [
                  _cell(r.name, bold: true),
                  _cell('${r.p}'),
                  _cell('${r.w}'),
                  _cell('${r.d}'),
                  _cell('${r.l}'),
                  _cell('${r.gf}-${r.ga}'),
                  _cell('${r.pts}', bold: true),
                ]),
            ],
          ),
          _h('Бомбардирлер'),
          if (scorers.isEmpty) const Text('—'),
          for (var i = 0; i < scorers.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text('${i + 1}. ${scorers[i].name} (${scorers[i].team}) — ${scorers[i].goals} гол, ${scorers[i].assists} ассист',
                  style: const TextStyle(fontSize: 16)),
            ),
        ],
      ),
    );
  }
}

class ReportScreen extends StatefulWidget {
  final GameDay day;
  const ReportScreen({super.key, required this.day});
  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final _key = GlobalKey();
  bool busy = false;

  Future<Uint8List> _capture() async {
    final b = _key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final img = await b.toImage(pixelRatio: 3);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() => busy = true);
    try {
      await job();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Қате: $e')));
      }
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _shareImage() => _run(() async {
        final bytes = await _capture();
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/doptep_${widget.day.id}.png');
        await f.writeAsBytes(bytes);
        await SharePlus.instance.share(ShareParams(
            files: [XFile(f.path)], text: '$kAppName — ${widget.day.date}'));
      });

  Future<void> _sharePdf() => _run(() async {
        final bytes = await _capture();
        final doc = pw.Document();
        final image = pw.MemoryImage(bytes);
        doc.addPage(pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(20),
          build: (_) => pw.Align(
              alignment: pw.Alignment.topCenter,
              child: pw.Image(image, fit: pw.BoxFit.contain)),
        ));
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/doptep_${widget.day.id}.pdf');
        await f.writeAsBytes(await doc.save());
        await SharePlus.instance.share(ShareParams(
            files: [XFile(f.path)], text: '$kAppName — ${widget.day.date}'));
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Нәтижені бөлісу'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: Column(children: [
        Expanded(
          child: SingleChildScrollView(
            child: RepaintBoundary(key: _key, child: ReportCard(day: widget.day)),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: busy
                ? const CircularProgressIndicator()
                : Row(children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _shareImage,
                        icon: const Icon(Icons.image),
                        label: const Text('Сурет'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _sharePdf,
                        icon: const Icon(Icons.picture_as_pdf),
                        label: const Text('PDF'),
                      ),
                    ),
                  ]),
          ),
        ),
      ]),
    );
  }
}

// ===================== ОЙЫН КҮНІ ЭКРАНЫ =====================
class DayScreen extends StatefulWidget {
  final GameDay day;
  final VoidCallback onChanged;
  const DayScreen({super.key, required this.day, required this.onChanged});
  @override
  State<DayScreen> createState() => _DayScreenState();
}

class _DayScreenState extends State<DayScreen> {
  GameDay get d => widget.day;

  void _r() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    syncTick.addListener(_r);
  }

  @override
  void dispose() {
    syncTick.removeListener(_r);
    super.dispose();
  }

  Future<void> _newMatch() async {
    String a = d.teams[0], b = d.teams[1];
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Жаңа матч'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButton<String>(
              isExpanded: true,
              value: a,
              items: d.teams.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
              onChanged: (v) => setD(() => a = v!),
            ),
            const Text('vs'),
            DropdownButton<String>(
              isExpanded: true,
              value: b,
              items: d.teams.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
              onChanged: (v) => setD(() => b = v!),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Бас тарту')),
            TextButton(onPressed: () => Navigator.pop(ctx, a != b), child: const Text('Құру')),
          ],
        ),
      ),
    );
    if (ok == true) {
      final m = d.sport == 'volleyball'
          ? MatchData(a, b, sets: [])
          : d.sport == 'basketball'
              ? MatchData(a, b, quarter: 1)
              : MatchData(a, b);
      setState(() => d.matches.add(m));
      widget.onChanged();
      _openMatch(m);
    }
  }

  void _openMatch(MatchData m) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => d.sport == 'football'
                ? MatchScreen(day: d, match: m, onChanged: widget.onChanged)
                : ScoreMatchScreen(day: d, match: m, onChanged: widget.onChanged)));
    setState(() {});
  }

  Widget _standings() {
    final rows = computeStandings(d);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        child: DataTable(
          columns: const [
            DataColumn(label: Text('Команда')),
            DataColumn(label: Text('О')),
            DataColumn(label: Text('Ж')),
            DataColumn(label: Text('Т')),
            DataColumn(label: Text('Жғ')),
            DataColumn(label: Text('Гол')),
            DataColumn(label: Text('Ұпай')),
          ],
          rows: rows
              .map((r) => DataRow(cells: [
                    DataCell(Text(r.name, style: const TextStyle(fontWeight: FontWeight.bold))),
                    DataCell(Text('${r.p}')),
                    DataCell(Text('${r.w}')),
                    DataCell(Text('${r.d}')),
                    DataCell(Text('${r.l}')),
                    DataCell(Text('${r.gf}-${r.ga}')),
                    DataCell(Text('${r.pts}',
                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo))),
                  ]))
              .toList(),
        ),
      ),
    );
  }

  Widget _scorers() {
    final list = computeStats([d]).where((s) => s.goals > 0 || s.assists > 0).toList();
    if (list.isEmpty) return const Center(child: Text('Әзірге гол жоқ'));
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (_, i) => ListTile(
        leading: PlayerAvatar(name: list[i].name, radius: 22),
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => PlayerScreen(
                    name: list[i].name, days: (allDaysRef.isEmpty ? [d] : allDaysRef)
                        .where((x) => x.sport == d.sport)
                        .toList()))),
        title: Text('${i + 1}. ${list[i].name}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(list[i].team),
        trailing: Text(
            '${kSportIcon[d.sport]} ${list[i].goals}${d.sport == 'football' ? ' · 🅰 ${list[i].assists}' : ''}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _matches() {
    if (d.matches.isEmpty) return const Center(child: Text('Матч жоқ. «+» басыңыз.'));
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: d.matches.length,
      itemBuilder: (_, i) {
        final m = d.matches[i];
        return Card(
          child: ListTile(
            title: Text('${m.a}  ${m.score(m.a)} : ${m.score(m.b)}  ${m.b}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(matchStatus(m)),
            leading: Icon(m.finished ? Icons.check_circle : Icons.timer,
                color: m.finished ? Colors.green : Colors.orange),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (!await confirmDialog(context, 'Бұл матч өшеді.')) return;
                setState(() => d.matches.removeAt(i));
                widget.onChanged();
              },
            ),
            onTap: () => _openMatch(m),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Ойын күні • ${d.date}'),
          backgroundColor: Colors.indigo,
          foregroundColor: Colors.white,
          actions: [
            IconButton(
              tooltip: 'Ойыншыларды өңдеу',
              icon: const Icon(Icons.group),
              onPressed: () async {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => EditPlayersScreen(day: d, onChanged: widget.onChanged)));
                setState(() {});
              },
            ),
            IconButton(
              tooltip: 'Бөлісу',
              icon: const Icon(Icons.share),
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => ReportScreen(day: d))),
            ),
          ],
          bottom: const TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            tabs: [
              Tab(icon: Icon(Icons.sports_soccer), text: 'Матчтар'),
              Tab(icon: Icon(Icons.leaderboard), text: 'Кесте'),
              Tab(icon: Icon(Icons.emoji_events), text: 'Бомбардир'),
            ],
          ),
        ),
        floatingActionButton:
            FloatingActionButton(onPressed: _newMatch, child: const Icon(Icons.add)),
        body: TabBarView(children: [_matches(), _standings(), _scorers()]),
      ),
    );
  }
}

// ===================== БАСКЕТБОЛ / ВОЛЕЙБОЛ МАТЧ ЭКРАНЫ =====================
class ScoreMatchScreen extends StatefulWidget {
  final GameDay day;
  final MatchData match;
  final VoidCallback onChanged;
  const ScoreMatchScreen(
      {super.key, required this.day, required this.match, required this.onChanged});
  @override
  State<ScoreMatchScreen> createState() => _ScoreMatchScreenState();
}

class _ScoreMatchScreenState extends State<ScoreMatchScreen> {
  MatchData get m => widget.match;
  bool get vb => m.sets != null;

  void _r() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    syncTick.addListener(_r);
  }

  @override
  void dispose() {
    syncTick.removeListener(_r);
    widget.onChanged();
    super.dispose();
  }

  Future<void> _basket(String team, int pts) async {
    final pl = widget.day.players[team] ?? [];
    final who = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('$team +$pts — кім?'),
        children: [
          for (final p in pl)
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, p), child: Text(p)),
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, kUnknown), child: const Text(kUnknown)),
        ],
      ),
    );
    if (who != null) {
      setState(() => m.goals.add(Goal(team, who, 0, '', pts, m.quarter)));
      widget.onChanged();
    }
  }

  void _point(String team, int k) {
    if (m.finished) return;
    setState(() {
      if (team == m.a) {
        m.ca = m.ca + k < 0 ? 0 : m.ca + k;
      } else {
        m.cb = m.cb + k < 0 ? 0 : m.cb + k;
      }
      final sets = m.sets!;
      final lim = sets.length == 4 ? 15 : 25; // 5-сет — 15 ұпайға дейін
      if (k > 0 && (m.ca >= lim || m.cb >= lim) && (m.ca - m.cb).abs() >= 2) {
        final w = m.ca > m.cb ? m.a : m.b;
        sets.add(VSet(m.ca, m.cb, w));
        m.ca = 0;
        m.cb = 0;
        if (m.score(w) >= 3) m.finished = true;
      }
    });
    widget.onChanged();
  }

  Widget _team(String t) {
    final cur = t == m.a ? m.ca : m.cb;
    return Expanded(
      child: Column(children: [
        Text(t,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        Text('${m.score(t)}',
            style: const TextStyle(fontSize: 64, fontWeight: FontWeight.bold, color: Colors.indigo)),
        if (vb) ...[
          Text('$cur', style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold)),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            ElevatedButton(
                onPressed: m.finished ? null : () => _point(t, 1), child: const Text('+1')),
            const SizedBox(width: 6),
            OutlinedButton(
                onPressed: m.finished ? null : () => _point(t, -1), child: const Text('−1')),
          ]),
        ] else
          Wrap(spacing: 6, alignment: WrapAlignment.center, children: [
            for (final n in [1, 2, 3])
              ElevatedButton(
                onPressed: m.finished ? null : () => _basket(t, n),
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green, foregroundColor: Colors.white),
                child: Text('+$n'),
              ),
          ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${m.a} — ${m.b}'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _team(m.a),
            const Padding(
              padding: EdgeInsets.only(top: 30),
              child: Text(':', style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold)),
            ),
            _team(m.b),
          ]),
          const SizedBox(height: 8),
          Center(
            child: Text(
                '${matchStatus(m)} · ${vb ? 'үлкен санау — сет, төменгі — ағымдағы сет' : 'ұпай есебі'}',
                style: const TextStyle(color: Colors.black54)),
          ),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (!vb && !m.finished) ...[
              OutlinedButton(
                onPressed: () {
                  setState(() => m.quarter++);
                  widget.onChanged();
                },
                child: const Text('Келесі тоқсан'),
              ),
              const SizedBox(width: 12),
            ],
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                  backgroundColor: m.finished ? Colors.orange : Colors.grey[800],
                  foregroundColor: Colors.white),
              onPressed: () {
                setState(() => m.finished = !m.finished);
                widget.onChanged();
              },
              icon: Icon(m.finished ? Icons.lock_open : Icons.flag),
              label: Text(m.finished ? 'Қайта ашу' : 'Матчты аяқтау'),
            ),
          ]),
          const Divider(height: 30),
          Text(vb ? 'Сеттер' : 'Ұпайлар',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          if (vb) ...[
            if (m.sets!.isEmpty)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('Сет әлі аяқталған жоқ (25 ұпай, 2 ұпай айырма; 5-сет — 15)'),
              ),
            for (var i = 0; i < m.sets!.length; i++)
              ListTile(
                dense: true,
                title: Text('${i + 1}-сет: ${m.sets![i].a} : ${m.sets![i].b}'),
                trailing: Text(m.sets![i].w, style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
          ] else ...[
            if (m.goals.isEmpty)
              const Padding(padding: EdgeInsets.all(8), child: Text('Ұпай жоқ')),
            for (var i = 0; i < m.goals.length; i++)
              ListTile(
                dense: true,
                title: Text('${m.goals[i].quarter}-тоқсан · ${m.goals[i].player} (${m.goals[i].team})'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('+${m.goals[i].pts}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  if (!m.finished)
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        setState(() => m.goals.removeAt(i));
                        widget.onChanged();
                      },
                    ),
                ]),
              ),
          ],
        ],
      ),
    );
  }
}

// ===================== МАТЧ ЭКРАНЫ =====================
class MatchScreen extends StatefulWidget {
  final GameDay day;
  final MatchData match;
  final VoidCallback onChanged;
  const MatchScreen(
      {super.key, required this.day, required this.match, required this.onChanged});
  @override
  State<MatchScreen> createState() => _MatchScreenState();
}

class _MatchScreenState extends State<MatchScreen> {
  MatchData get m => widget.match;
  Timer? _timer;

  bool get running => _timer != null;

  void _r() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    syncTick.addListener(_r);
  }

  void _break() {
    _timer?.cancel();
    _timer = null;
    setState(() => m.onBreak = true);
    widget.onChanged();
  }

  void _start() {
    if (m.onBreak) {
      m.onBreak = false;
      m.half = 2;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => m.seconds++);
      if (m.seconds % 15 == 0) widget.onChanged();
    });
    setState(() {});
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    widget.onChanged();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    syncTick.removeListener(_r);
    _timer?.cancel();
    widget.onChanged();
    super.dispose();
  }

  String get _clock {
    final mm = (m.seconds ~/ 60).toString().padLeft(2, '0');
    final ss = (m.seconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  Future<void> _goal(String team) async {
    final pl = widget.day.players[team] ?? [];
    final who = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('$team — гол кімнен?'),
        children: [
          for (final p in pl)
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, p), child: Text(p)),
          SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, kUnknown), child: const Text(kUnknown)),
        ],
      ),
    );
    if (who != null) {
      final others = pl.where((p) => p != who).toList();
      var assist = '';
      if (others.isNotEmpty && mounted) {
        final a = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('Ассист кімнен?'),
            children: [
              for (final p in others)
                SimpleDialogOption(onPressed: () => Navigator.pop(ctx, p), child: Text(p)),
              SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, ''), child: const Text('Ассистсіз')),
            ],
          ),
        );
        assist = a ?? '';
      }
      setState(() => m.goals.add(
          Goal(team, who, m.seconds == 0 ? 0 : m.seconds ~/ 60 + 1, assist)));
      widget.onChanged();
    }
  }

  Widget _team(String t) => Expanded(
        child: Column(children: [
          Text(t,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center),
          Text('${m.score(t)}',
              style: const TextStyle(fontSize: 64, fontWeight: FontWeight.bold, color: Colors.indigo)),
          ElevatedButton(
            onPressed: (m.finished || m.onBreak) ? null : () => _goal(t),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green, foregroundColor: Colors.white),
            child: const Text('+1 Гол', style: TextStyle(fontSize: 18)),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${m.a} — ${m.b}'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _team(m.a),
            const Padding(
              padding: EdgeInsets.only(top: 30),
              child: Text(':', style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold)),
            ),
            _team(m.b),
          ]),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.timer_outlined),
            const SizedBox(width: 8),
            Text(_clock,
                style: const TextStyle(
                    fontSize: 32, fontWeight: FontWeight.bold, fontFeatures: [ui.FontFeature.tabularFigures()])),
            const SizedBox(width: 12),
            IconButton.filled(
              onPressed: m.finished ? null : (running ? _stop : _start),
              icon: Icon(running ? Icons.pause : Icons.play_arrow),
            ),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(
              m.finished ? 'Аяқталды' : (m.onBreak ? 'Перерыв' : '${m.half}-тайм'),
              style: const TextStyle(fontSize: 16, color: Colors.black54),
            ),
            if (running && m.half == 1 && !m.onBreak)
              TextButton.icon(
                onPressed: _break,
                icon: const Icon(Icons.free_breakfast_outlined),
                label: const Text('Перерыв'),
              ),
          ]),
          const Divider(height: 30),
          const Align(
              alignment: Alignment.centerLeft,
              child: Text('Голдар', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          Expanded(
            child: ListView.builder(
              itemCount: m.goals.length,
              itemBuilder: (_, i) {
                final g = m.goals[i];
                final min = g.minute > 0 ? "${g.minute}'" : '';
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.sports_soccer, size: 20),
                  title: Text('$min ${g.player} (${g.team})'.trim()),
                  subtitle: g.assist.isEmpty ? null : Text('Ассист: ${g.assist}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: m.finished
                        ? null
                        : () {
                            setState(() => m.goals.removeAt(i));
                            widget.onChanged();
                          },
                  ),
                );
              },
            ),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: m.finished ? Colors.orange : Colors.grey[800],
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15)),
            onPressed: () {
              setState(() => m.finished = !m.finished);
              if (m.finished) {
                m.onBreak = false;
                _stop();
              }
              widget.onChanged();
            },
            icon: Icon(m.finished ? Icons.lock_open : Icons.flag),
            label: Text(m.finished ? 'Қайта ашу' : 'Матчты аяқтау',
                style: const TextStyle(fontSize: 18)),
          ),
        ]),
      ),
    );
  }
}
