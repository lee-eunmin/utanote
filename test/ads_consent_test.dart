import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:utanote/ads/ads_consent_controller.dart';
import 'package:utanote/storage/memory/in_memory_local_storage.dart';
import 'package:utanote/theme/app_theme.dart';
import 'package:utanote/ui/song_list_screen.dart';

/// Scriptable stand-in for Google's UMP consent APIs.
class _FakeConsentGateway implements ConsentGateway {
  bool canRequest = false;
  bool privacyRequired = false;
  Object? updateError;
  Object? formError;
  Object? canRequestError;
  Object? privacyFormError;

  /// Applied when the privacy options form is dismissed (user's new choice).
  bool? canRequestAfterPrivacyForm;

  final calls = <String>[];

  @override
  Future<void> requestConsentInfoUpdate() async {
    calls.add('update');
    if (updateError != null) throw updateError!;
  }

  @override
  Future<void> loadAndShowConsentFormIfRequired() async {
    calls.add('form');
    if (formError != null) throw formError!;
  }

  @override
  Future<bool> canRequestAds() async {
    calls.add('canRequestAds');
    if (canRequestError != null) throw canRequestError!;
    return canRequest;
  }

  @override
  Future<bool> isPrivacyOptionsRequired() async {
    calls.add('privacyStatus');
    return privacyRequired;
  }

  @override
  Future<void> showPrivacyOptionsForm() async {
    calls.add('privacyForm');
    if (privacyFormError != null) throw privacyFormError!;
    if (canRequestAfterPrivacyForm != null) {
      canRequest = canRequestAfterPrivacyForm!;
    }
  }
}

void main() {
  late _FakeConsentGateway gateway;
  late int sdkInitCount;
  late List<String> logs;
  late AdsConsentController controller;

  setUp(() {
    gateway = _FakeConsentGateway();
    sdkInitCount = 0;
    logs = [];
    controller = AdsConsentController(
      gateway: gateway,
      initializeSdk: () async => sdkInitCount++,
      log: logs.add,
    );
  });

  Future<bool> readyAfterMicrotasks() async {
    var ready = false;
    controller.adsReady.then((_) => ready = true);
    await pumpEventQueue();
    return ready;
  }

  group('AdsConsentController', () {
    test('ads stay disabled before the consent flow runs', () async {
      gateway.canRequest = true;
      expect(controller.canRequestAds, isFalse);
      expect(await readyAfterMicrotasks(), isFalse);
      expect(sdkInitCount, 0);
      expect(gateway.calls, isEmpty);
    });

    test('ads stay disabled when consent does not allow requests', () async {
      gateway.canRequest = false;
      await controller.start();
      expect(controller.canRequestAds, isFalse);
      expect(await readyAfterMicrotasks(), isFalse);
      expect(sdkInitCount, 0);
    });

    test('update → form → canRequestAds, then ads enabled', () async {
      gateway.canRequest = true;
      await controller.start();
      expect(gateway.calls.take(3), ['update', 'form', 'canRequestAds']);
      expect(controller.canRequestAds, isTrue);
      expect(await readyAfterMicrotasks(), isTrue);
      expect(sdkInitCount, 1);
    });

    test(
      'consent update failure still honours previous-session consent',
      () async {
        gateway
          ..updateError = Exception('network down')
          ..canRequest = true;
        await controller.start();
        expect(gateway.calls, isNot(contains('form')));
        expect(controller.canRequestAds, isTrue);
        expect(await readyAfterMicrotasks(), isTrue);
        expect(logs.single, contains('network down'));
      },
    );

    test('consent form failure still checks canRequestAds', () async {
      gateway
        ..formError = Exception('form failed')
        ..canRequest = true;
      await controller.start();
      expect(controller.canRequestAds, isTrue);
      expect(sdkInitCount, 1);
      expect(logs.single, contains('form failed'));
    });

    test('failure everywhere never throws and leaves ads disabled', () async {
      gateway
        ..updateError = Exception('a')
        ..canRequestError = Exception('b')
        ..privacyFormError = Exception('c');
      await expectLater(controller.start(), completes);
      await expectLater(controller.showPrivacyOptions(), completes);
      expect(controller.canRequestAds, isFalse);
      expect(controller.privacyOptionsRequired, isFalse);
      expect(sdkInitCount, 0);
    });

    test('SDK initialization failure does not throw', () async {
      final failing = AdsConsentController(
        gateway: gateway..canRequest = true,
        initializeSdk: () async => throw Exception('init failed'),
        log: logs.add,
      );
      await expectLater(failing.start(), completes);
      expect(logs.single, contains('init failed'));
    });

    test('SDK is initialized only once across every allowing path', () async {
      gateway
        ..canRequest = true
        ..privacyRequired = true;
      await Future.wait([controller.start(), controller.start()]);
      await controller.showPrivacyOptions();
      await controller.showPrivacyOptions();
      expect(gateway.calls.where((c) => c == 'update'), hasLength(1));
      expect(sdkInitCount, 1);
    });

    test('granting consent via privacy options enables ads', () async {
      gateway
        ..canRequest = false
        ..privacyRequired = true
        ..canRequestAfterPrivacyForm = true;
      await controller.start();
      expect(controller.canRequestAds, isFalse);
      await controller.showPrivacyOptions();
      expect(controller.canRequestAds, isTrue);
      expect(sdkInitCount, 1);
    });

    test('withdrawing consent via privacy options disables ads', () async {
      gateway
        ..canRequest = true
        ..privacyRequired = true
        ..canRequestAfterPrivacyForm = false;
      await controller.start();
      expect(controller.canRequestAds, isTrue);
      await controller.showPrivacyOptions();
      expect(controller.canRequestAds, isFalse);
    });

    test('reports privacy options requirement', () async {
      gateway.privacyRequired = true;
      await controller.start();
      expect(controller.privacyOptionsRequired, isTrue);
    });
  });

  group('privacy options entry', () {
    Future<void> pumpScreen(
      WidgetTester tester, {
      AdsConsentController? consent,
    }) async {
      final storage = InMemoryLocalStorage();
      await storage.init();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: SongListScreen(storage: storage, adsConsent: consent),
        ),
      );
      await tester.pumpAndSettle();
    }

    final button = find.byKey(const Key('privacyOptionsButton'));

    testWidgets('hidden without a consent controller (Web/iOS)', (
      tester,
    ) async {
      await pumpScreen(tester);
      expect(button, findsNothing);
      expect(find.byKey(const Key('addSongButton')), findsOneWidget);
    });

    testWidgets('hidden when privacy options are not required', (tester) async {
      gateway.privacyRequired = false;
      await controller.start();
      await pumpScreen(tester, consent: controller);
      expect(button, findsNothing);
    });

    testWidgets('appears once required, and opens the privacy form', (
      tester,
    ) async {
      gateway.privacyRequired = true;
      await pumpScreen(tester, consent: controller);
      expect(button, findsNothing);

      await tester.runAsync(controller.start);
      await tester.pumpAndSettle();
      expect(button, findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(gateway.calls, contains('privacyForm'));
    });
  });
}
