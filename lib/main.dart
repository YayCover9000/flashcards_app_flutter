// ============================================================================
// main.dart — Flashcards app (Decks + text-or-image sides + SM-2 scheduling)
// Includes: main(), Settings, Storage, JSON streaming import/export, UI pages.
// ============================================================================

import 'dart:convert'
    show jsonDecode, jsonEncode, JsonEncoder, utf8, LineSplitter,
    base64Decode, base64Encode, gzip;
import 'dart:convert' as convert show gzip;
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:io' as io;

import 'package:file_picker/file_picker.dart';
import 'package:flip_card/flip_card.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';

// ============================================================================
// [ STREAMING JSON HELPERS ] - parse huge JSON/JSONL/.gz without loading all
// ============================================================================

// Stream top-level JSON array objects from a *file path* (for .json).
Stream<Map<String, dynamic>> streamJsonArrayObjects(String path) async* {
  final stream = io.File(path).openRead();
  var buf = BytesBuilder(copy: false);
  bool inString = false;
  bool escape = false;
  int depth = 0;
  bool seenArray = false;

  await for (final chunk in stream) {
    for (final b in chunk) {
      if (!seenArray) {
        if (b == 0x5B) { // '['
          seenArray = true;
        }
        continue;
      }

      if (inString) {
        buf.addByte(b);
        if (escape) {
          escape = false;
        } else if (b == 0x5C) { // '\'
          escape = true;
        } else if (b == 0x22) { // '"'
          inString = false;
        }
        continue;
      } else {
        if (b == 0x22) { // '"'
          inString = true;
          buf.addByte(b);
          continue;
        }
      }

      if (b == 0x7B) { // '{'
        depth++;
        buf.addByte(b);
        continue;
      }
      if (b == 0x7D) { // '}'
        buf.addByte(b);
        depth--;
        if (depth == 0) {
          final bytes = buf.takeBytes();
          try {
            final obj = jsonDecode(utf8.decode(bytes));
            if (obj is Map<String, dynamic>) yield obj;
          } catch (_) {/* skip bad object */}
        }
        continue;
      }

      if (depth > 0) {
        buf.addByte(b);
      } else {
        if (b == 0x5D) { // ']'
          return;
        }
      }
    }
  }
}

// Stream top-level JSON array objects from a *byte stream* (.json or .json.gz).
Stream<Map<String, dynamic>> streamJsonArrayObjectsFromStream(
    Stream<List<int>> byteStream,
    ) async* {
  var buf = BytesBuilder(copy: false);
  bool inString = false, escape = false, seenArray = false;
  int depth = 0;

  await for (final chunk in byteStream) {
    for (final b in chunk) {
      if (!seenArray) {
        if (b == 0x5B) seenArray = true; // '['
        continue;
      }
      if (inString) {
        buf.addByte(b);
        if (escape) {
          escape = false;
        } else if (b == 0x5C) { // '\'
          escape = true;
        } else if (b == 0x22) { // '"'
          inString = false;
        }
        continue;
      } else if (b == 0x22) { // '"'
        inString = true;
        buf.addByte(b);
        continue;
      }

      if (b == 0x7B) { depth++; buf.addByte(b); continue; }         // '{'
      if (b == 0x7D) {                                              // '}'
        buf.addByte(b); depth--;
        if (depth == 0) {
          final bytes = buf.takeBytes();
          try {
            final obj = jsonDecode(utf8.decode(bytes));
            if (obj is Map<String, dynamic>) yield obj;
          } catch (_) {}
        }
        continue;
      }

      if (depth > 0) {
        buf.addByte(b);
      } else {
        if (b == 0x5D) return; // ']'
      }
    }
  }
}

// Background isolate: reads .json/.json.gz (top-level array) or .jsonl/.jsonl.gz.
void parseDeckIsolate(Map<String, dynamic> args) async {
  final send = args['send'] as SendPort;
  final path = args['path'] as String;

  try {
    final lower = path.toLowerCase();
    final isGz = lower.endsWith('.gz');
    final isJsonl = lower.endsWith('.jsonl') ||
        lower.endsWith('.jsonl.gz') ||
        lower.endsWith('.ndjson') ||
        lower.endsWith('.ndjson.gz');

    Stream<List<int>> openBytes() {
      final s = io.File(path).openRead();
      return isGz ? s.transform(io.GZipCodec().decoder) : s;
    }

    if (isJsonl) {
      final textLines = openBytes()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      const batchSize = 100;
      final batch = <Map<String, dynamic>>[];

      await for (final line in textLines) {
        try {
          final obj = jsonDecode(line);
          if (obj is Map<String, dynamic>) batch.add(obj);
        } catch (_) {}
        if (batch.length >= batchSize) {
          send.send({'type': 'batch', 'cards': List.of(batch), 'progress': null});
          batch.clear();
        }
      }
      if (batch.isNotEmpty) {
        send.send({'type': 'batch', 'cards': List.of(batch), 'progress': 1.0});
      }
      send.send({'type': 'done'});
      return;
    }

    // Stream a top-level JSON array (.json or .json.gz)
    const batchSize = 200;
    final batch = <Map<String, dynamic>>[];
    await for (final obj in streamJsonArrayObjectsFromStream(openBytes())) {
      batch.add(obj);
      if (batch.length >= batchSize) {
        send.send({'type': 'batch', 'cards': List.of(batch), 'progress': null});
        batch.clear();
      }
    }
    if (batch.isNotEmpty) {
      send.send({'type': 'batch', 'cards': List.of(batch), 'progress': 1.0});
    }
    send.send({'type': 'done'});
  } catch (e, st) {
    send.send({'type': 'error', 'message': e.toString(), 'stack': st.toString()});
  }
}

// ============================================================================
// [ SETTINGS ] - theme + export location (ask/docs/custom) + global scope
// ============================================================================

enum ExportLocationMode { askEveryTime, appDocuments, customFolder }

class AppSettings extends ChangeNotifier {
  static const _kThemeKey = 'settings_theme_mode_v1';         // 0=system,1=light,2=dark
  static const _kExportModeKey = 'settings_export_mode_v1';   // 0=ask,1=docs,2=custom
  static const _kCustomDirKey = 'settings_export_custom_dir_v1';

  int _themeIdx = 0;
  int _exportIdx = 0;
  String? _customDir;

  ThemeMode get themeMode =>
      [ThemeMode.system, ThemeMode.light, ThemeMode.dark][_themeIdx.clamp(0, 2)];
  int get themeIdx => _themeIdx;

  ExportLocationMode get exportMode =>
      ExportLocationMode.values[_exportIdx.clamp(0, 2)];
  int get exportIdx => _exportIdx;

  String? get customDir => _customDir;

  set themeIdx(int v) {
    _themeIdx = v;
    notifyListeners();
    _save();
  }

  set exportIdx(int v) {
    _exportIdx = v;
    notifyListeners();
    _save();
  }

  set customDir(String? v) {
    _customDir = v;
    notifyListeners();
    _save();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kThemeKey, _themeIdx);
    await p.setInt(_kExportModeKey, _exportIdx);
    if (_customDir == null || _customDir!.isEmpty) {
      await p.remove(_kCustomDirKey);
    } else {
      await p.setString(_kCustomDirKey, _customDir!);
    }
  }

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    final s = AppSettings();
    s._themeIdx = p.getInt(_kThemeKey) ?? 0;
    s._exportIdx = p.getInt(_kExportModeKey) ?? 0;
    s._customDir = p.getString(_kCustomDirKey);
    return s;
  }
}

class SettingsScope extends InheritedWidget {
  final AppSettings settings;
  const SettingsScope({super.key, required this.settings, required super.child});
  static AppSettings of(BuildContext context) =>
      (context.dependOnInheritedWidgetOfExactType<SettingsScope>())!.settings;
  @override
  bool updateShouldNotify(SettingsScope old) => old.settings != settings;
}

// ============================================================================
// [ MAIN ] - app entry + themes + root route
// ============================================================================

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSizeBytes = 120 * 1024 * 1024;
  final settings = await AppSettings.load();
  runApp(MyApp(settings: settings));
}

class MyApp extends StatefulWidget {
  final AppSettings settings;
  const MyApp({super.key, required this.settings});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return SettingsScope(
      settings: widget.settings,
      child: MaterialApp(
        title: 'Flashcards (Decks, Offline)',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
          scaffoldBackgroundColor: Colors.grey[100],
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo, brightness: Brightness.dark),
          useMaterial3: true,
        ),
        themeMode: widget.settings.themeMode,
        home: const DeckListPage(),
      ),
    );
  }
}

// ============================================================================
// [ MODELS ] - DeckMeta, FlashcardData (+ text-or-image, stats, SM-2)
// ============================================================================

enum SideKind { image, text }
SideKind _kindFromJson(dynamic v) => (v == 'text') ? SideKind.text : SideKind.image;
String _kindToJson(SideKind k) => k == SideKind.text ? 'text' : 'image';

class DeckMeta {
  final String id;
  final String name;
  const DeckMeta({required this.id, required this.name});

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  static DeckMeta fromJson(Map<String, dynamic> j) =>
      DeckMeta(id: j['id'] as String, name: j['name'] as String);
}

class FlashcardData {
  final String id;
  final String title;
  final String front;
  final String back;
  final SideKind frontKind;
  final SideKind backKind;

  // Ranking / stats
  final int correct;
  final int wrong;

  // SM-2 spaced repetition
  final int reps;           // consecutive successful repetitions
  final int intervalDays;   // current interval in days
  final double ease;        // ease factor (>= 1.3)
  final DateTime? due;      // next due date

  const FlashcardData({
    required this.id,
    required this.title,
    required this.front,
    required this.back,
    this.frontKind = SideKind.image,
    this.backKind  = SideKind.image,
    this.correct = 0,
    this.wrong = 0,
    this.reps = 0,
    this.intervalDays = 0,
    this.ease = 2.5,
    this.due,
  });

  double get score => (correct + wrong) == 0 ? 0.0 : correct / (correct + wrong);

  FlashcardData copyWith({
    String? id,
    String? title,
    String? front,
    String? back,
    SideKind? frontKind,
    SideKind? backKind,
    int? correct,
    int? wrong,
    int? reps,
    int? intervalDays,
    double? ease,
    DateTime? due,
  }) {
    return FlashcardData(
      id: id ?? this.id,
      title: title ?? this.title,
      front: front ?? this.front,
      back: back ?? this.back,
      frontKind: frontKind ?? this.frontKind,
      backKind:  backKind  ?? this.backKind,
      correct: correct ?? this.correct,
      wrong: wrong ?? this.wrong,
      reps: reps ?? this.reps,
      intervalDays: intervalDays ?? this.intervalDays,
      ease: ease ?? this.ease,
      due: due ?? this.due,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'front': front,
    'back': back,
    'frontKind': _kindToJson(frontKind),
    'backKind':  _kindToJson(backKind),
    'correct': correct,
    'wrong': wrong,
    'reps': reps,
    'intervalDays': intervalDays,
    'ease': ease,
    'due': due?.toIso8601String(),
  };

  static FlashcardData fromJson(Map<String, dynamic> j) => FlashcardData(
    id: j['id'] as String,
    title: (j['title'] as String?) ?? 'Card',
    front: j['front'] as String,
    back:  j['back']  as String,
    frontKind: _kindFromJson(j['frontKind']),
    backKind:  _kindFromJson(j['backKind']),
    correct: (j['correct'] as int?) ?? 0,
    wrong: (j['wrong'] as int?) ?? 0,
    reps: (j['reps'] as int?) ?? 0,
    intervalDays: (j['intervalDays'] as int?) ?? 0,
    ease: (j['ease'] as num?)?.toDouble() ?? 2.5,
    due: j['due'] != null ? DateTime.tryParse(j['due']) : null,
  );
}

// ============================================================================
// [ SM-2 ] - scheduler util
// ============================================================================

FlashcardData applySm2(FlashcardData c, int q, {DateTime? now}) {
  now ??= DateTime.now();
  q = q.clamp(0, 5);

  // Update EF
  final efPrime = c.ease + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02));
  final newEf = efPrime < 1.3 ? 1.3 : efPrime;

  int newReps;
  int newInterval;
  if (q < 3) {
    newReps = 0;
    newInterval = 1;
  } else {
    newReps = c.reps + 1;
    if (newReps == 1) {
      newInterval = 1;
    } else if (newReps == 2) {
      newInterval = 6;
    } else {
      newInterval = (c.intervalDays * newEf).round().clamp(1, 36500);
    }
  }

  final startOfToday = DateTime(now.year, now.month, now.day);
  final nextDue = startOfToday.add(Duration(days: newInterval));

  return c.copyWith(
    reps: newReps,
    intervalDays: newInterval,
    ease: newEf,
    due: nextDue,
  );
}

// ============================================================================
// [ HELPERS ] - data URL, mime guessing, safe file names, sideView
// ============================================================================

Widget sideView({
  required SideKind kind,
  required String value,
  BoxFit fit = BoxFit.cover,
  int? cacheWidth,
}) {
  if (kind == SideKind.text) {
    return Container(
      color: Colors.white,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Text(
          value,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, height: 1.2),
        ),
      ),
    );
  } else {
    return imageFromSource(value, fit: fit, cacheWidth: cacheWidth);
  }
}

Future<Map<String, dynamic>> _cardToPortableJson(FlashcardData c) async {
  Future<String> ensureDataUrlIfImage(SideKind k, String src) async {
    if (k == SideKind.text) return src; // keep text as-is
    if (src.startsWith('data:')) return src;
    final path = src.startsWith('file://') ? io.File.fromUri(Uri.parse(src)).path : src;
    final bytes = await io.File(path).readAsBytes();
    return _bytesToDataUrl(bytes, mime: 'image/jpeg');
  }

  return {
    'id': c.id,
    'title': c.title,
    'frontKind': _kindToJson(c.frontKind),
    'backKind':  _kindToJson(c.backKind),
    'front': await ensureDataUrlIfImage(c.frontKind, c.front),
    'back' : await ensureDataUrlIfImage(c.backKind,  c.back),
    // include stats & SM-2 so exports roundtrip
    'correct': c.correct,
    'wrong': c.wrong,
    'reps': c.reps,
    'intervalDays': c.intervalDays,
    'ease': c.ease,
    'due': c.due?.toIso8601String(),
  };
}

Future<io.Directory> _deckDir(String deckId) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = io.Directory(p.join(docs.path, 'decks', deckId));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<String> _persistDataUrlToFile(
    String dataUrl,
    io.Directory dir,
    String nameBase, {
      int maxDim = 1280,
      int jpegQuality = 80,
    }) async {
  final bytes = _dataUrlToBytes(dataUrl);
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    final path = p.join(dir.path, '$nameBase.bin');
    await io.File(path).writeAsBytes(bytes, flush: true);
    return path;
  }
  final w = decoded.width, h = decoded.height;
  final resized = (w > maxDim || h > maxDim)
      ? img.copyResize(
    decoded,
    width: w >= h ? maxDim : null,
    height: h > w ? maxDim : null,
    interpolation: img.Interpolation.average,
  )
      : decoded;
  final outJpg = img.encodeJpg(resized, quality: jpegQuality);
  final path = p.join(dir.path, '$nameBase.jpg');
  await io.File(path).writeAsBytes(outJpg, flush: true);
  return path;
}

String _guessMimeFromName(String? name) {
  if (name == null) return 'image/jpeg';
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
  return 'image/jpeg';
}

String _bytesToDataUrl(Uint8List bytes, {String mime = 'image/jpeg'}) {
  final b64 = base64Encode(bytes);
  return 'data:$mime;base64,$b64';
}

Uint8List _dataUrlToBytes(String dataUrl) {
  final idx = dataUrl.indexOf(',');
  if (idx == -1) return Uint8List(0);
  return base64Decode(dataUrl.substring(idx + 1));
}

Widget imageFromSource(String src,
    {BoxFit fit = BoxFit.cover, int? cacheWidth}) {
  if (src.startsWith('data:')) {
    final bytes = _dataUrlToBytes(src);
    return Image.memory(bytes,
        fit: fit, gaplessPlayback: true, cacheWidth: cacheWidth);
  }
  final filePath =
  src.startsWith('file://') ? io.File.fromUri(Uri.parse(src)).path : src;
  return Image.file(io.File(filePath),
      fit: fit, gaplessPlayback: true, cacheWidth: cacheWidth);
}

/// Make a safe filename fragment from a deck name (works on Windows/macOS/Linux).
String _safeFileSlug(String input) {
  var s = input.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  s = s.replaceAll(RegExp(r'\s+'), '_');
  s = s.replaceAll(RegExp(r'[ .]+$'), '');
  s = s.replaceAll(RegExp(r'_+'), '_');
  if (s.isEmpty) s = 'deck';
  if (s.length > 60) s = s.substring(0, 60);
  return s;
}

Future<String?> pickImageAsDataUrl(BuildContext context,
    {required String hint}) async {
  if (!kIsWeb) {
    final source = await showDialog<ImageSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose image source'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Camera'),
                onTap: () => Navigator.of(ctx).pop(ImageSource.camera)),
            ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Gallery'),
                onTap: () => Navigator.of(ctx).pop(ImageSource.gallery)),
            ListTile(
                leading: const Icon(Icons.upload_file),
                title: const Text('Pick from files'),
                onTap: () => Navigator.of(ctx).pop()),
          ],
        ),
      ),
    );

    if (source != null) {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: source, imageQuality: 85);
      if (picked != null) {
        final bytes = await picked.readAsBytes();
        final mime = _guessMimeFromName(picked.name);
        return _bytesToDataUrl(bytes, mime: mime);
      }
    }
  }

  try {
    final result =
    await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    if (file.bytes == null) return null;
    final mime = _guessMimeFromName(file.name);
    return _bytesToDataUrl(file.bytes!, mime: mime);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to pick file: $e')));
    }
    return null;
  }
}

Future<String> downscaleDataUrl(String dataUrl,
    {int maxDim = 1280, int jpegQuality = 80}) async {
  try {
    final comma = dataUrl.indexOf(',');
    if (comma < 0) return dataUrl;
    final bytes = base64Decode(dataUrl.substring(comma + 1));
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return dataUrl;

    final w = decoded.width, h = decoded.height;
    if (w <= maxDim && h <= maxDim) return dataUrl;

    final resized = img.copyResize(decoded,
        width: (w > h) ? maxDim : null,
        height: (h >= w) ? maxDim : null,
        interpolation: img.Interpolation.average);
    final out = img.encodeJpg(resized, quality: jpegQuality);
    final b64 = base64Encode(out);
    return 'data:image/jpeg;base64,$b64';
  } catch (_) {
    return dataUrl;
  }
}

// ============================================================================
// [ STORAGE ] - SharedPreferences for decks + cards (metadata & paths/urls)
// ============================================================================

class Store {
  static const decksKey = 'decks_v1';
  static String cardsKey(String deckId) => 'deck_${deckId}_cards_v1';

  static Future<List<DeckMeta>> loadDecks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(decksKey) ?? [];
    return raw
        .map((s) => DeckMeta.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  static Future<void> saveDecks(List<DeckMeta> decks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        decksKey, decks.map((d) => jsonEncode(d.toJson())).toList());
  }

  static Future<List<FlashcardData>> loadCards(String deckId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(cardsKey(deckId)) ?? [];
    return raw
        .map((s) =>
        FlashcardData.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  static Future<void> saveCards(String deckId, List<FlashcardData> cards) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        cardsKey(deckId), cards.map((c) => jsonEncode(c.toJson())).toList());
  }
}

// ============================================================================
// [ SETTINGS PAGE ] - (kept simple; deprecation warnings are harmless)
// ============================================================================

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _picking = false;

  @override
  Widget build(BuildContext context) {
    final s = SettingsScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const ListTile(title: Text('Appearance'), subtitle: Text('Theme')),
          RadioListTile<int>(
            value: 0,
            groupValue: s.themeIdx,
            onChanged: (v) => setState(() => s.themeIdx = v!),
            title: const Text('System'),
          ),
          RadioListTile<int>(
            value: 1,
            groupValue: s.themeIdx,
            onChanged: (v) => setState(() => s.themeIdx = v!),
            title: const Text('Light'),
          ),
          RadioListTile<int>(
            value: 2,
            groupValue: s.themeIdx,
            onChanged: (v) => setState(() => s.themeIdx = v!),
            title: const Text('Dark'),
          ),
          const Divider(),
          const ListTile(
            title: Text('Export'),
            subtitle: Text('Where to save deck JSON'),
          ),
          RadioListTile<int>(
            value: 0,
            groupValue: s.exportIdx,
            onChanged: (v) => setState(() => s.exportIdx = v!),
            title: const Text('Ask every time'),
            subtitle: const Text('Pick a folder on export'),
          ),
          RadioListTile<int>(
            value: 1,
            groupValue: s.exportIdx,
            onChanged: (v) => setState(() => s.exportIdx = v!),
            title: const Text('App Documents'),
            subtitle: const Text('Saves under the app’s documents directory'),
          ),
          RadioListTile<int>(
            value: 2,
            groupValue: s.exportIdx,
            onChanged: (v) => setState(() => s.exportIdx = v!),
            title: const Text('Custom folder'),
            subtitle: Text(s.customDir?.isNotEmpty == true
                ? s.customDir!
                : 'Not set'),
            secondary: _picking
                ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2))
                : IconButton(
              tooltip: 'Choose folder',
              icon: const Icon(Icons.folder_open),
              onPressed: () async {
                setState(() => _picking = true);
                try {
                  final dir = await FilePicker.platform.getDirectoryPath(
                      dialogTitle: 'Choose export folder');
                  if (dir != null) {
                    s.customDir = dir;
                    s.exportIdx = 2;
                  }
                } finally {
                  if (mounted) setState(() => _picking = false);
                }
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Note: On iOS, apps are sandboxed. Use “Ask every time” or the Files app. '
                  'On Android, the system file picker controls access to folders.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// [ DECK LIST PAGE ] - folders (create/rename/delete) + open Settings
// ============================================================================

class DeckListPage extends StatefulWidget {
  const DeckListPage({super.key});
  @override
  State<DeckListPage> createState() => _DeckListPageState();
}

class _DeckListPageState extends State<DeckListPage> {
  List<DeckMeta> _decks = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    _decks = await Store.loadDecks();
    setState(() => _loading = false);
  }

  Future<void> _createDeck() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Deck'),
        content: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: 'Deck name')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final deck = DeckMeta(
        id: DateTime.now().millisecondsSinceEpoch.toString(), name: name);
    setState(() => _decks.add(deck));
    await Store.saveDecks(_decks);
  }

  Future<void> _renameDeck(DeckMeta deck) async {
    final controller = TextEditingController(text: deck.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Deck'),
        content: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: 'Deck name')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final idx = _decks.indexWhere((d) => d.id == deck.id);
    if (idx != -1) {
      setState(() => _decks[idx] = DeckMeta(id: deck.id, name: name));
      await Store.saveDecks(_decks);
    }
  }

  Future<void> _deleteDeck(DeckMeta deck) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete deck?'),
        content: Text('This deletes deck "${deck.name}" and its cards.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _decks.removeWhere((d) => d.id == deck.id));
    await Store.saveDecks(_decks);
    await Store.saveCards(deck.id, const []); // clear cards for this deck
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Decks'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _decks.isEmpty
          ? Center(
        child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.folder_open,
                  size: 90, color: Colors.grey),
              const SizedBox(height: 8),
              const Text('No decks yet'),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                  onPressed: _createDeck,
                  icon: const Icon(Icons.add),
                  label: const Text('Create your first deck')),
            ]),
      )
          : ListView.separated(
        itemCount: _decks.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final d = _decks[i];
          return ListTile(
            leading: const Icon(Icons.folder),
            title: Text(d.name),
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => DeckPage(deck: d))),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'rename') _renameDeck(d);
                if (v == 'delete') _deleteDeck(d);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'rename', child: Text('Rename')),
                PopupMenuItem(
                    value: 'delete', child: Text('Delete')),
              ],
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _createDeck,
          icon: const Icon(Icons.create_new_folder),
          label: const Text('New Deck')),
    );
  }
}

// ============================================================================
// [ DECK PAGE ] - grid + import/export + "Study due" + SM-2 grading
// ============================================================================

class DeckPage extends StatefulWidget {
  final DeckMeta deck;
  const DeckPage({super.key, required this.deck});
  @override
  State<DeckPage> createState() => _DeckPageState();
}

class _DeckPageState extends State<DeckPage> {
  List<FlashcardData> _cards = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<FlashcardData> _dueCards() {
    final now = DateTime.now();
    final eod = DateTime(now.year, now.month, now.day).add(const Duration(days: 1));
    final due = _cards.where((c) => c.due == null || c.due!.isBefore(eod)).toList();
    due.sort((a, b) {
      final ad = a.due ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bd = b.due ?? DateTime.fromMillisecondsSinceEpoch(0);
      final cmp = ad.compareTo(bd);
      if (cmp != 0) return cmp;
      return a.ease.compareTo(b.ease);
    });
    return due;
  }

  Widget _scoreChip(FlashcardData c) {
    final pct = (c.score * 100).toStringAsFixed(0);
    final color = c.score >= 0.8
        ? Colors.green
        : (c.score >= 0.5 ? Colors.orange : Colors.red);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration:
      BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
      child: Text('$pct%', style: TextStyle(color: color, fontWeight: FontWeight.w600)),
    );
  }

  Widget _gridTile(FlashcardData card, int index) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SwipeViewerPage(
              cards: _cards,
              initialIndex: index,
              onEdit: (c) => _edit(c),
              onDelete: (c) => _delete(c),
              onGrade: (c, q) => _recordGrade(c, q),
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius:
                const BorderRadius.vertical(top: Radius.circular(12)),
                child: sideView(
                  kind: card.frontKind,
                  value: card.front,
                  fit: BoxFit.cover,
                  cacheWidth: 512,
                ),
              ),
            ),
            ListTile(
              dense: true,
              title: Text(card.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Row(
                children: [
                  _scoreChip(card),
                  const SizedBox(width: 8),
                  Text('EF ${card.ease.toStringAsFixed(2)}'
                      '${card.due != null ? ' · due ${card.due!.toLocal().toString().split(" ").first}' : ''}',
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'edit') _edit(card);
                  if (v == 'rename') _renameCard(card);
                  if (v == 'delete') _delete(card);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    _cards = await Store.loadCards(widget.deck.id);
    setState(() => _loading = false);
  }

  Future<void> _save() async => Store.saveCards(widget.deck.id, _cards);

  Future<void> _create() async {
    final created = await Navigator.of(context).push<FlashcardData?>(
        MaterialPageRoute(builder: (_) => const EditFlashcardPage()));
    if (created != null) {
      // persist images if needed
      final dir = await _deckDir(widget.deck.id);

      String frontVal = created.front;
      if (created.frontKind == SideKind.image && created.front.startsWith('data:')) {
        frontVal = await _persistDataUrlToFile(created.front, dir, '${created.id}_front');
      }

      String backVal = created.back;
      if (created.backKind == SideKind.image && created.back.startsWith('data:')) {
        backVal = await _persistDataUrlToFile(created.back, dir, '${created.id}_back');
      }

      final persisted = created.copyWith(front: frontVal, back: backVal);
      setState(() => _cards.add(persisted));
      await _save();
    }
  }

  Future<void> _edit(FlashcardData card) async {
    final updated = await Navigator.of(context).push<FlashcardData?>(
        MaterialPageRoute(builder: (_) => EditFlashcardPage(existing: card)));
    if (updated != null) {
      final dir = await _deckDir(widget.deck.id);

      String frontVal = updated.front;
      if (updated.frontKind == SideKind.image && updated.front.startsWith('data:')) {
        frontVal = await _persistDataUrlToFile(updated.front, dir, '${updated.id}_front');
      }

      String backVal = updated.back;
      if (updated.backKind == SideKind.image && updated.back.startsWith('data:')) {
        backVal = await _persistDataUrlToFile(updated.back, dir, '${updated.id}_back');
      }

      final persisted = updated.copyWith(front: frontVal, back: backVal);

      final idx = _cards.indexWhere((c) => c.id == persisted.id);
      if (idx != -1) {
        setState(() => _cards[idx] = persisted);
        await _save();
      }
    }
  }

  Future<void> _renameCard(FlashcardData card) async {
    final controller = TextEditingController(text: card.title);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Card'),
        content: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: 'Title')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;
    final idx = _cards.indexWhere((c) => c.id == card.id);
    if (idx != -1) {
      setState(() => _cards[idx] = card.copyWith(title: title));
      await _save();
    }
  }

  Future<void> _delete(FlashcardData card) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete card?'),
        content: Text('Delete "${card.title}" from this deck?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      setState(() => _cards.removeWhere((c) => c.id == card.id));
      await _save();
    }
  }

  Future<void> _recordGrade(FlashcardData card, int q) async {
    final idx = _cards.indexWhere((c) => c.id == card.id);
    if (idx == -1) return;

    final base = (q >= 3)
        ? card.copyWith(correct: card.correct + 1)
        : card.copyWith(wrong: card.wrong + 1);

    final updated = applySm2(base, q);
    setState(() => _cards[idx] = updated);
    await _save();
  }

  // --- Export: Portable .json (rehydrates images to data URLs) ---
  Future<void> _exportDeck() async {
    try {
      final cardsJson = <Map<String, dynamic>>[];
      for (final c in _cards) {
        cardsJson.add(await _cardToPortableJson(c));
      }

      final deck = {
        'schema': 'flashcards.simple.v1',
        'deck': {'id': widget.deck.id, 'name': widget.deck.name},
        'exportedAt': DateTime.now().toIso8601String(),
        'cards': cardsJson,
      };

      const encoder = JsonEncoder.withIndent('  ');
      final jsonStr = encoder.convert(deck);
      final slug = _safeFileSlug(widget.deck.name);
      final fileName =
          'deck_${slug}_${DateTime.now().millisecondsSinceEpoch}.json';

      final tmp = await getTemporaryDirectory();
      final tmpPath = p.join(tmp.path, fileName);
      await io.File(tmpPath).writeAsString(jsonStr);

      final savedPath = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          sourceFilePath: tmpPath,
          fileName: fileName,
        ),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
          Text(savedPath == null ? 'Export canceled' : 'Saved to: $savedPath')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  // --- Export: NDJSON (.jsonl) portable stream (header + 1 card per line) ---
  Future<void> _exportDeckJsonl() async {
    try {
      final slug = _safeFileSlug(widget.deck.name);
      final fileName =
          'deck_${slug}_${DateTime.now().millisecondsSinceEpoch}.jsonl';

      final tmp = await getTemporaryDirectory();
      final tmpPath = p.join(tmp.path, fileName);
      final sink = io.File(tmpPath).openWrite();

      sink.writeln(jsonEncode({
        '_meta': {
          'schema': 'flashcards.simple.v1',
          'deck': {'id': widget.deck.id, 'name': widget.deck.name},
          'exportedAt': DateTime.now().toIso8601String(),
          'format': 'jsonl'
        }
      }));

      for (final c in _cards) {
        final portable = await _cardToPortableJson(c);
        sink.writeln(jsonEncode(portable));
      }
      await sink.flush();
      await sink.close();

      final savedPath = await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          sourceFilePath: tmpPath,
          fileName: fileName,
        ),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
          Text(savedPath == null ? 'Export canceled' : 'Saved to: $savedPath')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Export (jsonl) failed: $e')));
      }
    }
  }

  // --- Share current deck (.json) ---
  Future<void> _shareDeck() async {
    try {
      final cardsJson = <Map<String, dynamic>>[];
      for (final c in _cards) {
        cardsJson.add(await _cardToPortableJson(c));
      }
      final deck = {
        'schema': 'flashcards.simple.v1',
        'deck': {'id': widget.deck.id, 'name': widget.deck.name},
        'exportedAt': DateTime.now().toIso8601String(),
        'cards': cardsJson,
      };
      final jsonStr = const JsonEncoder.withIndent('  ').convert(deck);

      final slug = _safeFileSlug(widget.deck.name);
      final fileName =
          'deck_${slug}_${DateTime.now().millisecondsSinceEpoch}.json';

      final tmp = await getTemporaryDirectory();
      final path = p.join(tmp.path, fileName);
      await io.File(path).writeAsString(jsonStr);

      await Share.shareXFiles(
        [XFile(path, mimeType: 'application/json', name: fileName)],
        subject: fileName,
        text: 'Flashcards deck: ${widget.deck.name}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Share failed: $e')));
      }
    }
  }

  // --- Import: supports .json (array), .jsonl and .json/.jsonl.gz ---
  Future<void> _importDeck() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'jsonl', 'gz', 'deckjson'],
      withData: false,
    );
    if (res == null || res.files.isEmpty) return;

    final path = res.files.single.path;
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('No file path available')));
      }
      return;
    }

    final progress = ValueNotifier<double?>(null);
    bool dialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Importing deck...'),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, p, __) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: p),
                const SizedBox(height: 8),
                Text(p == null ? 'Starting…' : '${(p * 100).toStringAsFixed(0)} %'),
              ],
            ),
          ),
        ),
      ),
    ).then((_) => dialogOpen = false);

    final rp = ReceivePort();
    await Isolate.spawn(parseDeckIsolate, {'send': rp.sendPort, 'path': path});

    int importedCount = 0;

    try {
      await for (final msg in rp) {
        if (msg is! Map) continue;
        final map = msg.cast<String, dynamic>();
        switch (map['type']) {
          case 'batch':
            final list = (map['cards'] as List).cast<Map<String, dynamic>>();
            final dir = await _deckDir(widget.deck.id);

            final toAdd = <FlashcardData>[];
            for (final m in list) {
              try {
                final raw = FlashcardData.fromJson(m);

                // persist images if needed
                String frontVal = raw.front;
                if (raw.frontKind == SideKind.image && raw.front.startsWith('data:')) {
                  frontVal = await _persistDataUrlToFile(raw.front, dir, '${raw.id}_front');
                }
                String backVal = raw.back;
                if (raw.backKind == SideKind.image && raw.back.startsWith('data:')) {
                  backVal = await _persistDataUrlToFile(raw.back, dir, '${raw.id}_back');
                }

                toAdd.add(raw.copyWith(front: frontVal, back: backVal));
              } catch (_) {}
            }

            if (toAdd.isNotEmpty) {
              final ids = _cards.map((e) => e.id).toSet();
              final unique = toAdd.where((c) => !ids.contains(c.id)).toList();
              if (unique.isNotEmpty) {
                setState(() => _cards.addAll(unique));
                await _save();
                importedCount += unique.length;
              }
            }

            final p = map['progress'];
            if (p is num) progress.value = p.toDouble().clamp(0.0, 1.0);
            break;

          case 'done':
            rp.close();
            break;

          case 'error':
            rp.close();
            throw Exception(map['message'] ?? 'Unknown parser error');
        }
      }

      if (mounted) {
        if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Imported $importedCount card(s)')),
        );
      }
    } catch (e) {
      if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _cards.isEmpty
        ? Center(
      child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.photo_library,
                size: 90, color: Colors.grey),
            const SizedBox(height: 8),
            const Text('No cards in this deck'),
            const SizedBox(height: 8),
            ElevatedButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add),
                label: const Text('Create first card')),
          ]),
    )
        : Padding(
      padding: const EdgeInsets.all(12),
      child: GridView.builder(
        itemCount: _cards.length,
        gridDelegate:
        const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.72,
        ),
        itemBuilder: (_, i) => _gridTile(_cards[i], i),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.deck.name),
        actions: [
          IconButton(
            onPressed: () {
              final due = _dueCards();
              if (due.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Nothing due right now!')),
                );
                return;
              }
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SwipeViewerPage(
                  cards: due,
                  initialIndex: 0,
                  onEdit: (c) => _edit(c),
                  onDelete: (c) => _delete(c),
                  onGrade: (c, q) => _recordGrade(c, q),
                ),
              ));
            },
            tooltip: 'Study due',
            icon: const Icon(Icons.play_circle),
          ),
          IconButton(
            onPressed: _importDeck,
            tooltip: 'Import deck (.json/.jsonl/.gz)',
            icon: const Icon(Icons.file_open),
          ),
          IconButton(
            onPressed: _exportDeck,
            tooltip: 'Export deck (.json)',
            icon: const Icon(Icons.download),
          ),
          IconButton(
            onPressed: _exportDeckJsonl,
            tooltip: 'Export deck (JSONL)',
            icon: const Icon(Icons.data_object),
          ),
          IconButton(
            onPressed: _load,
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            onPressed: _shareDeck,
            tooltip: 'Share deck',
            icon: const Icon(Icons.share),
          ),
        ],
      ),
      body: body,
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _create, icon: const Icon(Icons.add), label: const Text('New Card')),
    );
  }
}

// ============================================================================
// [ EDIT CARD PAGE ] - choose image/text per side + title
// ============================================================================

class EditFlashcardPage extends StatefulWidget {
  final FlashcardData? existing;
  const EditFlashcardPage({super.key, this.existing});

  @override
  State<EditFlashcardPage> createState() => _EditFlashcardPageState();
}

class _EditFlashcardPageState extends State<EditFlashcardPage> {
  SideKind _frontKind = SideKind.image;
  SideKind _backKind = SideKind.image;

  String? _front; // image data URL or text
  String? _back;  // image data URL or text

  late final TextEditingController _title;
  late final TextEditingController _frontText;
  late final TextEditingController _backText;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.existing?.title ?? 'Card');

    _frontKind = widget.existing?.frontKind ?? SideKind.image;
    _backKind  = widget.existing?.backKind  ?? SideKind.image;

    _front = widget.existing?.front;
    _back  = widget.existing?.back;

    _frontText = TextEditingController(text: _frontKind == SideKind.text ? (_front ?? '') : '');
    _backText  = TextEditingController(text: _backKind  == SideKind.text ? (_back  ?? '') : '');
  }

  @override
  void dispose() {
    _title.dispose();
    _frontText.dispose();
    _backText.dispose();
    super.dispose();
  }

  Future<void> _pick(bool isFront) async {
    final dataUrl =
    await pickImageAsDataUrl(context, hint: isFront ? 'front' : 'back');
    if (dataUrl == null) return;
    setState(() {
      if (isFront) {
        _frontKind = SideKind.image;
        _front = dataUrl;
      } else {
        _backKind = SideKind.image;
        _back = dataUrl;
      }
    });
  }

  Future<void> _save() async {
    // gather from text fields if text kind
    final frontVal = _frontKind == SideKind.text ? _frontText.text.trim() : _front;
    final backVal  = _backKind  == SideKind.text ? _backText.text.trim()  : _back;

    if (frontVal == null || frontVal.isEmpty || backVal == null || backVal.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Please provide both front and back (image or text).')));
      }
      return;
    }

    setState(() => _saving = true);
    final id =
        widget.existing?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
    final card = FlashcardData(
      id: id,
      title: _title.text.trim().isEmpty ? 'Card' : _title.text.trim(),
      front: frontVal,
      back: backVal,
      frontKind: _frontKind,
      backKind: _backKind,
      // keep existing stats/schedule if editing
      correct: widget.existing?.correct ?? 0,
      wrong: widget.existing?.wrong ?? 0,
      reps: widget.existing?.reps ?? 0,
      intervalDays: widget.existing?.intervalDays ?? 0,
      ease: widget.existing?.ease ?? 2.5,
      due: widget.existing?.due,
    );
    if (mounted) Navigator.of(context).pop(card);
  }

  Widget _sideEditor({
    required String label,
    required bool isFront,
    required SideKind kind,
    required ValueChanged<SideKind> onKind,
    required TextEditingController textCtrl,
    required String? value,
  }) {
    return Expanded(
      child: Column(
        children: [
          Row(
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              SegmentedButton<SideKind>(
                segments: const [
                  ButtonSegment(value: SideKind.image, label: Text('Image'), icon: Icon(Icons.image)),
                  ButtonSegment(value: SideKind.text,  label: Text('Text'),  icon: Icon(Icons.text_fields)),
                ],
                selected: {kind},
                onSelectionChanged: (s) => onKind(s.first),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: GestureDetector(
              onTap: kind == SideKind.image ? () => _pick(isFront) : null,
              child: Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: kind == SideKind.text
                      ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: TextField(
                      controller: textCtrl,
                      maxLines: null,
                      decoration: const InputDecoration(
                        hintText: 'Enter text…',
                        border: InputBorder.none,
                      ),
                    ),
                  )
                      : (value == null
                      ? Container(
                      color: Colors.grey[200],
                      child: const Center(
                          child: Icon(Icons.image, size: 56, color: Colors.grey)))
                      : sideView(kind: SideKind.image, value: value, fit: BoxFit.cover)),
                ),
              ),
            ),
          ),
          if (kind == SideKind.image) const SizedBox(height: 8),
          if (kind == SideKind.image)
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => _pick(isFront),
                  icon: const Icon(Icons.upload),
                  label: const Text('Pick image'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return Scaffold(
      appBar:
      AppBar(title: Text(isEditing ? 'Edit Card' : 'Create Card')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          TextField(
              controller: _title,
              decoration:
              const InputDecoration(labelText: 'Title (optional)')),
          const SizedBox(height: 8),
          Expanded(
            child: Row(children: [
              _sideEditor(
                label: 'Front',
                isFront: true,
                kind: _frontKind,
                onKind: (k) => setState(() => _frontKind = k),
                textCtrl: _frontText,
                value: _front,
              ),
              const SizedBox(width: 12),
              _sideEditor(
                label: 'Back',
                isFront: false,
                kind: _backKind,
                onKind: (k) => setState(() => _backKind = k),
                textCtrl: _backText,
                value: _back,
              ),
            ]),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: ElevatedButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save),
                    label: Text(_saving
                        ? 'Saving...'
                        : (isEditing ? 'Save changes' : 'Create card')))),
          ])
        ]),
      ),
    );
  }
}

// ============================================================================
// [ SWIPE VIEWER PAGE ] - horizontal swipe + grading (0–5) + edit/delete
// ============================================================================

class SwipeViewerPage extends StatefulWidget {
  final List<FlashcardData> cards;
  final int initialIndex;
  final Future<void> Function(FlashcardData)? onEdit;
  final Future<void> Function(FlashcardData)? onDelete;
  final Future<void> Function(FlashcardData, int q)? onGrade;

  const SwipeViewerPage({
    super.key,
    required this.cards,
    required this.initialIndex,
    this.onEdit,
    this.onDelete,
    this.onGrade,
  });

  @override
  State<SwipeViewerPage> createState() => _SwipeViewerPageState();
}

class _SwipeViewerPageState extends State<SwipeViewerPage> {
  late final PageController _controller;
  late int _index;
  bool _showBack = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.cards.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = (_index + delta).clamp(0, widget.cards.length - 1);
    if (next != _index) {
      _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Widget _gradeBar(FlashcardData c) {
    // 0..5 buttons (SM-2 quality)
    final labels = ['0','1','2','3','4','5'];
    return Wrap(
      spacing: 6,
      children: List.generate(6, (i) {
        return ElevatedButton(
          onPressed: widget.onGrade == null ? null : () async {
            await widget.onGrade!(c, i);
            if (!mounted) return;
            // auto-next on grade
            if (_index < widget.cards.length - 1) _go(1);
          },
          child: Text(labels[i]),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.cards.isEmpty) {
      return const Scaffold(body: Center(child: Text('No cards')));
    }

    final card = widget.cards[_index];

    return Scaffold(
      appBar: AppBar(
        title: Text('${card.title}  (${_index + 1}/${widget.cards.length})'),
        actions: [
          if (widget.onEdit != null)
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () => widget.onEdit!(card),
              tooltip: 'Edit',
            ),
          if (widget.onDelete != null)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () async {
                await widget.onDelete!(card);
                if (!mounted) return;
                if (_index >= widget.cards.length) {
                  Navigator.pop(context);
                } else {
                  setState(() {});
                }
              },
              tooltip: 'Delete',
            ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        onPageChanged: (i) => setState(() {
          _index = i;
          _showBack = false;
        }),
        itemCount: widget.cards.length,
        itemBuilder: (_, i) {
          final c = widget.cards[i];
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Card(
                    elevation: 6,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: SizedBox(
                        width: 320,
                        height: 420,
                        child: FlipCard(
                          front: sideView(kind: c.frontKind, value: c.front, fit: BoxFit.cover),
                          back:  sideView(kind: c.backKind,  value: c.back,  fit: BoxFit.cover),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Score: ${(c.score*100).toStringAsFixed(0)}% · EF ${c.ease.toStringAsFixed(2)}'
                          '${c.due != null ? ' · due ${c.due!.toLocal().toString().split(" ").first}' : ''}'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _gradeBar(c),
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const SizedBox(width: 16),
          FloatingActionButton.small(
            onPressed: () => _go(-1),
            child: const Icon(Icons.chevron_left),
            heroTag: 'prev',
          ),
          FloatingActionButton.small(
            onPressed: () => _go(1),
            child: const Icon(Icons.chevron_right),
            heroTag: 'next',
          ),
          const SizedBox(width: 16),
        ],
      ),
    );
  }
}
