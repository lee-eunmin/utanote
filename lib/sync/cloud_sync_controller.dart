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

  CloudSyncController({
    required this._engine,
    required this._account,
    this._manual,
    AutoSyncConfig? autoSync,
  }) : _auto = autoSync {
    _account.addListener(_onAccountChanged);
    _onAccountChanged();
  }

  // --- automatic sync state ---
  Timer? _debounceTimer;
  Timer? _backoffTimer;
  bool _pendingSync = false;
  int? _lastAttemptMs;
  int _consecutiveFailures = 0;
  int _backoffUntilMs = 0;
  int _syncRuns = 0;

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

  /// Bumped whenever local songs/folders may have changed (restore/merge),
  /// so screens know to reload.
  int get dataVersion => _dataVersion;

  bool get canSyncNow => _manual != null;
  ManualSyncStatus get manualStatus => _manualStatus;

  /// User-facing notice for [ManualSyncStatus.failed].
  String? get manualMessage => _manualMessage;

  /// UTC epoch ms of the last fully successful sync, if known.
  int? get lastSyncAtMs => _lastSyncAtMs;

  void _onAccountChanged() {
    if (_busy) return; // re-evaluated when the run ends
    final user = _account.user;
    final signedIn = _account.phase == AccountPhase.signedIn && user != null;
    if (!signedIn) {
      _uid = null;
      _pending = null;
      _message = null;
      _set(CloudSyncPhase.unavailable);
      return;
    }
    final link = _account.linkStatus;
    if (link == AccountLinkStatus.sameAccount) {
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
      _set(CloudSyncPhase.unavailable);
      return;
    }
    // Keep a pending decision / failure for the same account; anything
    // else (new account, first sign-in) starts from "not connected".
    final keep = user.uid == _uid &&
        (_phase == CloudSyncPhase.needsMergeDecision ||
            _phase == CloudSyncPhase.failed);
    if (!keep) {
      _uid = user.uid;
      _pending = null;
      _message = null;
      _set(CloudSyncPhase.notConnected);
    }
  }

  /// "클라우드 백업 설정" / "다시 시도". Ignored while a run is going.
  Future<void> startSetup() async {
    final user = _account.user;
    if (_busy || user == null) return;
    if (_account.phase != AccountPhase.signedIn ||
        _account.linkStatus != AccountLinkStatus.unlinked) {
      return;
    }
    _busy = true;
    _uid = user.uid;
    _pending = null;
    _message = null;
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
      _busy = false;
      _onAccountChanged();
    }
  }

  /// "합치기". Only valid while a decision is pending.
  Future<void> confirmMerge() async {
    final user = _account.user;
    if (_busy || user == null || _phase != CloudSyncPhase.needsMergeDecision) {
      return;
    }
    _busy = true;
    try {
      await _run(user, InitialSyncMode.merge);
    } catch (e) {
      _fail(_messageFor(e));
    } finally {
      _busy = false;
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
    await _account.refreshLink();
    _set(CloudSyncPhase.connected);
    await _loadLastSync();
  }

  bool get _canTwoWaySync {
    final user = _account.user;
    return _manual != null &&
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
      _manualMessage = e is ManualSyncFailure &&
              e.kind == ManualSyncFailureKind.accountMismatch
          ? '이 기기는 다른 계정에 연결되어 있어 동기화할 수 없어요.'
          : '동기화하지 못했어요. 이 기기의 데이터는 그대로예요.';
    } finally {
      _busy = false;
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
    _account.removeListener(_onAccountChanged);
    super.dispose();
  }
}
