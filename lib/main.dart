import 'package:flutter/material.dart';

import 'storage/local_storage.dart';
import 'storage/local_storage_factory.dart';
import 'ui/song_list_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = createLocalStorage();
  await storage.init();
  runApp(UtaNoteApp(storage: storage));
}

class UtaNoteApp extends StatelessWidget {
  final LocalStorage storage;

  const UtaNoteApp({super.key, required this.storage});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UtaNote',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: SongListScreen(storage: storage),
    );
  }
}
