import 'dart:async';

import 'package:flutter/foundation.dart';

import '../account/account_controller.dart';
import '../account/auth_gateway.dart';
import 'initial_sync_engine.dart';
import 'manual_sync.dart';
import 'sync_records.dart';

enum CloudSyncPhase {
  /// Not signed in, or signed in with an account this device can't use.
  unavailable,

  /// Signed in, device not connected yet: offer "클라우드 백업 설정".
  notConnected,

  /// Reading the device and the cloud to decide what to do.
  checking,

  /// Both sides have data: waiting for the user's merge/cancel choice.
  needsMergeDecision,

  /// Uploading / restoring / merging.
  syncing,

  /// The device is bound to the signed-in account.
  connected,

  /// The last attempt failed; local data unchanged; can retry.
  failed,
}

/// State of a two-way sync run (manual or automatic) while
/// [CloudSyncPhase.connected].
enum ManualSyncStatus { idle, running, succeeded, failed }

/// Why an automatic sync was requested (Phase B-4B).
enum AutoSyncTrigger {
  /// The signed-in session was restored and the device is bound.
  appStart,

  /// The app came back to the foreground.
  appResume,

  /// A user write to songs/folders/memberships (after the debounce).
  dataChanged,

  /// A request that arrived while a sync was running.
  followUp,
}

/// Timing of automatic sync. Production values by default.
class AutoSyncConfig {
  /// Quiet time after the last user write before syncing.
  final Duration debounce;

  /// Minimum time between automatic start/resume syncs (from the last
  /// attempt, successful or not).
  final Duration resumeThrottle;

  /// After a failed sync, automatic syncs wait this long, doubling per
  /// consecutive failure up to [backoffMax]. "지금 동기화" ignores it.
  final Duration backoffBase;
  final Duration backoffMax;

  /// UTC epoch ms.
  final int Function() now;

  const AutoSyncConfig({
    this.debounce = const Duration(seconds: 5),
    this.resumeThrottle = const Duration(minutes: 1),
    this.backoffBase = const Duration(minutes: 1),
    this.backoffMax = const Duration(minutes: 15),
    this.now = _utcNowMs,
  });

  static int _utcNowMs() => DateTime.now().toUtc().millisecondsSinceEpoch;
}

/// A cloud backup found for a signed-in, unbound device with no songs
/// (the empty-songbook restore offer). Restoring it is the normal first
/// connection ([CloudSyncController.startSetup]).
class CloudRestoreOffer {
  final String uid;

  /// Live (not deleted) songs/folders in the cloud.
  final SyncDataSummary cloud;

  const CloudRestoreOffer({required this.uid, required this.cloud});
}

/// UI state of the first cloud connection and of two-way syncs.
///
/// The first connection ("클라우드 백업 설정") only ever runs when the user
/// asks. Two-way sync runs on "지금 동기화" and — when [AutoSyncConfig] is
/// given (Phase B-4B) — automatically, but only for a device bound to the
/// signed-in account: at start, on return to the foreground (throttled),
/// and a few seconds after user data changes (debounced). One sync at a
/// time; requests during a run are folded into one follow-up run.
class CloudSyncController extends ChangeNotifier {
  final InitialSyncEngine _engine;
  final AccountController _account;

  /// Two-way sync for a bound device (Phase B-4A). Null → no
  /// "지금 동기화" button and no automatic sync.
  final ManualSyncEngine? _manual;

  /// Null → no automatic sync (manual only).
  final AutoSyncConfig? _auto;

  /// Whether to look for a restorable cloud backup (read-only) when a
  /// device with no songs is signed in but not bound.
  final bool _findRestorableBackup;

  CloudSyncController({
    required this._engine,
    required this._account,
    this._manual,
    AutoSyncConfig? autoSync,
    this._findRestorableBackup = false,
  }) : _auto = autoSync {
    _account.addListener(_onAccountChanged);
    _onAccountChanged();
  }

  // --- empty-songbook restore offer (read-only lookup) ---
  CloudRestoreOffer? _restoreOffer;
  bool _restorePromptPending = false;
  bool _findingBackup = false;
  int _findToken = 0;
  Future<void>? _finding;

  /// Set while the user's own Google sign-in is in progress, so the
  /// lookup after it may show the "클라우드 백업을 찾았어요" prompt (a
  /// restored session only updates the account sheet / empty-list card).
  bool _interactiveSignIn = false;

  // --- automatic sync state ---
  Timer? _debounceTimer;
  Timer? _backoffTimer;
  bool _pendingSync = false;
  int? _lastAttemptMs;
  int _consecutiveFailures = 0;
  int _backoffUntilMs = 0;
  int _syncRuns = 0;

  /// The account the two-way sync result ([manualStatus], [manualMessage])
  /// and the failure backoff belong to. A result never outlives its
  /// account/binding: it is cleared when another uid signs in, when a new
  /// first connection completes, and when a binding is released or the
  /// account deleted. Null → nothing recorded.
  String? _statusUid;

  // --- account deletion (Phase B-5) ---
  bool _suspended = false;
  final List<Completer<void>> _idleWaiters = [];

  /// Number of two-way sync runs started (manual + automatic), for tests.
  @visibleForTesting
  int get syncRuns => _syncRuns;

  CloudSyncPhase _phase = CloudSyncPhase.unavailable;
  String? _message;
  InitialSyncAssessment? _pending;
  String? _uid;
  bool _busy = false;
  int _dataVersion = 0;
  ManualSyncStatus _manualStatus = ManualSyncStatus.idle;
  String? _manualMessage;
  int? _lastSyncAtMs;

  CloudSyncPhase get phase => _phase;

  /// User-facing notice for [CloudSyncPhase.failed].
  String? get message => _message;

  /// Device/cloud item counts while [CloudSyncPhase.needsMergeDecision].
  SyncDataSummary? get localSummary => _pending?.local;
  SyncDataSummary? get cloudSummary => _pending?.cloud;

  bool get busy => _busy;

  /// Every sync (first connection, "지금 동기화", automatic) is off while
  /// an account deletion runs or is unfinished (Phase B-5).
  bool get suspended => _suspended;

  /// Bumped whenever local songs/folders may have changed (restore/merge),
  /// so screens know to reload.
  int get dataVersion => _dataVersion;

  bool get canSyncNow => _manual != null;
  ManualSyncStatus get manualStatus => _manualStatus;

  /// User-facing notice for [ManualSyncStatus.failed].
  String? get manualMessage => _manualMessage;

  /// UTC epoch ms of the last fully successful sync, if known.
  int? get lastSyncAtMs => _lastSyncAtMs;

  /// A cloud backup this signed-in, unbound, song-less device can restore.
  /// Only while [CloudSyncPhase.notConnected] and nothing is running.
  CloudRestoreOffer? get restoreOffer =>
      _phase == CloudSyncPhase.notConnected && !_busy && !_suspended
      ? _restoreOffer
      : null;

  /// The read-only backup lookup is running.
  bool get findingBackup => _findingBackup;

  /// The offer to show once as a prompt right after the user signed in, or
  /// null. Each offer is handed out at most once; "나중에" keeps
  /// [restoreOffer] (the account sheet / empty list still offer restoring).
  CloudRestoreOffer? takeRestorePrompt() {
    final offer = restoreOffer;
    if (offer == null || !_restorePromptPending) return null;
    _restorePromptPending = false;
    return offer;
  }

  /// Completes when the current backup lookup (if any) has finished.
  @visibleForTesting
  Future<void> waitForBackupLookup() => _finding ?? Future<void>.value();

  void _onAccountChanged() {
    final accountPhase = _account.phase;
    if (accountPhase == AccountPhase.signingIn) {
      _interactiveSignIn = true;
    } else if (accountPhase != AccountPhase.signedIn) {
      _interactiveSignIn = false;
    }
    final interactive =
        accountPhase == AccountPhase.signedIn && _interactiveSignIn;
    if (accountPhase == AccountPhase.signedIn) _interactiveSignIn = false;

    // A sync result of another account must not be shown for this one
    // (e.g. old uid denied → account re-created with a new uid).
    final current = _account.phase == AccountPhase.signedIn
        ? _account.user?.uid
        : null;
    if (_statusUid != null && current != null && current != _statusUid) {
      _clearTwoWayStatus();
      notifyListeners();
    }
    if (_busy) return; // re-evaluated when the run ends
    final user = _account.user;
    final signedIn = _account.phase == AccountPhase.signedIn && user != null;
    if (!signedIn) {
      _uid = null;
      _pending = null;
      _message = null;
      _clearRestoreOffer();
      _set(CloudSyncPhase.unavailable);
      return;
    }
    final link = _account.linkStatus;
    if (link == AccountLinkStatus.sameAccount) {
      _clearRestoreOffer();
      _uid = user.uid;
      _pending = null;
      _message = null;
      final entering = _phase != CloudSyncPhase.connected;
      _set(CloudSyncPhase.connected);
      if (entering) {
        _loadLastSync();
        // Session restored (or signed back in) on a bound device. A first
        // connection that just finished sets the phase itself, so it never
        // gets here and doesn't sync twice.
        requestAutoSync(AutoSyncTrigger.appStart);
      }
      return;
    }
    if (link != AccountLinkStatus.unlinked) {
      _clearRestoreOffer();
      _set(CloudSyncPhase.unavailable);
      return;
    }
    // Keep a pending decision / failure for the same account; anything
    // else (new account, first sign-in) starts from "not connected".
    final keep = user.uid == _uid &&
        (_phase == CloudSyncPhase.needsMergeDecision ||
            _phase == CloudSyncPhase.failed);
    if (!keep) {
      final entering =
          _phase != CloudSyncPhase.notConnected || _uid != user.uid;
      _uid = user.uid;
      _pending = null;
      _message = null;
      if (entering) _clearRestoreOffer();
      _set(CloudSyncPhase.notConnected);
      if (entering) _lookForRestorableBackup(user.uid, prompt: interactive);
    }
  }

  /// Read-only: asks the initial-sync engine whether this song-less,
  /// unbound device could restore a cloud backup ([InitialSyncEngine
  /// .findRestorableBackup]). Never writes anything; failures (offline,
  /// ...) just mean no offer — "클라우드 백업 설정" stays available.
  void _lookForRestorableBackup(String uid, {required bool prompt}) {
    if (!_findRestorableBackup || _suspended) return;
    final token = ++_findToken;
    _findingBackup = true;
    notifyListeners();
    _finding = () async {
      SyncDataSummary? found;
      try {
        found = await _engine.findRestorableBackup(uid);
      } catch (e) {
        debugPrint('[sync] backup lookup failed: $e');
      }
      if (token != _findToken) return; // superseded or cleared
      _findingBackup = false;
      if (found != null &&
          (found.songs > 0 || found.folders > 0) &&
          _phase == CloudSyncPhase.notConnected &&
          _uid == uid &&
          _account.user?.uid == uid) {
        _restoreOffer = CloudRestoreOffer(uid: uid, cloud: found);
        _restorePromptPending = prompt;
      }
      notifyListeners();
    }();
  }

  /// Forgets the restore offer and cancels a running lookup's result.
  void _clearRestoreOffer() {
    _findToken++;
    _findingBackup = false;
    _restoreOffer = null;
    _restorePromptPending = false;
  }

  /// "클라우드 백업 설정" / "다시 시도". Ignored while a run is going.
  Future<void> startSetup() async {
    final user = _account.user;
    if (_busy || _suspended || user == null) return;
    if (_account.phase != AccountPhase.signedIn ||
        _account.linkStatus != AccountLinkStatus.unlinked) {
      return;
    }
    _busy = true;
    _uid = user.uid;
    _pending = null;
    _message = null;
    _clearRestoreOffer();
    _set(CloudSyncPhase.checking);
    try {
      final a = await _engine.assess(user.uid);
      switch (a.kind) {
        case InitialSyncAssessmentKind.alreadyLinked:
          await _account.refreshLink();
          _set(CloudSyncPhase.connected);
        case InitialSyncAssessmentKind.linkedToOtherAccount:
          _fail('이 기기의 데이터는 다른 Google 계정에 연결되어 있어요.');
        case InitialSyncAssessmentKind.needsMergeDecision:
          _pending = a;
          _set(CloudSyncPhase.needsMergeDecision);
        case InitialSyncAssessmentKind.ready:
          await _run(user, a.mode!);
      }
    } catch (e) {
      _fail(_messageFor(e));
    } finally {
      _setIdle();
      _onAccountChanged();
    }
  }

  /// "합치기". Only valid while a decision is pending.
  Future<void> confirmMerge() async {
    final user = _account.user;
    if (_busy ||
        _suspended ||
        user == null ||
        _phase != CloudSyncPhase.needsMergeDecision) {
      return;
    }
    _busy = true;
    try {
      await _run(user, InitialSyncMode.merge);
    } catch (e) {
      _fail(_messageFor(e));
    } finally {
      _setIdle();
      _onAccountChanged();
    }
  }

  /// "취소": nothing is written anywhere.
  void cancelMerge() {
    if (_busy || _phase != CloudSyncPhase.needsMergeDecision) return;
    _pending = null;
    _set(CloudSyncPhase.notConnected);
  }

  Future<void> _run(AccountUser user, InitialSyncMode mode) async {
    _set(CloudSyncPhase.syncing);
    final result = await _engine.run(user.uid, mode: mode, email: user.email);
    if (result.needsDecision != null) {
      _pending = result.needsDecision;
      _set(CloudSyncPhase.needsMergeDecision);
      return;
    }
    _pending = null;
    _dataVersion++;
    // A new binding starts with a clean sync state: nothing from an
    // earlier account/binding carries over.
    _clearTwoWayStatus();
    await _account.refreshLink();
    _set(CloudSyncPhase.connected);
    await _loadLastSync();
  }

  bool get _canTwoWaySync {
    final user = _account.user;
    return _manual != null &&
        !_suspended &&
        user != null &&
        _phase == CloudSyncPhase.connected &&
        _account.phase == AccountPhase.signedIn &&
        _account.linkStatus == AccountLinkStatus.sameAccount;
  }

  /// "지금 동기화" / "다시 시도". Only while connected. Not limited by the
  /// automatic throttle or backoff; if a sync is already running, it runs
  /// once more right after it.
  Future<void> syncNow() async {
    if (!_canTwoWaySync) return;
    if (_busy) {
      _pendingSync = true;
      return;
    }
    await _runTwoWay(manual: true);
  }

  /// The app returned to the foreground.
  void onAppResumed() => requestAutoSync(AutoSyncTrigger.appResume);

  /// A user write to songs/folders/memberships completed. Syncs after
  /// [AutoSyncConfig.debounce] of quiet; only for a bound device.
  void onLocalDataChanged() {
    // The device has data again: an earlier restore offer no longer
    // describes what "복원하기" would do.
    if (_restoreOffer != null || _findingBackup) {
      _clearRestoreOffer();
      notifyListeners();
    }
    final auto = _auto;
    if (auto == null || !_canTwoWaySync) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(auto.debounce, () {
      _debounceTimer = null;
      requestAutoSync(AutoSyncTrigger.dataChanged);
    });
  }

  /// Asks for an automatic sync. Ignored unless automatic sync is on and
  /// this device is bound to the signed-in account. Never runs two syncs
  /// at once: during a run it only sets a single "run once more" flag.
  void requestAutoSync(AutoSyncTrigger trigger) {
    final auto = _auto;
    if (auto == null || !_canTwoWaySync) return;
    if (_busy) {
      // A start/resume request is already covered by the run in progress;
      // a data change made during it needs one more run afterwards.
      if (trigger == AutoSyncTrigger.dataChanged ||
          trigger == AutoSyncTrigger.followUp) {
        _pendingSync = true;
      }
      return;
    }
    final now = auto.now();
    if (trigger != AutoSyncTrigger.followUp && now < _backoffUntilMs) {
      // Failing recently: wait. A data change is retried once when the
      // backoff ends (it is still dirty locally either way).
      if (trigger == AutoSyncTrigger.dataChanged) {
        _backoffTimer?.cancel();
        _backoffTimer = Timer(
          Duration(milliseconds: _backoffUntilMs - now),
          () {
            _backoffTimer = null;
            requestAutoSync(AutoSyncTrigger.dataChanged);
          },
        );
      }
      return;
    }
    if ((trigger == AutoSyncTrigger.appStart ||
            trigger == AutoSyncTrigger.appResume) &&
        _lastAttemptMs != null &&
        now - _lastAttemptMs! < auto.resumeThrottle.inMilliseconds) {
      return;
    }
    unawaited(_runTwoWay(manual: false));
  }

  Future<void> _runTwoWay({required bool manual}) async {
    final engine = _manual;
    final user = _account.user;
    if (engine == null || user == null) return;
    _busy = true;
    _syncRuns++;
    _statusUid = user.uid;
    _lastAttemptMs = (_auto?.now ?? AutoSyncConfig._utcNowMs)();
    _manualMessage = null;
    _manualStatus = ManualSyncStatus.running;
    notifyListeners();
    var ok = false;
    try {
      final result = await engine.syncNow(user.uid);
      ok = true;
      _consecutiveFailures = 0;
      _backoffUntilMs = 0;
      if (result.localChanges > 0) _dataVersion++;
      _lastSyncAtMs = await engine.lastSuccessfulSyncAtMs();
      // Automatic successes stay quiet: only the last sync time changes.
      _manualStatus =
          manual ? ManualSyncStatus.succeeded : ManualSyncStatus.idle;
    } catch (e) {
      _consecutiveFailures++;
      final auto = _auto;
      if (auto != null) {
        final factor = 1 << (_consecutiveFailures - 1).clamp(0, 16);
        final wait = auto.backoffBase * factor;
        _backoffUntilMs = auto.now() +
            (wait > auto.backoffMax ? auto.backoffMax : wait).inMilliseconds;
      }
      _manualStatus = ManualSyncStatus.failed;
      _manualMessage = switch (e) {
        ManualSyncFailure(kind: ManualSyncFailureKind.accountMismatch) =>
          '이 기기는 다른 계정에 연결되어 있어 동기화할 수 없어요.',
        ManualSyncFailure(
          kind: ManualSyncFailureKind.accountDeletionPending,
        ) =>
          '계정 삭제가 끝나지 않아 동기화할 수 없어요.',
        _ => '동기화하지 못했어요. 이 기기의 데이터는 그대로예요.',
      };
    } finally {
      _setIdle();
      // The account changed while this run was in flight: its result
      // belongs to the old account and must not be shown.
      if (_account.user?.uid != user.uid) _clearTwoWayStatus();
      notifyListeners();
    }
    // Requests that arrived during the run: one more run, only after a
    // success (after a failure, the next trigger or "지금 동기화" retries).
    final followUp = _pendingSync;
    _pendingSync = false;
    if (followUp && ok && _canTwoWaySync) {
      if (_auto != null) {
        requestAutoSync(AutoSyncTrigger.followUp);
      } else {
        unawaited(_runTwoWay(manual: true));
      }
    }
  }

  // --- Phase B-5: account deletion -------------------------------------------

  /// Stops every kind of sync for an account deletion: cancels the
  /// debounce/backoff timers and any queued follow-up, refuses new runs
  /// (automatic, "지금 동기화", first connection), and completes once a run
  /// already in progress has finished, so no cloud write can happen after
  /// this returns.
  Future<void> suspendForAccountDeletion() async {
    _suspended = true;
    _clearRestoreOffer();
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _backoffTimer?.cancel();
    _backoffTimer = null;
    _pendingSync = false;
    notifyListeners();
    if (!_busy) return;
    final idle = Completer<void>();
    _idleWaiters.add(idle);
    await idle.future;
  }

  /// Allows sync again: after a deletion was cancelled before anything was
  /// deleted, or after it finished (the device is then unbound and signed
  /// out, so nothing runs until the user connects again).
  void resumeAfterAccountDeletion() {
    if (!_suspended) return;
    _suspended = false;
    _pendingSync = false;
    _consecutiveFailures = 0;
    _backoffUntilMs = 0;
    _manualStatus = ManualSyncStatus.idle;
    _manualMessage = null;
    _onAccountChanged();
    notifyListeners();
  }

  /// The device's data no longer belongs to any cloud account (account
  /// deleted): forget the shown sync state.
  void resetAfterAccountDeletion() {
    _clearTwoWayStatus();
    _lastSyncAtMs = null;
    _lastAttemptMs = null;
    _uid = null;
    _pending = null;
    _message = null;
    _dataVersion++;
    notifyListeners();
  }

  /// "이 기기의 이전 클라우드 연결 해제" (Phase B-5.1) completed: the old
  /// binding's sync result and backoff are gone with it.
  void onBindingReleased() {
    _clearTwoWayStatus();
    _lastSyncAtMs = null;
    notifyListeners();
  }

  /// Forgets the two-way sync result, failure backoff and queued follow-up
  /// of the current/previous account. Not a way to hide errors: only called
  /// when that account/binding is no longer the one in use.
  void _clearTwoWayStatus() {
    _manualStatus = ManualSyncStatus.idle;
    _manualMessage = null;
    _consecutiveFailures = 0;
    _backoffUntilMs = 0;
    _backoffTimer?.cancel();
    _backoffTimer = null;
    _pendingSync = false;
    _lastAttemptMs = null;
    _statusUid = null;
  }

  void _setIdle() {
    _busy = false;
    final waiters = List.of(_idleWaiters);
    _idleWaiters.clear();
    for (final w in waiters) {
      if (!w.isCompleted) w.complete();
    }
  }

  Future<void> _loadLastSync() async {
    final manual = _manual;
    if (manual == null) return;
    try {
      _lastSyncAtMs = await manual.lastSuccessfulSyncAtMs();
      notifyListeners();
    } catch (_) {
      // Display only.
    }
  }

  /// Simulates a sync that changed local data (screen-refresh tests).
  @visibleForTesting
  void debugMarkDataChanged() {
    _dataVersion++;
    notifyListeners();
  }

  void _fail(String message) {
    _message = message;
    _set(CloudSyncPhase.failed);
  }

  static String _messageFor(Object e) {
    const keep = ' 이 기기의 노래와 폴더는 그대로예요.';
    if (e is InitialSyncFailure) {
      switch (e.kind) {
        case InitialSyncFailureKind.backup:
          return '안전 백업을 만들지 못해 클라우드 연결을 시작하지 않았어요.$keep';
        case InitialSyncFailureKind.network:
          return '네트워크 연결을 확인한 뒤 다시 시도해 주세요.$keep';
        case InitialSyncFailureKind.permissionDenied:
          return '클라우드 접근이 거부됐어요. 다시 로그인한 뒤 시도해 주세요.$keep';
        case InitialSyncFailureKind.other:
          break;
      }
    }
    return '클라우드 연결에 실패했어요. 잠시 후 다시 시도해 주세요.$keep';
  }

  void _set(CloudSyncPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _backoffTimer?.cancel();
    _setIdle();
    _account.removeListener(_onAccountChanged);
    super.dispose();
  }
}
