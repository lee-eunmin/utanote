import 'package:flutter/foundation.dart';

import '../account/account_controller.dart';
import '../account/auth_gateway.dart';
import 'initial_sync_engine.dart';
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

/// UI state of the first cloud connection. Only runs when the user asks:
/// no automatic sync of any kind.
class CloudSyncController extends ChangeNotifier {
  final InitialSyncEngine _engine;
  final AccountController _account;

  CloudSyncController({
    required this._engine,
    required this._account,
  }) {
    _account.addListener(_onAccountChanged);
    _onAccountChanged();
  }

  CloudSyncPhase _phase = CloudSyncPhase.unavailable;
  String? _message;
  InitialSyncAssessment? _pending;
  String? _uid;
  bool _busy = false;
  int _dataVersion = 0;

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
      _set(CloudSyncPhase.connected);
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
    _account.removeListener(_onAccountChanged);
    super.dispose();
  }
}
