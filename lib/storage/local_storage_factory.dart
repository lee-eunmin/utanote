// Platform storage selection.
//
// This app targets Android and Web only. Android (dart:io available) gets
// the SQLite-backed implementation; everything else (Web) gets the
// browser-local implementation. Using a conditional export means neither
// platform-specific file is compiled into the other platform's build — e.g.
// sqflite is never pulled into the web bundle.
export 'web/web_local_storage.dart'
    if (dart.library.io) 'android/sqlite_local_storage.dart';
