// ============================================================================
// main.dart — Flashcards app (Decks + smaller cards + rename + import/export)
// Includes: main(), Settings (theme + export location), Storage, UI pages.
// ============================================================================

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:io' as io;

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flip_card/flip_card.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' as services; // Clipboard
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';



// NEW: stream top-level JSON array objects from a file path.
// Works on huge files without loading the whole file in memory.
Stream<Map<String, dynamic>> streamJsonArrayObjects(String path) async* {
  final stream = io.File(path).openRead();
  // We’ll scan bytes and split out top-level {...} objects safely (handles strings/escapes).
  var buf = BytesBuilder(copy: false);
  bool inString = false;
  bool escape = false;
  int depth = 0;
  bool seenArray = false;

  await for (final chunk in stream) {
    for (final b in chunk) {
      if (!seenArray) {
        // skip whitespace until we see '['
        if (b == 0x5B) { // '['
          seenArray = true;
        }
        continue;
      }

      // handle string/escape state
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

      // not in string: track object depth
      if (b == 0x7B) { // '{'
        depth++;
        buf.addByte(b);
        continue;
      }
      if (b == 0x7D) { // '}'
        buf.addByte(b);
        depth--;
        if (depth == 0) {
          // complete object
          final bytes = buf.takeBytes();
          try {
            final obj = jsonDecode(utf8.decode(bytes));
            if (obj is Map<String, dynamic>) yield obj;
          } catch (_) {/* skip bad object */}
        }
        continue;
      }

      // if we started an object, keep bytes
      if (depth > 0) {
        buf.addByte(b);
      } else {
        // depth==0 outside of objects: watch for ']' to finish
        if (b == 0x5D) { // ']'
          return;
        }
        // skip commas/whitespace between objects
      }
    }
  }
}



// Runs in a background isolate and sends batches of cards back to the UI isolate.
void parseDeckIsolate(Map<String, dynamic> args) async {
  final send = args['send'] as SendPort;
  final path = args['path'] as String;

  try {
    final lower = path.toLowerCase();
    final isGz = lower.endsWith('.gz');
    final isJsonl = lower.endsWith('.jsonl');

    if (isJsonl) {
      final f = io.File(path);
      final totalBytes = await f.length();
      int seen = 0;
      final List<Map<String, dynamic>> batch = [];
      await for (final line in f.openRead().transform(utf8.decoder).transform(const LineSplitter())) {
        seen += line.length + 1;
        try {
          final obj = jsonDecode(line);
          if (obj is Map<String, dynamic>) batch.add(obj);
        } catch (_) {}
        if (batch.length >= 100) {
          send.send({'type': 'batch', 'cards': List.of(batch), 'progress': (totalBytes == 0) ? null : seen / totalBytes});
          batch.clear();
        }
      }
      if (batch.isNotEmpty) send.send({'type': 'batch', 'cards': List.of(batch), 'progress': 1.0});
      send.send({'type': 'done'});
      return;
    }

    if (!isGz) {
      // NEW: stream a top-level JSON array without loading the whole file.
      int seen = 0;
      int emitted = 0;
      const batchSize = 200;
      final batch = <Map<String, dynamic>>[];

      await for (final obj in streamJsonArrayObjects(path)) {
        // Validate schema only once by peeking the first object that carries meta,
        // or accept any flashcard object. If your file has a header object instead,
        // adapt here. For now we assume each element is a card map.
        batch.add(obj);
        emitted++;
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

    // For .gz: NOTE the archive decoder needs full bytes; for truly huge sets,
    // prefer .jsonl.gz and handle like JSONL above. We keep your old path:
    final raw = await io.File(path).readAsBytes();
    final Uint8List jsonBytes = Uint8List.fromList(GZipDecoder().decodeBytes(raw));
    final decoded = jsonDecode(utf8.decode(jsonBytes));

    if (decoded is! Map<String, dynamic>) throw FormatException('Invalid deck JSON (root)');
    if (decoded['schema'] != 'flashcards.simple.v1') throw FormatException('Unknown deck schema');
    final cards = decoded['cards'];
    if (cards is! List) throw FormatException('Invalid cards array');

    const batchSize = 200;
    final total = cards.isEmpty ? 1 : cards.length;
    List<Map<String, dynamic>> batch = [];
    for (int i = 0; i < cards.length; i++) {
      final item = cards[i];
      if (item is Map) batch.add(item.cast<String, dynamic>());
      if (batch.length >= batchSize || i == cards.length - 1) {
        send.send({'type': 'batch', 'cards': batch, 'progress': (i + 1) / total});
        batch = [];
      }
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

/// Simple inherited holder so the whole widget tree can read settings.
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
// [ MODELS ] - DeckMeta, FlashcardData
// ============================================================================

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
  final String title; // user-renameable
  final String front; // data URL
  final String back;  // data URL

  const FlashcardData({
    required this.id,
    required this.title,
    required this.front,
    required this.back,
  });

  FlashcardData copyWith({
    String? id,
    String? title,
    String? front,
    String? back,
  }) {
    return FlashcardData(
      id: id ?? this.id,
      title: title ?? this.title,
      front: front ?? this.front,
      back: back ?? this.back,
    );
  }

  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'front': front, 'back': back};

  static FlashcardData fromJson(Map<String, dynamic> json) => FlashcardData(
    id: json['id'] as String,
    title: (json['title'] as String?) ?? 'Card',
    front: json['front'] as String,
    back: json['back'] as String,
  );
}


// ============================================================================
// [ HELPERS ] - data URL, mime guessing, safe file names, img widget
// ============================================================================

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

Widget imageFromDataUrl(String dataUrl, {BoxFit fit = BoxFit.cover}) {
  final bytes = _dataUrlToBytes(dataUrl);
  return Image.memory(bytes, fit: fit, gaplessPlayback: true);
}

/// Make a safe filename fragment from a deck name (works on Windows/macOS/Linux).
String _safeFileSlug(String input) {
  // Replace characters invalid on Windows: < > : " / \ | ? *  and control chars
  var s = input.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  // Collapse whitespace to single underscores
  s = s.replaceAll(RegExp(r'\s+'), '_');
  // Remove trailing dots/spaces (illegal on Windows)
  s = s.replaceAll(RegExp(r'[ .]+$'), '');
  // Collapse multiple underscores
  s = s.replaceAll(RegExp(r'_+'), '_');
  if (s.isEmpty) s = 'deck';
  if (s.length > 60) s = s.substring(0, 60); // keep it neat
  return s;
}

Future<String?> pickImageAsDataUrl(BuildContext context,
    {required String hint}) async {
  // Mobile/desktop chooser
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
      final picked =
      await picker.pickImage(source: source, imageQuality: 85);
      if (picked != null) {
        final bytes = await picked.readAsBytes();
        final mime = _guessMimeFromName(picked.name);
        return _bytesToDataUrl(bytes, mime: mime);
      }
    }
  }

  // Web or fallback via file picker
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
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick file: $e')));
    }
    return null;
  }
}

Future<String> downscaleDataUrl(String dataUrl, {int maxDim = 1280, int jpegQuality = 80}) async {
  try {
    final comma = dataUrl.indexOf(',');
    if (comma < 0) return dataUrl;
    final meta = dataUrl.substring(5, comma); // e.g. image/png;base64
    final bytes = base64Decode(dataUrl.substring(comma + 1));
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return dataUrl;

    final w = decoded.width, h = decoded.height;
    if (w <= maxDim && h <= maxDim) return dataUrl;

    final resized = img.copyResize(decoded, width: (w > h) ? maxDim : null, height: (h >= w) ? maxDim : null, interpolation: img.Interpolation.average);
    final out = img.encodeJpg(resized, quality: jpegQuality);
    final b64 = base64Encode(out);
    return 'data:image/jpeg;base64,$b64';
  } catch (_) {
    return dataUrl; // fall back if anything fails
  }
}


// ============================================================================
// [ STORAGE ] - SharedPreferences for decks + cards
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

  static Future<void> saveCards(
      String deckId, List<FlashcardData> cards) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(cardsKey(deckId),
        cards.map((c) => jsonEncode(c.toJson())).toList());
  }
}

// ============================================================================
// [ SETTINGS PAGE ] - theme + export location options wheel
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
                  final dir =
                  await FilePicker.platform.getDirectoryPath(
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
// [ DECK PAGE ] - grid of smaller cards + per-deck import/export
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

  // In _DeckPageState
  Widget _gridTile(FlashcardData card, int index) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SwipeViewerPage(
              cards: _cards,                 // pass the list
              initialIndex: index,           // start at tapped card
              onEdit: (c) => _edit(c),       // keep your edit/delete actions
              onDelete: (c) => _delete(c),
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                child: imageFromDataUrl(card.front, fit: BoxFit.cover),
              ),
            ),
            ListTile(
              dense: true,
              title: Text(card.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'edit') _edit(card);
                  if (v == 'rename') _renameCard(card);
                  if (v == 'delete') _delete(card);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit images')),
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
      setState(() => _cards.add(created));
      await _save();
    }
  }

  Future<void> _edit(FlashcardData card) async {
    final updated = await Navigator.of(context).push<FlashcardData?>(
        MaterialPageRoute(
            builder: (_) => EditFlashcardPage(existing: card)));
    if (updated != null) {
      final idx = _cards.indexWhere((c) => c.id == updated.id);
      if (idx != -1) {
        setState(() => _cards[idx] = updated);
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
      setState(() => _cards[idx] = FlashcardData(
          id: card.id, title: title, front: card.front, back: card.back));
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

  // -------- Export honoring Settings (ask/docs/custom) --------
// NEW: export as .jsonl (NDJSON) for big decks
  Future<void> _exportDeckJsonl() async {
    try {
      final slug = _safeFileSlug(widget.deck.name);
      final fileName = 'deck_${slug}_${DateTime.now().millisecondsSinceEpoch}.jsonl';

      // stream write
      final tmp = await getTemporaryDirectory();
      final tmpPath = p.join(tmp.path, fileName);
      final sink = io.File(tmpPath).openWrite();

      // minimal header (optional): first line can store deck meta
      sink.writeln(jsonEncode({
        '_meta': {
          'schema': 'flashcards.simple.v1',
          'deck': {'id': widget.deck.id, 'name': widget.deck.name},
          'exportedAt': DateTime.now().toIso8601String(),
          'format': 'jsonl'
        }
      }));

      for (final c in _cards) {
        sink.writeln(jsonEncode(c.toJson()));
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
      if (savedPath == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Export canceled')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved to: $savedPath')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export (jsonl) failed: $e')),
        );
      }
    }
  }





  // --- Share current deck as a .json file ---
  Future<void> _shareDeck() async {
    try {
      final deck = {
        'schema': 'flashcards.simple.v1',
        'deck': {'id': widget.deck.id, 'name': widget.deck.name},
        'exportedAt': DateTime.now().toIso8601String(),
        'cards': _cards.map((c) => c.toJson()).toList(),
      };
      final jsonStr = const JsonEncoder.withIndent('  ').convert(deck);

      final slug = _safeFileSlug(widget.deck.name);
      final fileName = 'deck_${slug}_${DateTime.now().millisecondsSinceEpoch}.json';

      // write to a temp file so share targets can read it
      final tmp = await getTemporaryDirectory();
      final path = p.join(tmp.path, fileName);
      await io.File(path).writeAsString(jsonStr);

      // share the file (no extra deps besides share_plus)
      await Share.shareXFiles(
        [XFile(path, mimeType: 'application/json', name: fileName)],
        subject: fileName,
        text: 'Flashcards deck: ${widget.deck.name}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Share failed: $e')),
        );
      }
    }
  }


// ============================================================================
// [ DECK PAGE ] -  import
// ============================================================================


  Future<void> _importDeck() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'jsonl', 'json.gz', 'deckjson'],
      withData: false,
    );
    if (res == null || res.files.isEmpty) return;

    final path = res.files.single.path;
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No file path available')),
        );
      }
      return;
    }

    // Progress dialog
    final progress = ValueNotifier<double?>(null);
    bool dialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => WillPopScope(
        onWillPop: () async => false,
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
            final newCards = <FlashcardData>[];
            for (final m in list) {
              try {
                final c = FlashcardData.fromJson(m);
                if (c.front.startsWith('data:') && c.back.startsWith('data:')) {
                  newCards.add(c);
                }
              } catch (_) {}
            }
            if (newCards.isNotEmpty) {
              // Deduplicate vs existing
              final ids = _cards.map((e) => e.id).toSet();
              final toAdd = newCards.where((c) => !ids.contains(c.id)).toList();

              if (toAdd.isNotEmpty) {
                setState(() => _cards.addAll(toAdd));
                await _save(); // persist incrementally
                importedCount += toAdd.length;
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

      if (imported.isEmpty) {
        if (mounted) {
          if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No valid cards found')),
          );
        }
        return;
      }

      final ids = _cards.map((e) => e.id).toSet();
      final merged = [..._cards, ...imported.where((c) => !ids.contains(c.id))];

      setState(() => _cards = merged);
      await _save();

      if (mounted) {
        if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Imported ${imported.length} card(s)')),
        );
      }
    } catch (e) {
      if (dialogOpen) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
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
          maxCrossAxisExtent: 220, // smaller tiles, more per row
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
              onPressed: _importDeck,
              tooltip: 'Import deck (.json)',
              icon: const Icon(Icons.file_open)
          ),
          IconButton(
              onPressed: _exportDeck,
              tooltip: 'Export deck',
              icon: const Icon(Icons.download)
          ),
          // NEW: export JSONL button
          IconButton(
            onPressed: _exportDeckJsonl, // <== call your new method
            tooltip: 'Export deck (JSONL)',
            icon: const Icon(Icons.data_object), // you can pick another icon
          ),
          IconButton(
              onPressed: _load,
              tooltip: 'Reload',
              icon: const Icon(Icons.refresh)
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
          onPressed: _create,
          icon: const Icon(Icons.add),
          label: const Text('New Card')),
    );
  }
}

// ============================================================================
// [ EDIT CARD PAGE ] - choose front/back images + title
// ============================================================================

class EditFlashcardPage extends StatefulWidget {
  final FlashcardData? existing;
  const EditFlashcardPage({super.key, this.existing});

  @override
  State<EditFlashcardPage> createState() => _EditFlashcardPageState();
}

class _EditFlashcardPageState extends State<EditFlashcardPage> {
  String? _front;
  String? _back;
  late final TextEditingController _title;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _front = widget.existing?.front;
    _back = widget.existing?.back;
    _title = TextEditingController(text: widget.existing?.title ?? 'Card');
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pick(bool isFront) async {
    final dataUrl = await pickImageAsDataUrl(context,
        hint: isFront ? 'front' : 'back');
    if (dataUrl == null) return;
    setState(() {
      if (isFront) {
        _front = dataUrl;
      } else {
        _back = dataUrl;
      }
    });
  }

  Future<void> _save() async {
    if (_front == null || _back == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Please select both front and back images.')));
      }
      return;
    }
    setState(() => _saving = true);
    final id = widget.existing?.id ??
        DateTime.now().millisecondsSinceEpoch.toString();
    final card = FlashcardData(
        id: id,
        title: _title.text.trim().isEmpty ? 'Card' : _title.text.trim(),
        front: _front!,
        back: _back!);
    if (mounted) Navigator.of(context).pop(card);
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(
          title: Text(isEditing ? 'Edit Card' : 'Create Card')),
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
              Expanded(
                child: GestureDetector(
                  onTap: () => _pick(true),
                  child: Card(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: _front == null
                          ? Container(
                          color: Colors.grey[200],
                          child: const Center(
                              child: Icon(Icons.image,
                                  size: 56, color: Colors.grey)))
                          : imageFromDataUrl(_front!, fit: BoxFit.cover),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: () => _pick(false),
                  child: Card(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: _back == null
                          ? Container(
                          color: Colors.grey[200],
                          child: const Center(
                              child: Icon(Icons.image,
                                  size: 56, color: Colors.grey)))
                          : imageFromDataUrl(_back!, fit: BoxFit.cover),
                    ),
                  ),
                ),
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
// [ VIEW CARD PAGE ] - flip front/back
// ============================================================================

class ViewFlashcardPage extends StatelessWidget {
  final FlashcardData card;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const ViewFlashcardPage(
      {super.key,
        required this.card,
        required this.onEdit,
        required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(card.title), actions: [
        IconButton(onPressed: onEdit, icon: const Icon(Icons.edit)),
        IconButton(
            onPressed: () {
              onDelete();
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.delete)),
      ]),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Card(
            elevation: 6,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: 420,
                width: 320,
                child: FlipCard(
                  front: imageFromDataUrl(card.front, fit: BoxFit.cover),
                  back: imageFromDataUrl(card.back, fit: BoxFit.cover),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
class SwipeViewerPage extends StatefulWidget {
  final List<FlashcardData> cards;
  final int initialIndex;
  final Future<void> Function(FlashcardData)? onEdit;
  final Future<void> Function(FlashcardData)? onDelete;

  const SwipeViewerPage({
    super.key,
    required this.cards,
    required this.initialIndex,
    this.onEdit,
    this.onDelete,
  });

  @override
  State<SwipeViewerPage> createState() => _SwipeViewerPageState();
}

class _SwipeViewerPageState extends State<SwipeViewerPage> {
  late final PageController _controller;
  late int _index;

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

  @override
  Widget build(BuildContext context) {
    if (widget.cards.isEmpty) {
      return const Scaffold(body: Center(child: Text('No cards')));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.cards[_index].title}  (${_index + 1}/${widget.cards.length})'),
        actions: [
          if (widget.onEdit != null)
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () => widget.onEdit!(widget.cards[_index]),
              tooltip: 'Edit',
            ),
          if (widget.onDelete != null)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () async {
                final current = widget.cards[_index];
                await widget.onDelete!(current);
                if (!mounted) return;
                if (_index >= widget.cards.length) {
                  Navigator.pop(context); // deck now shorter than index
                } else {
                  setState(() {}); // reflect deck changes
                }
              },
              tooltip: 'Delete',
            ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        onPageChanged: (i) => setState(() => _index = i),
        itemCount: widget.cards.length,
        itemBuilder: (_, i) {
          final card = widget.cards[i];
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Card(
                elevation: 6,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    width: 320,
                    height: 420,
                    child: FlipCard(
                      front: imageFromDataUrl(card.front, fit: BoxFit.cover),
                      back: imageFromDataUrl(card.back, fit: BoxFit.cover),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
      // (Optional) little nudge buttons in case you prefer taps over swipes
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

