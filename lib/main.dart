// --------------------------- main.dart (Decks + smaller cards + rename) ---------------------------
// A Flutter app for image flashcards with:
// - Smaller, denser grid on home deck page
// - Deck (folder) system
// - Rename cards and decks
// - Import/Export per deck (no backend)
//
// pubspec deps needed (same as before):
//   flip_card, image_picker, file_picker, shared_preferences,
//   share_plus, path_provider

import 'dart:convert';
import 'package:flip_card/flip_card.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io' as io; // only used on non-web
import 'package:flutter/services.dart' as services; // Clipboard
import 'package:path/path.dart' as p;

void main() => runApp(const MyApp());

// --------------------------- Models ---------------------------

class DeckMeta {
  final String id;
  final String name;
  const DeckMeta({required this.id, required this.name});

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  static DeckMeta fromJson(Map<String, dynamic> j) => DeckMeta(id: j['id'] as String, name: j['name'] as String);
}

class FlashcardData {
  final String id;
  final String title; // user-renameable
  final String front; // data URL
  final String back;  // data URL

  const FlashcardData({required this.id, required this.title, required this.front, required this.back});

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'front': front, 'back': back};

  static FlashcardData fromJson(Map<String, dynamic> json) => FlashcardData(
        id: json['id'] as String,
        title: (json['title'] as String?) ?? 'Card',
        front: json['front'] as String,
        back: json['back'] as String,
      );
}

// --------------------------- Helpers ---------------------------

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


Future<String?> pickImageAsDataUrl(BuildContext context, {required String hint}) async {
  // Mobile/desktop chooser
  if (!kIsWeb) {
    final source = await showDialog<ImageSource>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose image source'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.camera_alt), title: const Text('Camera'), onTap: () => Navigator.of(ctx).pop(ImageSource.camera)),
            ListTile(leading: const Icon(Icons.photo_library), title: const Text('Gallery'), onTap: () => Navigator.of(ctx).pop(ImageSource.gallery)),
            ListTile(leading: const Icon(Icons.upload_file), title: const Text('Pick from files'), onTap: () => Navigator.of(ctx).pop()),
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

  // Web or fallback via file picker
  try {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    if (file.bytes == null) return null;
    final mime = _guessMimeFromName(file.name);
    return _bytesToDataUrl(file.bytes!, mime: mime);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to pick file: $e')));
    }
    return null;
  }
}

// --------------------------- Storage ---------------------------

class Store {
  static const decksKey = 'decks_v1';
  static String cardsKey(String deckId) => 'deck_${deckId}_cards_v1';

  static Future<List<DeckMeta>> loadDecks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(decksKey) ?? [];
    return raw.map((s) => DeckMeta.fromJson(jsonDecode(s) as Map<String, dynamic>)).toList();
  }

  static Future<void> saveDecks(List<DeckMeta> decks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(decksKey, decks.map((d) => jsonEncode(d.toJson())).toList());
  }

  static Future<List<FlashcardData>> loadCards(String deckId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(cardsKey(deckId)) ?? [];
    return raw.map((s) => FlashcardData.fromJson(jsonDecode(s) as Map<String, dynamic>)).toList();
  }

  static Future<void> saveCards(String deckId, List<FlashcardData> cards) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(cardsKey(deckId), cards.map((c) => jsonEncode(c.toJson())).toList());
  }
}

// --------------------------- App ---------------------------

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flashcards (Decks, Offline)',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo), useMaterial3: true, scaffoldBackgroundColor: Colors.grey[100]),
      home: const DeckListPage(),
    );
  }
}

// --------------------------- Deck List (Folders) ---------------------------

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
        content: TextField(controller: controller, decoration: const InputDecoration(labelText: 'Deck name')), 
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final deck = DeckMeta(id: DateTime.now().millisecondsSinceEpoch.toString(), name: name);
    setState(() => _decks.add(deck));
    await Store.saveDecks(_decks);
  }

  Future<void> _renameDeck(DeckMeta deck) async {
    final controller = TextEditingController(text: deck.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Deck'),
        content: TextField(controller: controller, decoration: const InputDecoration(labelText: 'Deck name')),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: const Text('Save')),
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
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _decks.removeWhere((d) => d.id == deck.id));
    await Store.saveDecks(_decks);
    // Optionally clear cards storage for that deck
    await Store.saveCards(deck.id, const []);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Decks')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _decks.isEmpty
              ? Center(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.folder_open, size: 90, color: Colors.grey),
                    const SizedBox(height: 8),
                    const Text('No decks yet'),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(onPressed: _createDeck, icon: const Icon(Icons.add), label: const Text('Create your first deck')),
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
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => DeckPage(deck: d))),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'rename') _renameDeck(d);
                          if (v == 'delete') _deleteDeck(d);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'rename', child: Text('Rename')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(onPressed: _createDeck, icon: const Icon(Icons.create_new_folder), label: const Text('New Deck')),
    );
  }
}

// --------------------------- Deck Page (smaller cards + per-deck import/export) ---------------------------

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

  Future<void> _load() async {
    setState(() => _loading = true);
    _cards = await Store.loadCards(widget.deck.id);
    setState(() => _loading = false);
  }

  Future<void> _save() async => Store.saveCards(widget.deck.id, _cards);

  Future<void> _create() async {
    final created = await Navigator.of(context).push<FlashcardData?>(MaterialPageRoute(builder: (_) => const EditFlashcardPage()));
    if (created != null) {
      setState(() => _cards.add(created));
      await _save();
    }
  }

  Future<void> _edit(FlashcardData card) async {
    final updated = await Navigator.of(context).push<FlashcardData?>(MaterialPageRoute(builder: (_) => EditFlashcardPage(existing: card)));
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
        content: TextField(controller: controller, decoration: const InputDecoration(labelText: 'Title')),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;
    final idx = _cards.indexWhere((c) => c.id == card.id);
    if (idx != -1) {
      setState(() => _cards[idx] = FlashcardData(id: card.id, title: title, front: card.front, back: card.back));
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
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      setState(() => _cards.removeWhere((c) => c.id == card.id));
      await _save();
    }
  }

Future<void> _exportDeck() async {
  final deck = {
    'schema': 'flashcards.simple.v1',
    'deck': {'id': widget.deck.id, 'name': widget.deck.name},
    'exportedAt': DateTime.now().toIso8601String(),
    'cards': _cards.map((c) => c.toJson()).toList(),
  };
  final jsonStr = const JsonEncoder.withIndent('  ').convert(deck);

  if (kIsWeb) {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export Deck (Copy & Share)'),
        content: SizedBox(
          width: 520,
          height: 360,
          child: Column(
            children: [
              const Align(alignment: Alignment.centerLeft, child: Text('Copy this JSON and save it as .json')),
              const SizedBox(height: 8),
              Expanded(child: SingleChildScrollView(child: SelectableText(jsonStr, style: const TextStyle(fontSize: 12)))),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await services.Clipboard.setData(services.ClipboardData(text: jsonStr));
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            child: const Text('Copy'),
          ),
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
        ],
      ),
    );
    return;
  }

  try {
    // Build a safe file name from the deck title
    final slug = _safeFileSlug(widget.deck.name);
    final fileName = 'deck_${slug}_${DateTime.now().millisecondsSinceEpoch}.json';

    // Figure out a Downloads directory
    String? downloads;
    if (io.Platform.isWindows) {
      final home = io.Platform.environment['USERPROFILE'];
      if (home != null && home.isNotEmpty) {
        downloads = p.join(home, 'Downloads');
      }
    } else if (io.Platform.isMacOS || io.Platform.isLinux) {
      try {
        final d = await getDownloadsDirectory(); // may be null on some setups
        downloads = d?.path;
      } catch (_) {}
    }
    // Fallback to temp if we couldn't find Downloads
    downloads ??= (await getTemporaryDirectory()).path;

    // Final path (cross-platform safe)
    final fullPath = p.join(downloads, fileName);
    await io.File(fullPath).writeAsString(jsonStr);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to: $fullPath')),
      );
    }
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }
}


  Future<void> _importDeck() async {
    try {
      final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json'], withData: true);
      if (res == null || res.files.isEmpty) return;
      final file = res.files.single;
      final bytes = file.bytes ?? await io.File(file.path!).readAsBytes();
      final str = utf8.decode(bytes);
      final decoded = jsonDecode(str);
      if (decoded is! Map) throw Exception('Invalid deck format');
      if (decoded['schema'] != 'flashcards.simple.v1') throw Exception('Unknown deck schema');
      final cardsJson = decoded['cards'];
      if (cardsJson is! List) throw Exception('Invalid cards array');

      final imported = <FlashcardData>[];
      for (final item in cardsJson) {
        if (item is! Map) continue;
        try {
          final c = FlashcardData.fromJson(item.cast<String, dynamic>());
          if (!c.front.startsWith('data:') || !c.back.startsWith('data:')) continue;
          imported.add(c);
        } catch (_) {}
      }

      if (imported.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No valid cards found')));
        }
        return;
      }

      final ids = _cards.map((e) => e.id).toSet();
      final merged = [..._cards, ...imported.where((c) => !ids.contains(c.id))];
      setState(() => _cards = merged);
      await _save();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Imported ${imported.length} card(s)')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    }
  }

  Widget _gridTile(FlashcardData card) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ViewFlashcardPage(
              card: card,
              onEdit: () => _edit(card),
              onDelete: () => _delete(card),
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

  @override
  Widget build(BuildContext context) {
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _cards.isEmpty
            ? Center(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.photo_library, size: 90, color: Colors.grey),
                  const SizedBox(height: 8),
                  const Text('No cards in this deck'),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(onPressed: _create, icon: const Icon(Icons.add), label: const Text('Create first card')),
                ]),
              )
            : Padding(
                padding: const EdgeInsets.all(12),
                child: GridView.builder(
                  itemCount: _cards.length,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220, // <- smaller tiles, more per row
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.72,
                  ),
                  itemBuilder: (_, i) => _gridTile(_cards[i]),
                ),
              );

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.deck.name),
        actions: [
          IconButton(onPressed: _importDeck, tooltip: 'Import deck (.json)', icon: const Icon(Icons.file_open)),
          IconButton(onPressed: _exportDeck, tooltip: 'Export deck', icon: const Icon(Icons.download)),
          IconButton(onPressed: _load, tooltip: 'Reload', icon: const Icon(Icons.refresh)),
        ],
      ),
      body: body,
      floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add), label: const Text('New Card')),
    );
  }
}

// --------------------------- Edit Card ---------------------------

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
    final dataUrl = await pickImageAsDataUrl(context, hint: isFront ? 'front' : 'back');
    if (dataUrl == null) return;
    setState(() { if (isFront) _front = dataUrl; else _back = dataUrl; });
  }

  Future<void> _save() async {
    if (_front == null || _back == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select both front and back images.')));
      }
      return;
    }
    setState(() => _saving = true);
    final id = widget.existing?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
    final card = FlashcardData(id: id, title: _title.text.trim().isEmpty ? 'Card' : _title.text.trim(), front: _front!, back: _back!);
    if (mounted) Navigator.of(context).pop(card);
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEditing ? 'Edit Card' : 'Create Card')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          TextField(controller: _title, decoration: const InputDecoration(labelText: 'Title (optional)')),
          const SizedBox(height: 8),
          Expanded(
            child: Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => _pick(true),
                  child: Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: _front == null ? Container(color: Colors.grey[200], child: const Center(child: Icon(Icons.image, size: 56, color: Colors.grey))) : imageFromDataUrl(_front!, fit: BoxFit.cover),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: () => _pick(false),
                  child: Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: _back == null ? Container(color: Colors.grey[200], child: const Center(child: Icon(Icons.image, size: 56, color: Colors.grey))) : imageFromDataUrl(_back!, fit: BoxFit.cover),
                    ),
                  ),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: ElevatedButton.icon(onPressed: _saving ? null : _save, icon: const Icon(Icons.save), label: Text(_saving ? 'Saving...' : (isEditing ? 'Save changes' : 'Create card')))),
          ])
        ]),
      ),
    );
  }
}

// --------------------------- View Card ---------------------------

class ViewFlashcardPage extends StatelessWidget {
  final FlashcardData card;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const ViewFlashcardPage({super.key, required this.card, required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(card.title), actions: [
        IconButton(onPressed: onEdit, icon: const Icon(Icons.edit)),
        IconButton(onPressed: () { onDelete(); Navigator.of(context).pop(); }, icon: const Icon(Icons.delete)),
      ]),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Card(
            elevation: 6,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
