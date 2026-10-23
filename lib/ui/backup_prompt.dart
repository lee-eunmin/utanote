import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/account_controller.dart';
import '../account/auth_gateway.dart';
import '../storage/local_storage.dart';
import '../theme/app_theme.dart';
import 'widgets/account_button.dart';

/// Where "나중에" is remembered. A local, per-device UI setting — not user
/// song data, so it is never synced.
abstract class BackupPromptPrefs {
  /// UTC epoch ms of the last "나중에" / dismissal, or null.
  Future<int?> snoozedAtMs();
  Future<void> setSnoozedAtMs(int utcMs);
}

class SharedPreferencesBackupPromptPrefs implements BackupPromptPrefs {
  static const key = 'backup_prompt_snoozed_at_ms';

  @override
  Future<int?> snoozedAtMs() async =>
      (await SharedPreferences.getInstance()).getInt(key);

  @override
  Future<void> setSnoozedAtMs(int utcMs) async =>
      (await SharedPreferences.getInstance()).setInt(key, utcMs);
}

/// After "나중에" (or closing the sheet), the prompt stays away this long.
const Duration kBackupPromptSnooze = Duration(days: 7);

/// What the prompt's main button does.
enum BackupPromptAction {
  /// Signed out: sign in with Google, then set up the backup.
  connectGoogle,

  /// Already signed in, device not bound: go straight to the first
  /// connection (no account picker again).
  setUpBackup,
}

/// Decides whether to offer cloud backup now. Shown only when ALL hold:
/// - this build has cloud backup and sign-in is usable (not starting up,
///   not unavailable);
/// - the device is NOT bound to any account (`account_uid` absent) — the
///   binding is the final word: once bound, never again;
/// - signed in → that account is unlinked (not another account's device);
/// - at least one song is saved locally (brand-new users aren't nagged);
/// - not snoozed within [kBackupPromptSnooze].
/// Reads only; never writes anything.
Future<BackupPromptAction?> evaluateBackupPrompt({
  required AccountController account,
  required LocalStorage storage,
  required BackupPromptPrefs prefs,
  required int nowMs,
}) async {
  if (account.cloudSync == null) return null;
  final phase = account.phase;
  if (phase != AccountPhase.signedOut && phase != AccountPhase.signedIn) {
    return null;
  }
  if (await account.readBoundAccountUid() != null) return null;
  if (phase == AccountPhase.signedIn &&
      account.linkStatus != AccountLinkStatus.unlinked) {
    return null;
  }
  if ((await storage.songs.getAll()).isEmpty) return null;
  final snoozed = await prefs.snoozedAtMs();
  if (snoozed != null && nowMs - snoozed < kBackupPromptSnooze.inMilliseconds) {
    return null;
  }
  return phase == AccountPhase.signedIn
      ? BackupPromptAction.setUpBackup
      : BackupPromptAction.connectGoogle;
}

/// Checks once per app launch, after the first screen has settled and
/// sign-in has finished starting, and shows [BackupPromptSheet] if
/// [evaluateBackupPrompt] says so.
class BackupPromptGate extends StatefulWidget {
  final AccountController? account;
  final LocalStorage storage;

  /// Null → no prompt (Web, tests that don't opt in).
  final BackupPromptPrefs? prefs;

  /// Settle time after the first frame.
  final Duration delay;

  /// Longest wait for sign-in to finish starting before giving up for
  /// this launch.
  final Duration accountTimeout;

  final int Function() now;
  final Widget child;

  const BackupPromptGate({
    super.key,
    required this.account,
    required this.storage,
    required this.prefs,
    required this.child,
    this.delay = const Duration(milliseconds: 1500),
    this.accountTimeout = const Duration(seconds: 10),
    this.now = _utcNowMs,
  });

  static int _utcNowMs() => DateTime.now().toUtc().millisecondsSinceEpoch;

  @override
  State<BackupPromptGate> createState() => _BackupPromptGateState();
}

class _BackupPromptGateState extends State<BackupPromptGate> {
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    if (widget.account != null && widget.prefs != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    }
  }

  Future<void> _check() async {
    if (_checked) return;
    _checked = true;
    final account = widget.account!;
    final prefs = widget.prefs!;
    await Future<void>.delayed(widget.delay);
    if (!mounted) return;
    if (!await _accountSettled(account)) return;
    if (!mounted) return;
    BackupPromptAction? action;
    try {
      action = await evaluateBackupPrompt(
        account: account,
        storage: widget.storage,
        prefs: prefs,
        nowMs: widget.now(),
      );
    } catch (e) {
      debugPrint('[backup-prompt] check failed: $e');
      return;
    }
    if (action == null || !mounted) return;

    final choice = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => BackupPromptSheet(action: action!),
    );
    if (!mounted) return;
    if (choice != true) {
      // "나중에" or closed: remember it; nothing else changes.
      try {
        await prefs.setSnoozedAtMs(widget.now());
      } catch (_) {}
      return;
    }
    await _connect(account, action);
  }

  /// Waits (bounded) until sign-in has finished starting.
  Future<bool> _accountSettled(AccountController account) async {
    bool settled() =>
        account.phase != AccountPhase.initializing &&
        account.phase != AccountPhase.signingIn;
    if (settled()) return true;
    final done = Completer<void>();
    void listener() {
      if (settled() && !done.isCompleted) done.complete();
    }

    account.addListener(listener);
    try {
      await done.future.timeout(widget.accountTimeout);
      return true;
    } on TimeoutException {
      return false;
    } finally {
      account.removeListener(listener);
    }
  }

  Future<void> _connect(
    AccountController account,
    BackupPromptAction action,
  ) async {
    if (action == BackupPromptAction.connectGoogle) {
      await account.signIn(); // failures/cancel: shown by the account sheet
      if (!mounted) return;
    }
    final cloud = account.cloudSync;
    if (account.phase != AccountPhase.signedIn || cloud == null) return;
    if (account.linkStatus == AccountLinkStatus.unlinked) {
      // The existing first-connection flow, in the account sheet (progress,
      // merge/cancel choice, errors).
      unawaited(cloud.startSetup());
    }
    if (!mounted) return;
    await showAccountSheet(context, account);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// "노래를 안전하게 백업할까요?" — pops `true` for the main button, `false`
/// for "나중에" (null when dismissed).
class BackupPromptSheet extends StatelessWidget {
  final BackupPromptAction action;

  const BackupPromptSheet({super.key, required this.action});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.hairline,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '노래를 안전하게 백업할까요?',
                style: AppTextStyles.sheetTitle,
              ),
            ),
            const SizedBox(height: 12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Google 계정을 연결하면 앱을 삭제하거나 새 기기로 바꿔도 '
                '저장한 노래와 폴더를 다시 불러올 수 있어요.',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '이 기기에 저장된 데이터는 계정을 연결해도 삭제되지 않아요.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const Key('backupPromptConnect'),
              onPressed: () => Navigator.of(context).pop(true),
              icon: Icon(
                action == BackupPromptAction.connectGoogle
                    ? Icons.login_rounded
                    : Icons.cloud_upload_outlined,
                size: 18,
              ),
              label: Text(
                action == BackupPromptAction.connectGoogle
                    ? 'Google 계정 연결'
                    : '클라우드 백업 설정',
              ),
            ),
            const SizedBox(height: 6),
            TextButton(
              key: const Key('backupPromptLater'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('나중에'),
            ),
          ],
        ),
      ),
    );
  }
}
