import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:excel/excel.dart' as xl;

const shopName = 'मेरी दुकान'; // <- अपनी दुकान का नाम यहाँ बदलें
final nav = GlobalKey<NavigatorState>();
final tick = ValueNotifier<int>(0);
final editMode = ValueNotifier<bool>(false);
const palette = [0xFFE3F2FD, 0xFFE8F5E9, 0xFFFFF3E0, 0xFFFCE4EC, 0xFFF3E5F5, 0xFFFFFDE7, 0xFFE0F2F1, 0xFFEFEBE9];

// ---------- Models ----------
// type: 0 = खुला (weight), 1 = पैकेट (count), 2 = अलग-अलग वज़न के पैकेट
class Node {
  String name; int type; double price; int color; String bar; List<Node> kids;
  Node(this.name, {this.type = 0, this.price = 0, this.color = 0xFFE3F2FD, this.bar = '', List<Node>? kids}) : kids = kids ?? [];
  bool get leaf => kids.isEmpty;
  Map toJson() => {'n': name, 't': type, 'p': price, 'c': color, 'b': bar, 'k': kids.map((e) => e.toJson()).toList()};
  factory Node.fromJson(Map j) => Node(j['n'], type: j['t'], price: (j['p'] as num).toDouble(), color: j['c'], bar: j['b'],
      kids: (j['k'] as List).map((e) => Node.fromJson(e)).toList());
}

class Line {
  Node n; int qty; List<int> w; double price;
  Line(this.n, this.qty, this.w, this.price);
  int get totalG => n.type == 2 ? w.fold(0, (a, b) => a + b) : qty;
  double get amount => n.type == 1 ? qty * price : totalG / 1000 * price;
  bool get complete => n.name.isNotEmpty && qty > 0 && price > 0;
  Map toJson() => {'n': n.name, 't': n.type, 'q': qty, 'w': w, 'p': price, 'b': n.bar};
  factory Line.fromJson(Map j) => Line(Node(j['n'], type: j['t'], bar: j['b'] ?? ''), j['q'], List<int>.from(j['w']), (j['p'] as num).toDouble());
}

class Bill {
  int no; DateTime dt; List<Line> lines;
  Bill(this.no, this.dt, this.lines);
  double get total => lines.fold(0.0, (a, l) => a + l.amount);
  Map toJson() => {'no': no, 'd': dt.toIso8601String(), 'l': lines.map((e) => e.toJson()).toList()};
  factory Bill.fromJson(Map j) => Bill(j['no'], DateTime.parse(j['d']), (j['l'] as List).map((e) => Line.fromJson(e)).toList());
}

class S {
  static List<Node> root = [];
  static List<Bill> hist = [], drafts = [];
  static late Bill cur;
  static int next = 1;
  static String printer = '';
  static late SharedPreferences p;
  static Bill newBill() => Bill(next++, DateTime.now(), []);
  static Future<void> load() async {
    p = await SharedPreferences.getInstance();
    final s = p.getString('d');
    if (s != null) {
      try {
        final j = jsonDecode(s);
        root = (j['r'] as List).map((e) => Node.fromJson(e)).toList();
        hist = (j['h'] as List).map((e) => Bill.fromJson(e)).toList();
        drafts = (j['dr'] as List).map((e) => Bill.fromJson(e)).toList();
        cur = Bill.fromJson(j['c']); next = j['n']; printer = j['pr'];
        return;
      } catch (_) {}
    }
    root = [
      Node('चावल', color: palette[0], kids: [Node('इंडिया गेट', price: 120), Node('सोना मसूरी', price: 55)]),
      Node('दालें', color: palette[1], kids: [Node('अरहर दाल', price: 140), Node('मूंग दाल', price: 120)]),
      Node('बिस्कुट', color: palette[2], kids: [Node('पारले-जी', type: 1, price: 10), Node('गुड डे', type: 1, price: 30)]),
      Node('चीनी', color: palette[3], kids: [Node('चीनी (खुली)', price: 45), Node('चीनी पैकेट', type: 2, price: 45)]),
    ];
    cur = newBill();
  }
  static void save() => p.setString('d', jsonEncode({
        'r': root.map((e) => e.toJson()).toList(), 'h': hist.map((e) => e.toJson()).toList(),
        'dr': drafts.map((e) => e.toJson()).toList(), 'c': cur.toJson(), 'n': next, 'pr': printer}));
}

// ---------- Helpers ----------
bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
String fmtG(int g) => g < 1000 ? '$g ग्राम' : '${(g / 1000).toStringAsFixed(3).replaceAll(RegExp(r'\.?0+$'), '')} किग्रा';
String fmtP(double p) => p == p.roundToDouble() ? '${p.toInt()}' : '$p';
String fmtQty(Line l) {
  if (l.qty == 0) return '—';
  if (l.n.type == 1) return '${l.qty} नग';
  if (l.n.type == 2) return '${l.w.join(',')} / ${fmtG(l.totalG)}';
  return fmtG(l.qty);
}
String qp(Line l) => '${l.qty == 0 ? '—' : fmtQty(l)} × ${l.price == 0 ? '—' : fmtP(l.price)}';
void snack(String t, {bool err = false}) => ScaffoldMessenger.of(nav.currentContext!)
    .showSnackBar(SnackBar(backgroundColor: err ? Colors.red : null, content: Text(t)));
void feedback() { SystemSound.play(SystemSoundType.click); HapticFeedback.heavyImpact(); }

Widget btn(String t, Color col, VoidCallback f) => Padding(
      padding: const EdgeInsets.all(4),
      child: ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: col, foregroundColor: Colors.white,
              minimumSize: const Size(64, 50), textStyle: const TextStyle(fontSize: 18)),
          onPressed: f, child: Text(t)));

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await S.load();
  runApp(MaterialApp(
    navigatorKey: nav, debugShowCheckedModeBanner: false,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue), scaffoldBackgroundColor: Colors.white,
        textTheme: const TextTheme(bodyMedium: TextStyle(fontSize: 18))),
    home: const Home()));
}

// ---------- Bill image (used for print, JPG share, PDF) ----------
Future<ui.Image> billImg(Bill b, double s) async {
  final w = 384.0 * s;
  final rec = ui.PictureRecorder();
  final cv = Canvas(rec);
  cv.drawRect(Rect.fromLTWH(0, 0, w, 100000), Paint()..color = Colors.white);
  double y = 4 * s;
  double tp(String t, double x, double wd, double sz, bool bold, TextAlign al) {
    final p = TextPainter(
        text: TextSpan(text: t, style: TextStyle(color: Colors.black, fontSize: sz * s, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        textDirection: TextDirection.ltr, textAlign: al)..layout(minWidth: wd * s, maxWidth: wd * s);
    p.paint(cv, Offset(x * s, y));
    return p.height;
  }
  void row(List<List> cols, {double sz = 20, bool bold = false}) {
    double h = 0;
    for (final c in cols) { h = math.max(h, tp(c[0], c[1], c[2], sz, bold, c.length > 3 ? c[3] : TextAlign.left)); }
    y += h;
  }
  void line() { cv.drawLine(Offset(0, y + 2 * s), Offset(w, y + 2 * s), Paint()..color = Colors.black..strokeWidth = s); y += 6 * s; }
  row([[shopName, 0.0, 384.0, TextAlign.center]], sz: 26, bold: true);
  row([['बिल नं. ${b.no}   ${DateFormat('dd-MM-yyyy HH:mm').format(b.dt)}', 0.0, 384.0, TextAlign.center]], sz: 18);
  line();
  row([['क्र.', 0.0, 28.0], ['राशि', 28.0, 84.0, TextAlign.right], ['सामान / मात्रा × भाव', 120.0, 264.0]], sz: 17, bold: true);
  line();
  for (var i = 0; i < b.lines.length; i++) {
    final l = b.lines[i];
    row([['${i + 1}', 0.0, 28.0], [l.complete ? l.amount.toStringAsFixed(2) : '—', 28.0, 84.0, TextAlign.right], [l.n.name, 120.0, 264.0]]);
    row([[qp(l), 120.0, 264.0]], sz: 18);
    y += 3 * s;
  }
  line();
  row([['कुल: ₹ ${b.total.toStringAsFixed(2)}', 0.0, 384.0, TextAlign.right]], sz: 26, bold: true);
  row([['धन्यवाद', 0.0, 384.0, TextAlign.center]], sz: 18);
  return rec.endRecording().toImage(w.toInt(), (y + 10 * s).toInt());
}

Future<Uint8List> pngOf(Bill b, double s) async =>
    (await (await billImg(b, s)).toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();

Future<bool> pickPrinter(BuildContext c) async {
  final l = await PrintBluetoothThermal.pairedBluetooths;
  if (l.isEmpty) { snack('पहले Bluetooth सेटिंग में प्रिंटर पेयर करें', err: true); return false; }
  final m = await showDialog<String>(context: c, builder: (c) => SimpleDialog(title: const Text('प्रिंटर चुनें'), children: [
        for (final d in l) SimpleDialogOption(onPressed: () => Navigator.pop(c, d.macAdress), child: Text('${d.name}  ${d.macAdress}'))]));
  if (m == null) return false;
  S.printer = m; S.save();
  await PrintBluetoothThermal.disconnect;
  return true;
}

Future<String?> printBill(BuildContext c, Bill b) async {
  try {
    if (S.printer.isEmpty && !await pickPrinter(c)) return 'प्रिंटर नहीं चुना';
    if (!await PrintBluetoothThermal.connectionStatus) {
      if (!await PrintBluetoothThermal.connect(macPrinterAddress: S.printer)) return 'प्रिंटर से कनेक्ट नहीं हुआ';
    }
    var im = img.decodePng(await pngOf(b, 2))!;
    im = img.copyResize(im, width: 384);
    final g = Generator(PaperSize.mm58, await CapabilityProfile.load());
    final bytes = <int>[...g.imageRaster(im), ...g.feed(3)];
    await PrintBluetoothThermal.writeBytes(bytes);
    return null;
  } catch (e) { return 'प्रिंट त्रुटि: $e'; }
}

Future<void> shareJpg(Bill b) async {
  final im = img.decodePng(await pngOf(b, 3))!;
  final f = File('${(await getTemporaryDirectory()).path}/bill_${b.no}.jpg')..writeAsBytesSync(img.encodeJpg(im, quality: 95));
  await Share.shareXFiles([XFile(f.path)], text: 'बिल नं. ${b.no}');
}

Future<File> billsPdf(List<Bill> bs) async {
  final doc = pw.Document();
  const pf = PdfPageFormat.a4; const m = 20.0;
  final cw = (pf.width - 2 * m) / 3, ph = pf.height - 2 * m;
  final pages = <List<pw.Widget>>[[]];
  var col = 0; var y = 0.0;
  for (final b in bs) {
    final im = await billImg(b, 2);
    final bytes = (await im.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    final h = im.height * cw / im.width;
    if (y + h > ph && y > 0) { col++; y = 0; if (col > 2) { col = 0; pages.add([]); } }
    pages.last.add(pw.Positioned(left: col * cw, top: y, child: pw.Image(pw.MemoryImage(bytes), width: cw)));
    y += h + 6;
  }
  for (final p in pages) {
    doc.addPage(pw.Page(pageFormat: pf, margin: const pw.EdgeInsets.all(m), build: (_) => pw.Stack(children: p)));
  }
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/bills_${DateFormat('dd-MM-yyyy').format(DateTime.now())}.pdf')..writeAsBytesSync(await doc.save());
}

Future<void> excelRange(DateTimeRange r) async {
  final e = xl.Excel.createExcel();
  e.rename('Sheet1', 'सारांश');
  final s1 = e['सारांश']; final s2 = e['सभी बिल'];
  xl.TextCellValue t(String s) => xl.TextCellValue(s);
  s1.appendRow([t('बिल नं.'), t('दिनांक'), t('मदें'), t('कुल राशि')]);
  s2.appendRow([t('बिल नं.'), t('दिनांक'), t('क्र.'), t('सामान'), t('मात्रा'), t('भाव'), t('राशि')]);
  final bs = S.hist.where((b) => !b.dt.isBefore(r.start) && b.dt.isBefore(r.end.add(const Duration(days: 1)))).toList()
    ..sort((a, b) => a.dt.compareTo(b.dt));
  for (final b in bs) {
    final d = DateFormat('dd-MM-yyyy').format(b.dt);
    s1.appendRow([xl.IntCellValue(b.no), t(d), xl.IntCellValue(b.lines.length), xl.DoubleCellValue(b.total)]);
    for (var i = 0; i < b.lines.length; i++) {
      final l = b.lines[i];
      s2.appendRow([xl.IntCellValue(b.no), t(d), xl.IntCellValue(i + 1), t(l.n.name), t(fmtQty(l)), xl.DoubleCellValue(l.price), xl.DoubleCellValue(l.amount)]);
    }
  }
  final dir = await getApplicationDocumentsDirectory();
  final f = File('${dir.path}/bills.xlsx')..writeAsBytesSync(e.encode()!);
  await Share.shareXFiles([XFile(f.path)]);
}

// ---------- Scanner ----------
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanState();
}
class _ScanState extends State<ScanPage> {
  bool done = false;
  @override
  Widget build(BuildContext c) => Scaffold(
      appBar: AppBar(title: const Text('स्कैन करें')),
      body: MobileScanner(onDetect: (cap) {
        if (done) return;
        final v = cap.barcodes.isNotEmpty ? cap.barcodes.first.rawValue : null;
        if (v != null) { done = true; Navigator.pop(c, v); }
      }));
}
Future<String?> scanOnce(BuildContext c) => Navigator.push<String>(c, MaterialPageRoute(builder: (_) => const ScanPage()));
Node? findBar(List<Node> l, String code) {
  for (final n in l) { if (n.bar == code) return n; final r = findBar(n.kids, code); if (r != null) return r; }
  return null;
}
Future<void> onScan(String code) async {
  final n = findBar(S.root, code);
  if (n == null) { snack('बारकोड नहीं मिला – आइटम एडिट में बारकोड जोड़ें', err: true); return; }
  final i = S.cur.lines.indexWhere((l) => l.n.name == n.name && n.type == 1 && l.n.type == 1);
  if (i >= 0) { S.cur.lines[i].qty++; S.save(); feedback(); tick.value++; return; }
  final l = await entry(n, null);
  if (l != null) addLine(l);
}
void addLine(Line l) { S.cur.lines.add(l); S.save(); feedback(); tick.value++; }

// ---------- Grid / dialogs ----------
Future<void> openNode(Node n) async {
  if (n.leaf) {
    nav.currentState!.popUntil((r) => r.isFirst);
    final l = await entry(n, null);
    if (l != null) addLine(l);
    return;
  }
  showKids(n);
}

Widget tiles(List<Node> items, int cols, {bool add = true}) {
  final ed = editMode.value && add;
  return GridView.count(
      shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), crossAxisCount: cols,
      mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: .95,
      children: [
        for (final n in items)
          InkWell(
            onTap: () => ed ? editNode(nav.currentContext!, n, items) : openNode(n),
            child: Stack(children: [
              Card(color: Color(n.color), margin: EdgeInsets.zero, child: Center(child: Padding(padding: const EdgeInsets.all(3),
                  child: Text(n.name, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))))),
              if (ed) const Positioned(top: 3, right: 3, child: Icon(Icons.edit, size: 16)),
            ])),
        if (ed)
          InkWell(onTap: () { items.add(Node('नया')); S.save(); tick.value++; },
              child: const Card(margin: EdgeInsets.zero, child: Center(child: Icon(Icons.add, size: 36)))),
      ]);
}

void showKids(Node n) {
  showGeneralDialog(
      context: nav.currentContext!, barrierDismissible: true, barrierLabel: '',
      transitionDuration: const Duration(milliseconds: 250),
      transitionBuilder: (c, a, _, child) => ScaleTransition(scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack), child: child),
      pageBuilder: (c, _, __) => Center(
          child: Material(borderRadius: BorderRadius.circular(16),
              child: Container(width: math.min(560.0, MediaQuery.of(c).size.width * .92), padding: const EdgeInsets.all(12),
                  child: AnimatedBuilder(animation: Listenable.merge([tick, editMode]), builder: (c, _) => Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(n.name, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        ConstrainedBox(constraints: const BoxConstraints(maxHeight: 380), child: SingleChildScrollView(child: tiles(n.kids, 4))),
                        btn('वापस', Colors.blue, () => Navigator.pop(c)),
                      ]))))));
}

Future<void> editNode(BuildContext c, Node n, List<Node> list) async {
  final nm = TextEditingController(text: n.name);
  final pr = TextEditingController(text: n.price == 0 ? '' : fmtP(n.price));
  final bc = TextEditingController(text: n.bar);
  int t = n.type, col = n.color;
  void apply() { n.name = nm.text; n.price = double.tryParse(pr.text) ?? 0; n.type = t; n.bar = bc.text; n.color = col; S.save(); tick.value++; }
  await showDialog(context: c, builder: (c) => StatefulBuilder(builder: (c, set) => AlertDialog(
        title: const Text('बदलाव करें'),
        content: SingleChildScrollView(child: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nm, decoration: const InputDecoration(labelText: 'नाम')),
          TextField(controller: pr, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'भाव (₹)')),
          DropdownButton<int>(value: t, isExpanded: true, onChanged: (v) => set(() => t = v!), items: const [
            DropdownMenuItem(value: 0, child: Text('खुला (वज़न से)')),
            DropdownMenuItem(value: 1, child: Text('पैकेट (गिनती से)')),
            DropdownMenuItem(value: 2, child: Text('अलग-अलग वज़न के पैकेट'))]),
          TextField(controller: bc, decoration: InputDecoration(labelText: 'बारकोड', suffixIcon: IconButton(
              icon: const Icon(Icons.qr_code_scanner), onPressed: () async { final r = await scanOnce(c); if (r != null) set(() => bc.text = r); }))),
          const SizedBox(height: 8),
          Wrap(children: [for (final k in palette) GestureDetector(onTap: () => set(() => col = k),
              child: Container(margin: const EdgeInsets.all(4), width: 36, height: 36,
                  decoration: BoxDecoration(color: Color(k), shape: BoxShape.circle, border: Border.all(width: col == k ? 3 : 1))))]),
        ]))),
        actions: [
          btn('हटाएँ', Colors.red, () { list.remove(n); S.save(); tick.value++; Navigator.pop(c); }),
          btn('अंदर खोलें', Colors.blue, () { apply(); Navigator.pop(c); showKids(n); }),
          btn('सेव', Colors.green, () { apply(); Navigator.pop(c); }),
        ],
      )));
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
  n.price = p; S.save();
  return Line(n, qty, w, p);
}

Future<int?> askNum(BuildContext c, String title, List<int> opts, String Function(int) lab, String hint, int init) {
  int v = init;
  final ctl = TextEditingController(text: init > 0 ? '$init' : '');
  return showDialog<int>(context: c, barrierDismissible: false, builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            content: SingleChildScrollView(child: SizedBox(width: 520, child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: ctl, keyboardType: TextInputType.number, style: const TextStyle(fontSize: 24),
                  decoration: InputDecoration(labelText: hint, border: const OutlineInputBorder()),
                  onChanged: (s) => set(() => v = int.tryParse(s) ?? 0)),
              const SizedBox(height: 6),
              Text(lab(v), style: const TextStyle(fontSize: 22, color: Colors.blue)),
              Wrap(children: [for (final o in opts) btn(lab(o), Colors.blue.shade400, () { v += o; ctl.text = '$v'; set(() {}); })]),
            ]))),
            actions: [
              btn('वापस', Colors.blue, () => Navigator.pop(c)),
              btn('साफ़ करें', Colors.red, () { v = 0; ctl.clear(); set(() {}); }),
              btn('आगे', Colors.green, () => Navigator.pop(c, v)),
            ],
          )));
}

Future<double?> askPrice(BuildContext c, String title, double def) {
  String s = def > 0 ? fmtP(def) : '';
  bool fresh = true;
  return showDialog<double>(context: c, barrierDismissible: false, builder: (c) => StatefulBuilder(builder: (c, set) {
        void key(String k) => set(() {
              if (fresh) { s = ''; fresh = false; }
              if (k == '<') { if (s.isNotEmpty) s = s.substring(0, s.length - 1); }
              else if (k == '.' && s.contains('.')) {} else { s += k; }
            });
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: SizedBox(width: 360, child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(width: double.infinity, padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(border: Border.all(color: Colors.blue), borderRadius: BorderRadius.circular(8)),
                child: Text('₹ $s', style: const TextStyle(fontSize: 30))),
            Wrap(alignment: WrapAlignment.center, children: [
              for (final k in ['1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0', '<']) btn(k, Colors.blue.shade400, () => key(k))]),
          ]))),
          actions: [
            btn('वापस', Colors.blue, () => Navigator.pop(c)),
            btn('साफ़ करें', Colors.red, () => set(() { s = ''; fresh = false; })),
            btn('आगे', Colors.green, () => Navigator.pop(c, double.tryParse(s) ?? 0)),
          ],
        );
      }));
}

// ---------- Home shell ----------
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}
class _HomeState extends State<Home> {
  int tab = 0; String q = '';
  @override
  void initState() { super.initState(); tick.addListener(_r); editMode.addListener(_r); }
  void _r() => setState(() {});
  @override
  void dispose() { tick.removeListener(_r); editMode.removeListener(_r); super.dispose(); }
  List<Node> flat(List<Node> l) => [for (final n in l) ...(n.leaf ? [n] : flat(n.kids))];

  void newBill() {
    if (S.cur.lines.isEmpty) { snack('यह बिल पहले से खाली है'); return; }
    S.drafts.add(S.cur); S.cur = S.newBill(); S.save(); tick.value++;
  }

  void draftsDialog(BuildContext c) {
    showDialog(context: c, builder: (c) => StatefulBuilder(builder: (c, set) => AlertDialog(
          title: const Text('चालू बिल (ड्राफ्ट)'),
          content: SizedBox(width: 420, child: S.drafts.isEmpty ? const Text('कोई ड्राफ्ट नहीं') : ListView(shrinkWrap: true, children: [
            for (final d in List.of(S.drafts)) ListTile(
                title: Text('बिल नं. ${d.no} • ${d.lines.length} मदें'), subtitle: Text('₹ ${d.total.toStringAsFixed(2)}'),
                onTap: () { S.drafts.remove(d); if (S.cur.lines.isNotEmpty) S.drafts.add(S.cur); S.cur = d; S.save(); tick.value++; Navigator.pop(c); },
                trailing: IconButton(icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () { S.drafts.remove(d); S.save(); tick.value++; set(() {}); }))])),
          actions: [btn('वापस', Colors.blue, () => Navigator.pop(c))])));
  }

  Widget sell(int cols) {
    final items = q.isEmpty ? S.root : flat(S.root).where((n) => n.name.contains(q)).toList();
    return Padding(padding: const EdgeInsets.all(8), child: Column(children: [
      Row(children: [
        Expanded(child: TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'खोजें', border: OutlineInputBorder(), isDense: true),
            onChanged: (v) => setState(() => q = v))),
        btn('नया बिल', Colors.blue, newBill)]),
      const SizedBox(height: 8),
      Expanded(child: SingleChildScrollView(child: tiles(items, cols, add: q.isEmpty))),
    ]));
  }

  @override
  Widget build(BuildContext c) {
    final cols = MediaQuery.of(c).size.width >= 700 ? 8 : 4;
    return Scaffold(
      appBar: AppBar(
        leading: tab == 0 ? IconButton(icon: Icon(editMode.value ? Icons.edit_off : Icons.edit_outlined), onPressed: () => editMode.value = !editMode.value) : null,
        centerTitle: true, title: Text(DateFormat('dd-MM-yyyy').format(DateTime.now())),
        actions: [
          IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: () async { final r = await scanOnce(c); if (r != null) onScan(r); }),
          IconButton(icon: Badge(isLabelVisible: S.drafts.isNotEmpty, label: Text('${S.drafts.length}'), child: const Icon(Icons.folder_open)), onPressed: () => draftsDialog(c)),
          TextButton(onPressed: () async { await Navigator.push(c, MaterialPageRoute(builder: (_) => Preview(S.cur))); tick.value++; },
              child: Text('बिल (${S.cur.lines.length})', style: const TextStyle(fontSize: 18))),
        ]),
      body: [sell(cols), const AllBills(), const Report()][tab],
      bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (i) => setState(() => tab = i), destinations: const [
        NavigationDestination(icon: Icon(Icons.grid_view), label: 'बिक्री'),
        NavigationDestination(icon: Icon(Icons.receipt_long), label: 'सभी बिल'),
        NavigationDestination(icon: Icon(Icons.bar_chart), label: 'रिपोर्ट')]),
    );
  }
}

// ---------- Preview / edit a bill ----------
class Preview extends StatefulWidget {
  final Bill b;
  const Preview(this.b, {super.key});
  @override
  State<Preview> createState() => _PreviewState();
}
class _PreviewState extends State<Preview> {
  Bill get b => widget.b;

  Future<void> doPrint() async {
    final bad = b.lines.indexWhere((l) => !l.complete);
    if (b.lines.isEmpty || bad >= 0) {
      snack(b.lines.isEmpty ? 'बिल खाली है' : 'क्रम ${bad + 1}: सामान, मात्रा या भाव अधूरा है', err: true);
      return;
    }
    final saved = S.hist.contains(b);
    if (!saved) { S.hist.add(b); S.drafts.remove(b); if (identical(b, S.cur)) S.cur = S.newBill(); }
    S.save(); tick.value++;
    final e = await printBill(context, b);
    snack(e ?? 'बिल नं. ${b.no} प्रिंट हो गया', err: e != null);
    if (!saved && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext c) {
    const h = TextStyle(fontWeight: FontWeight.bold, fontSize: 18);
    Widget cell(int f, Widget w) => Expanded(flex: f, child: w);
    return Scaffold(
      appBar: AppBar(title: Text('बिल नं. ${b.no}'), actions: [
        IconButton(icon: const Icon(Icons.print_outlined), tooltip: 'प्रिंटर चुनें', onPressed: () => pickPrinter(c)),
        IconButton(icon: const Icon(Icons.share), tooltip: 'WhatsApp / JPG शेयर', onPressed: () => shareJpg(b)),
      ]),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(8), child: Row(children: [
          cell(1, const Text('क्र.', style: h)), cell(2, const Text('राशि', style: h)), cell(4, const Text('सामान', style: h)),
          cell(3, const Text('मात्रा', style: h)), cell(2, const Text('भाव', style: h))])),
        const Divider(height: 1),
        Expanded(child: ListView.separated(
            itemCount: b.lines.length, separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (c, i) {
              final l = b.lines[i];
              return InkWell(
                  onTap: () async { final r = await entry(l.n, l); if (r != null) { setState(() => b.lines[i] = r); S.save(); } },
                  onLongPress: () => showDialog(context: c, builder: (d) => AlertDialog(title: Text('${l.n.name} हटाएँ?'), actions: [
                        btn('नहीं', Colors.blue, () => Navigator.pop(d)),
                        btn('हाँ', Colors.red, () { setState(() => b.lines.removeAt(i)); S.save(); Navigator.pop(d); })])),
                  child: Padding(padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8), child: Row(children: [
                    cell(1, Text('${i + 1}')), cell(2, Text(l.complete ? l.amount.toStringAsFixed(2) : '—')),
                    cell(4, Text(l.n.name, maxLines: 2)), cell(3, Text(fmtQty(l), style: const TextStyle(fontSize: 16))),
                    cell(2, Text(l.price > 0 ? fmtP(l.price) : '—'))])));
            })),
        Container(color: Colors.blue.shade50, padding: const EdgeInsets.all(10), child: Row(children: [
          Expanded(child: Text('कुल: ₹ ${b.total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
          btn('वापस', Colors.blue, () => Navigator.pop(c)),
          btn('प्रिंट', Colors.green, doPrint)])),
      ]),
    );
  }
}

// ---------- All bills ----------
class AllBills extends StatefulWidget {
  const AllBills({super.key});
  @override
  State<AllBills> createState() => _ABState();
}
class _ABState extends State<AllBills> {
  DateTime day = DateTime.now();
  @override
  Widget build(BuildContext c) {
    final l = S.hist.where((b) => sameDay(b.dt, day)).toList()..sort((a, b) => a.no.compareTo(b.no));
    final tot = l.fold(0.0, (a, b) => a + b.total);
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(icon: const Icon(Icons.chevron_left, size: 32), onPressed: () => setState(() => day = day.subtract(const Duration(days: 1)))),
        TextButton.icon(icon: const Icon(Icons.calendar_month), label: Text(DateFormat('dd-MM-yyyy').format(day), style: const TextStyle(fontSize: 20)),
            onPressed: () async {
              final d = await showDatePicker(context: c, initialDate: day, firstDate: DateTime(2020), lastDate: DateTime(2100));
              if (d != null) setState(() => day = d);
            }),
        IconButton(icon: const Icon(Icons.chevron_right, size: 32), onPressed: () => setState(() => day = day.add(const Duration(days: 1)))),
      ]),
      Text('${l.length} बिल • कुल ₹ ${tot.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
      const Divider(),
      Expanded(child: l.isEmpty ? const Center(child: Text('कोई बिल नहीं')) : ListView(children: [
        for (final b in l) ListTile(
            title: Text('बिल नं. ${b.no}   ₹ ${b.total.toStringAsFixed(2)}'),
            subtitle: Text('${DateFormat('HH:mm').format(b.dt)} • ${b.lines.length} मदें'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async { await Navigator.push(c, MaterialPageRoute(builder: (_) => Preview(b))); setState(() {}); })])),
    ]);
  }
}

// ---------- Reports ----------
class Report extends StatefulWidget {
  const Report({super.key});
  @override
  State<Report> createState() => _RState();
}
class _RState extends State<Report> {
  int per = 0, sort = 0; DateTime ref = DateTime.now();
  bool inP(DateTime d) => per == 0 ? sameDay(d, ref) : per == 1 ? (d.year == ref.year && d.month == ref.month) : d.year == ref.year;

  @override
  Widget build(BuildContext c) {
    final m = <String, List>{};
    for (final b in S.hist.where((b) => inP(b.dt))) {
      for (final l in b.lines) {
        final a = m.putIfAbsent(l.n.name, () => [l.n.type, 0, 0.0]);
        a[1] += l.totalG; a[2] += l.amount;
      }
    }
    double avg(List a) => a[1] == 0 ? 0 : a[2] / (a[0] == 1 ? a[1] : a[1] / 1000);
    final es = m.entries.toList()..sort((x, y) => sort == 0 ? y.value[2].compareTo(x.value[2]) : sort == 1 ? y.value[1].compareTo(x.value[1]) : avg(y.value).compareTo(avg(x.value)));
    final fmt = per == 0 ? 'dd-MM-yyyy' : per == 1 ? 'MMMM yyyy' : 'yyyy';
    return ListView(padding: const EdgeInsets.all(12), children: [
      const Text('A. बिल डाउनलोड', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      Wrap(children: [
        btn('आज के बिल PDF (शेयर / सेव)', Colors.blue, () async {
          final l = S.hist.where((b) => sameDay(b.dt, DateTime.now())).toList()..sort((a, b) => a.no.compareTo(b.no));
          if (l.isEmpty) { snack('आज कोई बिल नहीं', err: true); return; }
          await Share.shareXFiles([XFile((await billsPdf(l)).path)]);
        }),
        btn('Excel (तारीख चुनें)', Colors.green, () async {
          final r = await showDateRangePicker(context: c, firstDate: DateTime(2020), lastDate: DateTime(2100));
          if (r != null) await excelRange(r);
        }),
      ]),
      const Divider(height: 32),
      const Text('B. बिक्री विश्लेषण', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      SegmentedButton<int>(segments: const [ButtonSegment(value: 0, label: Text('दैनिक')), ButtonSegment(value: 1, label: Text('मासिक')), ButtonSegment(value: 2, label: Text('वार्षिक'))],
          selected: {per}, onSelectionChanged: (s) => setState(() => per = s.first)),
      TextButton.icon(icon: const Icon(Icons.calendar_month), label: Text(DateFormat(fmt).format(ref), style: const TextStyle(fontSize: 20)),
          onPressed: () async {
            final d = await showDatePicker(context: c, initialDate: ref, firstDate: DateTime(2020), lastDate: DateTime(2100));
            if (d != null) setState(() => ref = d);
          }),
      SegmentedButton<int>(segments: const [ButtonSegment(value: 0, label: Text('राशि')), ButtonSegment(value: 1, label: Text('मात्रा')), ButtonSegment(value: 2, label: Text('भाव'))],
          selected: {sort}, onSelectionChanged: (s) => setState(() => sort = s.first)),
      const SizedBox(height: 8),
      if (es.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('इस अवधि में कोई बिक्री नहीं'))
      else SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(columns: const [
        DataColumn(label: Text('सामान')), DataColumn(label: Text('मात्रा')), DataColumn(label: Text('राशि')), DataColumn(label: Text('औसत भाव'))],
          rows: [for (final e in es) DataRow(cells: [
            DataCell(Text(e.key)), DataCell(Text(e.value[0] == 1 ? '${e.value[1]} नग' : fmtG(e.value[1]))),
            DataCell(Text((e.value[2] as double).toStringAsFixed(2))), DataCell(Text(avg(e.value).toStringAsFixed(2)))])])),
    ]);
  }
}
