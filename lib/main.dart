import 'package:flutter/material.dart';

import 'storage/local_storage.dart';
import 'storage/local_storage_factory.dart';
import 'theme/app_theme.dart';
import 'ui/app_shell.dart';

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
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: AppShell(storage: storage),
    );
  }
}
