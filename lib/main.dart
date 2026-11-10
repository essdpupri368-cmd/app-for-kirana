import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

void main() => runApp(const App());

// ---------- Models ----------
// type: 0 = खुला (weight), 1 = पैकेट (count), 2 = अलग-अलग वज़न के पैकेट
class Node {
  String name; int type; double price; List<Node> kids;
  Node(this.name, {this.type = 0, this.price = 0, this.kids = const []});
  bool get leaf => kids.isEmpty;
}

class Line {
  Node n; int qty; List<int> w; double price;
  Line(this.n, this.qty, this.w, this.price);
  int get totalG => n.type == 2 ? w.fold(0, (a, b) => a + b) : qty;
  double get amount => n.type == 1 ? qty * price : totalG / 1000 * price;
  bool get complete => n.name.isNotEmpty && qty > 0 && price > 0;
}

String fmtG(int g) => g < 1000 ? '$g ग्राम'
    : '${(g / 1000).toStringAsFixed(3).replaceAll(RegExp(r'\.?0+$'), '')} किग्रा';

String fmtQty(Line l) {
  if (l.qty == 0) return '—';
  if (l.n.type == 1) return '${l.qty} नग';
  if (l.n.type == 2) return '${l.w.map((e) => e).join(',')} = ${fmtG(l.totalG)}';
  return fmtG(l.qty);
}

// ---------- Data (stage 1: in memory) ----------
final root = <Node>[
  Node('चावल', kids: [Node('इंडिया गेट', price: 120), Node('सोना मसूरी', price: 55)]),
  Node('दालें', kids: [Node('अरहर दाल', price: 140), Node('मूंग दाल', price: 120)]),
  Node('बिस्कुट', kids: [Node('पारले-जी', type: 1, price: 10), Node('गुड डे', type: 1, price: 30)]),
  Node('चीनी', kids: [Node('चीनी (खुली)', price: 45), Node('चीनी पैकेट', type: 2, price: 45)]),
];
final List<Line> bill = [];
int billNo = 1;
final nav = GlobalKey<NavigatorState>();

// ---------- App ----------
class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        navigatorKey: nav,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          scaffoldBackgroundColor: Colors.white,
          textTheme: const TextTheme(bodyMedium: TextStyle(fontSize: 18)),
        ),
        home: const Home(),
      );
}

Widget btn(String t, Color col, VoidCallback f) => Padding(
      padding: const EdgeInsets.all(4),
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(backgroundColor: col, foregroundColor: Colors.white,
            minimumSize: const Size(70, 52), textStyle: const TextStyle(fontSize: 18)),
        onPressed: f, child: Text(t)),
    );

Widget grid(List<Node> items, void Function(Node) tap, int cols) => GridView.count(
      shrinkWrap: true, crossAxisCount: cols, mainAxisSpacing: 6, crossAxisSpacing: 6,
      children: [
        for (final n in items)
          InkWell(
            onTap: () => tap(n),
            child: Card(color: Colors.blue.shade50,
              child: Center(child: Text(n.name, textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)))),
          )
      ]);

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  bool edit = false;

  Future<void> open(Node n) async {
    if (n.leaf) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      final l = await entry(n, null);
      if (l != null) {
        bill.add(l);
        SystemSound.play(SystemSoundType.click);
        HapticFeedback.heavyImpact();
        setState(() {});
      }
      return;
    }
    await showGeneralDialog(
      context: context, barrierDismissible: true, barrierLabel: '',
      transitionDuration: const Duration(milliseconds: 250),
      transitionBuilder: (c, a, _, child) => ScaleTransition(scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack), child: child),
      pageBuilder: (c, _, __) => Center(
        child: Material(borderRadius: BorderRadius.circular(16),
          child: Container(width: 560, padding: const EdgeInsets.all(12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(n.name, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              SizedBox(height: 360, child: grid(n.kids, open, 4)),
              btn('वापस', Colors.blue, () => Navigator.pop(c)),
            ]))),
      ));
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => setState(() => edit = !edit)),
          centerTitle: true,
          title: Text(DateFormat('dd-MM-yyyy').format(DateTime.now())),
          actions: [
            TextButton.icon(
              icon: const Icon(Icons.receipt_long),
              label: Text('बिल देखें (${bill.length})', style: const TextStyle(fontSize: 18)),
              onPressed: () async { await Navigator.push(c, MaterialPageRoute(builder: (_) => const Preview())); setState(() {}); },
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(8),
          child: grid(root, open, 8),
        ),
      );
}

// ---------- Entry flow: quantity -> price ----------
Future<Line?> entry(Node n, Line? old) async {
  final ctx = nav.currentContext!;
  int qty = old?.qty ?? 0; List<int> w = old?.w ?? [];
  if (n.type == 0) {
    final q = await askNum(ctx, n.name, [5, 10, 50, 100, 500, 1000, 5000, 10000, 50000, 100000], fmtG, 'ग्राम में लिखें', qty);
    if (q == null) return null; qty = q;
  } else {
    final q = await askNum(ctx, n.name, List.generate(10, (i) => i + 1), (v) => '$v', 'नग लिखें', qty);
    if (q == null) return null; qty = q; w = [];
    if (n.type == 2) {
      for (var i = 1; i <= qty; i++) {
        final g = await askNum(ctx, '${n.name} – पैकेट $i', [50, 100, 250, 500, 1000, 5000], fmtG, 'ग्राम में लिखें', 0);
        if (g == null) return null; w.add(g);
      }
    }
  }
  final temp = Line(n, qty, w, n.price);
  final p = await askPrice(ctx, '${n.name} – ${fmtQty(temp)}', old?.price ?? n.price);
  if (p == null) return null;
  n.price = p; // default price is updated
  return Line(n, qty, w, p);
}

Future<int?> askNum(BuildContext c, String title, List<int> opts, String Function(int) lab, String hint, int init) {
  int v = init;
  final ctl = TextEditingController(text: init > 0 ? '$init' : '');
  return showDialog<int>(context: c, barrierDismissible: false, builder: (c) => StatefulBuilder(
    builder: (c, set) => AlertDialog(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      content: SizedBox(width: 520, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: ctl, keyboardType: TextInputType.number, style: const TextStyle(fontSize: 24),
          decoration: InputDecoration(labelText: hint, border: const OutlineInputBorder()),
          onChanged: (s) => v = int.tryParse(s) ?? 0),
        const SizedBox(height: 6),
        Text(lab(v), style: const TextStyle(fontSize: 22, color: Colors.blue)),
        Wrap(children: [for (final o in opts) btn(lab(o), Colors.blue.shade400, () { v += o; ctl.text = '$v'; set(() {}); })]),
      ])),
      actions: [
        btn('वापस', Colors.blue, () => Navigator.pop(c)),
        btn('साफ़ करें', Colors.red, () { v = 0; ctl.clear(); set(() {}); }),
        btn('आगे', Colors.green, () => Navigator.pop(c, v)), // blank is allowed
      ],
    )));
}

Future<double?> askPrice(BuildContext c, String title, double def) {
  String s = def > 0 ? def.toString().replaceAll(RegExp(r'\.0$'), '') : '';
  bool fresh = true; // first key press clears old content
  return showDialog<double>(context: c, barrierDismissible: false, builder: (c) => StatefulBuilder(
    builder: (c, set) {
      void key(String k) => set(() {
        if (fresh) { s = ''; fresh = false; }
        if (k == '<') { if (s.isNotEmpty) s = s.substring(0, s.length - 1); }
        else if (k == '.' && s.contains('.')) {} else { s += k; }
      });
      return AlertDialog(
        title: Text(title),
        content: SizedBox(width: 360, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: double.infinity, padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(border: Border.all(color: Colors.blue), borderRadius: BorderRadius.circular(8)),
            child: Text('₹ ${s.isEmpty ? '' : s}', style: const TextStyle(fontSize: 30))),
          Wrap(alignment: WrapAlignment.center, children: [
            for (final k in ['1','2','3','4','5','6','7','8','9','.','0','<']) btn(k, Colors.blue.shade400, () => key(k)),
          ]),
        ])),
        actions: [
          btn('वापस', Colors.blue, () => Navigator.pop(c)),
          btn('साफ़ करें', Colors.red, () => set(() { s = ''; fresh = false; })),
          btn('आगे', Colors.green, () => Navigator.pop(c, double.tryParse(s) ?? 0)),
        ],
      );
    }));
}

// ---------- Preview ----------
class Preview extends StatefulWidget {
  const Preview({super.key});
  @override
  State<Preview> createState() => _PreviewState();
}

class _PreviewState extends State<Preview> {
  double get total => bill.fold(0, (a, l) => a + l.amount);

  void print_() {
    final bad = bill.indexWhere((l) => !l.complete);
    if (bill.isEmpty || bad >= 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.red,
        content: Text(bill.isEmpty ? 'बिल खाली है' : 'क्रम ${bad + 1}: मात्रा या भाव अधूरा है')));
      return;
    }
    // TODO stage 3: save bill + Bluetooth print (bitmap)
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('बिल नं. $billNo सेव हुआ')));
    billNo++; bill.clear(); Navigator.pop(context);
  }

  @override
  Widget build(BuildContext c) {
    const h = TextStyle(fontWeight: FontWeight.bold, fontSize: 18);
    return Scaffold(
      appBar: AppBar(title: Text('बिल नं. $billNo')),
      body: Column(children: [
        const Padding(padding: EdgeInsets.all(8), child: Row(children: [
          SizedBox(width: 50, child: Text('क्र.', style: h)), SizedBox(width: 100, child: Text('राशि', style: h)),
          Expanded(child: Text('सामान', style: h)), SizedBox(width: 170, child: Text('मात्रा', style: h)),
          SizedBox(width: 80, child: Text('भाव', style: h)),
        ])),
        const Divider(),
        Expanded(child: ListView.separated(
          itemCount: bill.length, separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (c, i) { final l = bill[i]; return InkWell(
            onTap: () async { final r = await entry(l.n, l); if (r != null) setState(() => bill[i] = r); },
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8), child: Row(children: [
              SizedBox(width: 50, child: Text('${i + 1}')),
              SizedBox(width: 100, child: Text(l.complete ? l.amount.toStringAsFixed(2) : '—')),
              Expanded(child: Text(l.n.name)), SizedBox(width: 170, child: Text(fmtQty(l))),
              SizedBox(width: 80, child: Text(l.price > 0 ? '${l.price}' : '—')),
            ])));
          })),
        Container(color: Colors.blue.shade50, padding: const EdgeInsets.all(12),
          child: Row(children: [
            Text('कुल: ₹ ${total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const Spacer(),
            btn('वापस', Colors.blue, () => Navigator.pop(c)),
            btn('प्रिंट', Colors.green, print_),
          ])),
      ]),
    );
  }
}
