import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flip_card/flip_card.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: FlashcardPage(),
    );
  }
}

class FlashcardPage extends StatefulWidget {
  @override
  _FlashcardPageState createState() => _FlashcardPageState();
}

class _FlashcardPageState extends State<FlashcardPage> {
  String? frontImage;
  String? backImage;

  Future<void> _pickImage(bool isFront) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.camera);
    if (pickedFile != null) {
      setState(() {
        if (isFront) {
          frontImage = pickedFile.path;
        } else {
          backImage = pickedFile.path;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Photo Flashcard')),
      body: Center(
        child: (frontImage != null && backImage != null)
            ? FlipCard(
                front: Image.file(File(frontImage!), fit: BoxFit.cover),
                back: Image.file(File(backImage!), fit: BoxFit.cover),
              )
            : const Text('Take two photos to create a card'),
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            onPressed: () => _pickImage(true),
            child: const Icon(Icons.camera_front),
          ),
          const SizedBox(height: 16),
          FloatingActionButton(
            onPressed: () => _pickImage(false),
            child: const Icon(Icons.camera_rear),
          ),
        ],
      ),
    );
  }
}
