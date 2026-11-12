import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:utanote/main.dart';
import 'package:utanote/storage/memory/in_memory_local_storage.dart';
import 'package:utanote/ui/widgets/keyboard_dismiss.dart';

/// App-wide "tap outside a text field closes the keyboard"
/// ([DismissKeyboardOnTapOutside], installed in `MaterialApp.builder`).
void main() {
  late int buttonTaps;

  Widget app({Widget? extra}) => MaterialApp(
        builder: (context, child) =>
            DismissKeyboardOnTapOutside(child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => ListView(
              children: [
                const TextField(key: Key('a')),
                const TextField(key: Key('b')),
                TextButton(
                  key: const Key('button'),
                  onPressed: () => buttonTaps++,
                  child: const Text('버튼'),
                ),
                TextButton(
                  key: const Key('openSheet'),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextField(key: Key('sheetField')),
                          SizedBox(height: 200),
                        ],
                      ),
                    ),
                  ),
                  child: const Text('시트'),
                ),
                const SizedBox(key: Key('empty'), height: 600),
                ?extra,
              ],
            ),
          ),
        ),
      );

  FocusNode focusOf(WidgetTester tester, String key) => tester
      .widget<EditableText>(
        find.descendant(of: find.byKey(Key(key)), matching: find.byType(EditableText)),
      )
      .focusNode;

  setUp(() => buttonTaps = 0);

  testWidgets('tap on an empty area unfocuses and hides the keyboard',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const Key('a')));
    await tester.pump();
    expect(focusOf(tester, 'a').hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tapAt(tester.getCenter(find.byKey(const Key('empty'))));
    await tester.pump();
    expect(focusOf(tester, 'a').hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('tap inside the focused field keeps the keyboard', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const Key('a')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('a')));
    await tester.pump();
    expect(focusOf(tester, 'a').hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('tap on another field moves focus without hiding the keyboard',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const Key('a')));
    await tester.pump();
    tester.testTextInput.log.clear();

    await tester.tap(find.byKey(const Key('b')));
    await tester.pump();
    expect(focusOf(tester, 'a').hasFocus, isFalse);
    expect(focusOf(tester, 'b').hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(
      tester.testTextInput.log.map((c) => c.method),
      isNot(contains('TextInput.hide')),
    );
  });

  testWidgets('buttons still work and the keyboard closes', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const Key('a')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('button')));
    await tester.pump();
    expect(buttonTaps, 1);
    expect(focusOf(tester, 'a').hasFocus, isFalse);
  });

  testWidgets('a drag outside the field is not a tap (keyboard stays)',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const Key('a')));
    await tester.pump();
    final node = focusOf(tester, 'a');
    // Slow drag (no fling), so field "a" stays built.
    await tester.timedDragFrom(
      tester.getCenter(find.byKey(const Key('empty'))),
      const Offset(0, -40),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('works inside a bottom sheet (above the Navigator)',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const Key('openSheet')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sheetField')));
    await tester.pump();
    expect(focusOf(tester, 'sheetField').hasFocus, isTrue);

    // An empty spot inside the sheet: keyboard closes, sheet stays open.
    final field = tester.getRect(find.byKey(const Key('sheetField')));
    await tester.tapAt(field.bottomCenter + const Offset(0, 100));
    await tester.pump();
    expect(focusOf(tester, 'sheetField').hasFocus, isFalse);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sheetField')), findsOneWidget);
  });

  testWidgets('mouse keeps Flutter\'s default (unfocus on pointer down)',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const Key('a')));
    await tester.pump();
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(tester.getCenter(find.byKey(const Key('empty'))));
    await tester.pump();
    expect(focusOf(tester, 'a').hasFocus, isFalse);
    await gesture.up();
  });

  testWidgets('installed app-wide by UtaNoteApp', (tester) async {
    final storage = InMemoryLocalStorage();
    await storage.init();
    await tester.pumpWidget(UtaNoteApp(storage: storage));
    await tester.pumpAndSettle();
    expect(find.byType(DismissKeyboardOnTapOutside), findsOneWidget);
  });
}
