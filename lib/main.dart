// --------------------------- main.dart ---------------------------
// A single-file Flutter app that creates image flashcards and shares
// decks via JSON (no backend). Works on web & desktop/mobile.
//
// pubspec deps needed:
// flip_card, image_picker, file_picker, shared_preferences,
// share_plus, path_provider

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
import 'package:flutter/services.dart' as services; // <-- alias fixes Clipboard refs

void main() => runApp(const MyApp());

// --------------------------- Model ---------------------------

class FlashcardData {
  final String id;
  final String front; // data URL
  final String back;  // data URL

  const FlashcardData({required this.id, required this.front, required this.back});

  Map<String, dynamic> toJson() => {'id': id, 'front': front, 'back': back};

  static FlashcardData fromJson(Map<String, dynamic> json) => FlashcardData(
        id: json['id'] as String,
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

Widget imageFromDataUrl(String dataUrl, {BoxFit fit = BoxFit.contain}) {
  final bytes = _dataUrlToBytes(dataUrl);
  return Image.memory(bytes, fit: fit, gaplessPlayback: true);
}

Future<String?> pickImageAsDataUrl(BuildContext context, {required String hint}) async {
  // Mobile/desktop
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
              onTap: () => Navigator.of(ctx).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Gallery'),
              onTap: () => Navigator.of(ctx).pop(ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Pick from files'),
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ],
        ),
      ),
    );

    if (source != null) {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: source, imageQuality: 85);
      if (picked != null) {
        final bytes = await picked.readAsBytes();
        final mime = _guessMimeFromName(picked.name); // <- NO .mimeType
        return _bytesToDataUrl(bytes, mime: mime);
      }
    }
  }

  // Web or fallback: FilePicker
  try {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    if (file.bytes == null) return null;
    final mime = _guessMimeFromName(file.name); // <- NO .mimeType
    return _bytesToDataUrl(file.bytes!, mime: mime);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to pick file: $e')));
    }
    return null;
  }
}

// --------------------------- App ---------------------------

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flashcards (No Backend)',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.grey[100],
      ),
      home: const FlashcardListPage(),
    );
  }
}

class FlashcardListPage extends StatefulWidget {
  const FlashcardListPage({super.key});
  @override
  State<FlashcardListPage> createState() => _FlashcardListPageState();
}

class _FlashcardListPageState extends State<FlashcardListPage> {
  static const _prefsKey = 'flashcards_v3_dataurls';
  List<FlashcardData> _cards = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadCards();
  }

  Future<void> _loadCards() async {
    setState(() => _loading = true);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? [];
    _cards = raw.map((s) => FlashcardData.fromJson(jsonDecode(s) as Map<String, dynamic>)).toList();
    setState(() => _loading = false);
  }

  Future<void> _saveCards() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = _cards.map((c) => jsonEncode(c.toJson())).toList();
    await prefs.setStringList(_prefsKey, raw);
  }

  Future<void> _createNewCard() async {
    final created = await Navigator.of(context).push<FlashcardData?>(
      MaterialPageRoute(builder: (_) => const EditFlashcardPage()),
    );
    if (created != null) {
      setState(() => _cards.add(created));
      await _saveCards();
    }
  }

  Future<void> _editCard(FlashcardData card) async {
    final updated = await Navigator.of(context).push<FlashcardData?>(
      MaterialPageRoute(builder: (_) => EditFlashcardPage(existing: card)),
    );
    if (updated != null) {
      final idx = _cards.indexWhere((c) => c.id == updated.id);
      if (idx != -1) {
        setState(() => _cards[idx] = updated);
        await _saveCards();
      }
    }
  }

  Future<void> _deleteCard(FlashcardData card) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete card?'),
        content: const Text('This removes the card from your deck.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _cards.removeWhere((c) => c.id == card.id));
    await _saveCards();
  }

  Future<void> _exportDeck() async {
    final deck = {
      'schema': 'flashcards.simple.v1',
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
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Copy this JSON and send it to a friend. They can import it.'),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(jsonStr, style: const TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await services.Clipboard.setData(services.ClipboardData(text: jsonStr)); // <-- aliased
                if (ctx.mounted) Navigator.of(ctx).pop();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
                }
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
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/flashcards_export_${DateTime.now().millisecondsSinceEpoch}.json';
      final file = io.File(path);
      await file.writeAsString(jsonStr);
      await Share.shareXFiles([XFile(file.path, mimeType: 'application/json')], text: 'My Flashcards Deck');
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
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No valid cards found in file')));
        }
        return;
      }

      final ids = _cards.map((e) => e.id).toSet();
      final merged = [..._cards, ...imported.where((c) => !ids.contains(c.id))];

      setState(() => _cards = merged);
      await _saveCards();
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
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ViewFlashcardPage(
            card: card,
            onEdit: () => _editCard(card),
            onDelete: () => _deleteCard(card),
          ),
        ),
      ),
      borderRadius: BorderRadius.circular(12),
      child: Card(
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                child: imageFromDataUrl(card.front, fit: BoxFit.cover),
              ),
            ),
            ListTile(
              title: Text('Card ${card.id.substring(card.id.length - 6)}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(icon: const Icon(Icons.edit), onPressed: () => _editCard(card)),
                  IconButton(icon: const Icon(Icons.delete), onPressed: () => _deleteCard(card)),
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
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.photo_library, size: 90, color: Colors.grey),
                    const SizedBox(height: 12),
                    const Text('No flashcards yet', style: TextStyle(fontSize: 18, color: Colors.grey)),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: _createNewCard,
                      icon: const Icon(Icons.add),
                      label: const Text('Create first card'),
                    ),
                  ],
                ),
              )
            : Padding(
                padding: const EdgeInsets.all(12),
                child: GridView.builder(
                  itemCount: _cards.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.75,
                  ),
                  itemBuilder: (_, i) => _gridTile(_cards[i]),
                ),
              );

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Flashcards (Offline & Shareable)'),
        actions: [
          IconButton(onPressed: _importDeck, tooltip: 'Import deck (.json)', icon: const Icon(Icons.file_open)),
          IconButton(onPressed: _exportDeck, tooltip: 'Export deck', icon: const Icon(Icons.ios_share)),
          IconButton(onPressed: _loadCards, tooltip: 'Reload', icon: const Icon(Icons.refresh)),
        ],
      ),
      body: body,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNewCard,
        icon: const Icon(Icons.add),
        label: const Text('New Card'),
      ),
    );
  }
}

// --------------------------- Edit Page ---------------------------

class EditFlashcardPage extends StatefulWidget {
  final FlashcardData? existing;
  const EditFlashcardPage({super.key, this.existing});

  @override
  State<EditFlashcardPage> createState() => _EditFlashcardPageState();
}

class _EditFlashcardPageState extends State<EditFlashcardPage> {
  String? _front;
  String? _back;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _front = widget.existing?.front;
    _back = widget.existing?.back;
  }

  Future<void> _pick(bool isFront) async {
    final dataUrl = await pickImageAsDataUrl(context, hint: isFront ? 'front' : 'back');
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select both front and back images.')),
        );
      }
      return;
    }
    setState(() => _saving = true);
    final id = widget.existing?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
    final card = FlashcardData(id: id, front: _front!, back: _back!);
    if (mounted) Navigator.of(context).pop(card);
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEditing ? 'Edit Card' : 'Create Card')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => _pick(true),
                      child: Card(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: _front == null
                              ? Container(color: Colors.grey[200], child: const Center(child: Icon(Icons.image, size: 56, color: Colors.grey)))
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
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: _back == null
                              ? Container(color: Colors.grey[200], child: const Center(child: Icon(Icons.image, size: 56, color: Colors.grey)))
                              : imageFromDataUrl(_back!, fit: BoxFit.cover),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.save),
                    label: Text(_saving ? 'Saving...' : (isEditing ? 'Save changes' : 'Create card')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// --------------------------- View Page ---------------------------

class ViewFlashcardPage extends StatelessWidget {
  final FlashcardData card;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const ViewFlashcardPage({super.key, required this.card, required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flashcard'),
        actions: [
          IconButton(onPressed: onEdit, icon: const Icon(Icons.edit)),
          IconButton(
            onPressed: () {
              onDelete();
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.delete),
          ),
        ],
      ),
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
