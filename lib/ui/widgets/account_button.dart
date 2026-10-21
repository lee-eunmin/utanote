import 'package:flutter/material.dart';

import '../../account/account_controller.dart';
import '../../sync/cloud_sync_controller.dart';
import '../../sync/sync_records.dart';
import '../../theme/app_theme.dart';
import 'app_header.dart';

/// Header entry for the Google account sheet. Takes no space when there is
/// no account support (Web, tests) or sign-in is unavailable/starting.
class AccountButton extends StatelessWidget {
  final AccountController? account;

  /// Called after the sheet closes (a restore/merge may have changed the
  /// local songs and folders).
  final VoidCallback? onSheetClosed;

  const AccountButton({super.key, required this.account, this.onSheetClosed});

  @override
  Widget build(BuildContext context) {
    final account = this.account;
    if (account == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: account,
      builder: (context, _) {
        if (account.phase == AccountPhase.initializing ||
            account.phase == AccountPhase.unavailable) {
          return const SizedBox.shrink();
        }
        final signedIn = account.phase == AccountPhase.signedIn;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Tooltip(
            message: '계정',
            child: HeaderIconButton(
              key: const Key('accountButton'),
              icon: signedIn
                  ? Icons.account_circle_rounded
                  : Icons.account_circle_outlined,
              onPressed: () async {
                await showAccountSheet(context, account);
                onSheetClosed?.call();
              },
            ),
          ),
        );
      },
    );
  }
}

Future<void> showAccountSheet(BuildContext context, AccountController account) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) => AccountSheet(account: account),
  );
}

class AccountSheet extends StatelessWidget {
  final AccountController account;

  const AccountSheet({super.key, required this.account});

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
        child: ListenableBuilder(
          listenable: Listenable.merge([account, ?account.cloudSync]),
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
                child: Text('계정', style: AppTextStyles.sheetTitle),
              ),
              const SizedBox(height: 14),
              ..._body(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _body() {
    final message = account.message;
    final notice = message == null
        ? null
        : Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text(
              message,
              key: const Key('accountMessage'),
              style: const TextStyle(fontSize: 13, color: AppColors.danger),
            ),
          );

    switch (account.phase) {
      case AccountPhase.initializing:
      case AccountPhase.unavailable:
        return [
          const _Note('지금은 로그인을 사용할 수 없어요.'),
        ];
      case AccountPhase.signedOut:
      case AccountPhase.signingIn:
        final busy = account.phase == AccountPhase.signingIn;
        return [
          ?notice,
          const _Note(
            'Google 계정으로 로그인할 수 있어요. 클라우드 백업은 준비 중이며, '
            '이 기기의 노래와 폴더는 그대로 유지됩니다.',
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const Key('googleSignInButton'),
              onPressed: busy ? null : account.signIn,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login_rounded, size: 18),
              label: Text(busy ? '로그인 중…' : 'Google로 로그인'),
            ),
          ),
        ];
      case AccountPhase.signedIn:
        final user = account.user;
        return [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              user?.email ?? '(이메일 없음)',
              key: const Key('accountEmail'),
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'UID ${user?.uid ?? '-'}',
              key: const Key('accountUid'),
              style: AppTextStyles.meta,
            ),
          ),
          const SizedBox(height: 12),
          if (account.cloudSync case final cloud?) ...[
            _CloudBackupSection(cloud: cloud),
            const SizedBox(height: 12),
            const _Note('로그아웃해도 이 기기의 노래와 폴더는 삭제되지 않습니다.'),
          ] else
            const _Note(
              '클라우드 백업은 준비 중이에요. 로그아웃해도 이 기기의 노래와 폴더는 '
              '삭제되지 않습니다.',
            ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              key: const Key('signOutButton'),
              onPressed: account.signOut,
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('로그아웃'),
            ),
          ),
        ];
    }
  }
}

class _Note extends StatelessWidget {
  final String text;

  const _Note(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          height: 1.45,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

/// First cloud connection (Phase B-3). Runs only when the user taps it.
class _CloudBackupSection extends StatelessWidget {
  final CloudSyncController cloud;

  const _CloudBackupSection({required this.cloud});

  @override
  Widget build(BuildContext context) {
    switch (cloud.phase) {
      case CloudSyncPhase.unavailable:
        return const SizedBox.shrink();
      case CloudSyncPhase.notConnected:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Note('이 기기의 노래와 폴더를 Google 계정에 백업할 수 있어요.'),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const Key('cloudSetupButton'),
              onPressed: cloud.busy ? null : cloud.startSetup,
              icon: const Icon(Icons.cloud_upload_outlined, size: 18),
              label: const Text('클라우드 백업 설정'),
            ),
          ],
        );
      case CloudSyncPhase.checking:
      case CloudSyncPhase.syncing:
        return Row(
          key: const Key('cloudSyncProgress'),
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Note(
                cloud.phase == CloudSyncPhase.checking
                    ? '이 기기와 클라우드의 데이터를 확인하는 중…'
                    : '클라우드에 연결하는 중… 앱을 닫지 말아 주세요.',
              ),
            ),
          ],
        );
      case CloudSyncPhase.needsMergeDecision:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Note(
              '이 기기(${_summary(cloud.localSummary)})와 '
              '클라우드(${_summary(cloud.cloudSummary)})에 모두 데이터가 있어요. '
              '합치면 양쪽의 노래와 폴더가 모두 남아요. 같은 항목은 더 최근에 바뀐 '
              '쪽으로 맞춰지고, 한쪽에서 삭제한 항목은 양쪽에서 삭제돼요.',
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    key: const Key('cloudMergeCancel'),
                    onPressed: cloud.busy ? null : cloud.cancelMerge,
                    child: const Text('취소'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    key: const Key('cloudMergeConfirm'),
                    onPressed: cloud.busy ? null : cloud.confirmMerge,
                    child: const Text('합치기'),
                  ),
                ),
              ],
            ),
          ],
        );
      case CloudSyncPhase.connected:
        const connected = Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            key: Key('cloudConnected'),
            children: [
              Icon(
                Icons.cloud_done_rounded,
                size: 18,
                color: AppColors.textSecondary,
              ),
              SizedBox(width: 8),
              Text(
                '백업 연결됨',
                style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
              ),
            ],
          ),
        );
        if (!cloud.canSyncNow) return connected;
        final running = cloud.manualStatus == ManualSyncStatus.running;
        final last = cloud.lastSyncAtMs;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            connected,
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                last == null
                    ? '아직 동기화한 적이 없어요.'
                    : '마지막 동기화: ${formatSyncTime(last)}',
                key: const Key('cloudLastSync'),
                style: AppTextStyles.meta,
              ),
            ),
            if (cloud.manualStatus == ManualSyncStatus.succeeded)
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 6, 4, 0),
                child: Text(
                  '동기화 완료',
                  key: Key('cloudSyncDone'),
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
              ),
            if (cloud.manualStatus == ManualSyncStatus.failed)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
                child: Text(
                  cloud.manualMessage ?? '동기화하지 못했어요. 이 기기의 데이터는 그대로예요.',
                  key: const Key('cloudSyncFailed'),
                  style: const TextStyle(fontSize: 13, color: AppColors.danger),
                ),
              ),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const Key('cloudSyncNowButton'),
              onPressed: cloud.busy ? null : cloud.syncNow,
              icon: running
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded, size: 18),
              label: Text(
                running
                    ? '동기화하는 중…'
                    : cloud.manualStatus == ManualSyncStatus.failed
                        ? '다시 시도'
                        : '지금 동기화',
              ),
            ),
          ],
        );
      case CloudSyncPhase.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                cloud.message ?? '클라우드 연결에 실패했어요.',
                key: const Key('cloudSyncMessage'),
                style: const TextStyle(fontSize: 13, color: AppColors.danger),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const Key('cloudRetryButton'),
              onPressed: cloud.busy ? null : cloud.startSetup,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('다시 시도'),
            ),
          ],
        );
    }
  }

  static String _summary(SyncDataSummary? s) =>
      s == null ? '-' : '노래 ${s.songs}곡 · 폴더 ${s.folders}개';
}

/// Local-time display of a UTC epoch-ms sync time, e.g. "10월 22일 15:04".
String formatSyncTime(int utcMs) {
  final t = DateTime.fromMillisecondsSinceEpoch(utcMs, isUtc: true).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.month}월 ${t.day}일 ${two(t.hour)}:${two(t.minute)}';
}
