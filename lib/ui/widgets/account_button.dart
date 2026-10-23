import 'package:flutter/material.dart';

import '../../account/account_controller.dart';
import '../../account/account_deletion.dart';
import '../../account/auth_gateway.dart';
import '../../config/account_links.dart';
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
          listenable: Listenable.merge([
            account,
            ?account.cloudSync,
            ?account.deletion,
          ]),
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
        final deletion = account.deletion;
        return [
          ?notice,
          if (deletion != null && deletion.completedThisLaunch)
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(
                '계정과 클라우드 백업을 삭제했어요. 이 기기의 노래와 폴더는 그대로예요. '
                '원하면 다시 Google 계정을 연결해 새 백업을 만들 수 있어요.',
                key: Key('accountDeletedNotice'),
                style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
              ),
            )
          else if (deletion?.pending != null)
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(
                '계정 삭제가 끝나지 않았어요. 삭제하던 Google 계정으로 다시 로그인한 뒤 '
                '"계정 삭제 계속하기"를 눌러 주세요. 그때까지 동기화는 멈춰 있어요.',
                key: Key('accountDeletionPendingNotice'),
                style: TextStyle(fontSize: 13, color: AppColors.danger),
              ),
            ),
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
          if (account.linkStatus ==
              AccountLinkStatus.previousAccountSameEmail) ...[
            ?notice,
            _PreviousBindingSection(account: account),
            const SizedBox(height: 12),
            const _Note('로그아웃해도 이 기기의 노래와 폴더는 삭제되지 않습니다.'),
          ] else if (account.cloudSync case final cloud?) ...[
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
              onPressed: (account.deletion?.busy ?? false)
                  ? null
                  : account.signOut,
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('로그아웃'),
            ),
          ),
          if (account.deletion case final deletion?
              when account.linkStatus !=
                  AccountLinkStatus.previousAccountSameEmail) ...[
            const SizedBox(height: 8),
            const Divider(color: AppColors.hairline, height: 1),
            const SizedBox(height: 8),
            _AccountDeletionSection(account: account, deletion: deletion),
          ],
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
              onPressed: cloud.busy || cloud.suspended
                  ? null
                  : cloud.startSetup,
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
              onPressed: cloud.busy || cloud.suspended ? null : cloud.syncNow,
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
              onPressed: cloud.busy || cloud.suspended
                  ? null
                  : cloud.startSetup,
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

/// Signed in with the same Google email as the device's earlier cloud
/// account, but a new uid (Phase B-5.1). Nothing syncs; the user may
/// explicitly release the old binding on this device.
class _PreviousBindingSection extends StatelessWidget {
  final AccountController account;

  const _PreviousBindingSection({required this.account});

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('previousBindingSection'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '이 기기는 이전 UtaNote 클라우드 계정에 연결되어 있어요. 같은 Google '
            '계정으로 새 클라우드 백업을 다시 설정할 수 있어요. 그때까지 동기화는 '
            '하지 않아요.',
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          key: const Key('releasePreviousBindingButton'),
          onPressed: () async {
            final ok = await confirmReleasePreviousBinding(context);
            if (ok == true) await account.releasePreviousCloudBinding();
          },
          icon: const Icon(Icons.link_off_rounded, size: 18),
          label: const Text('이 기기의 이전 클라우드 연결 해제'),
        ),
      ],
    );
  }
}

/// True only when the user chose to release the old binding.
Future<bool?> confirmReleasePreviousBinding(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('releasePreviousBindingDialog'),
      backgroundColor: AppColors.surfaceHigh,
      title: const Text(
        '이 기기는 이전 UtaNote 클라우드 계정에 연결되어 있어요.',
        style: AppTextStyles.sheetTitle,
      ),
      content: const Text(
        '같은 Google 계정으로 새 클라우드 백업을 다시 설정하시겠어요?\n\n'
        '연결을 해제해도 이 기기의 노래와 폴더는 삭제되지 않아요. 해제한 뒤 '
        '"클라우드 백업 설정"을 누르면 새 백업을 만들 수 있어요.',
        style: TextStyle(
          fontSize: 14,
          height: 1.45,
          color: AppColors.textPrimary,
        ),
      ),
      actions: [
        TextButton(
          key: const Key('releasePreviousBindingCancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const Key('releasePreviousBindingConfirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('이 기기의 이전 클라우드 연결 해제'),
        ),
      ],
    ),
  );
}

/// "계정 및 클라우드 데이터 삭제" (Phase B-5): entry, progress, failure and
/// resume. The deletion itself runs in [AccountDeletionController], so it
/// keeps going if the sheet is closed.
class _AccountDeletionSection extends StatelessWidget {
  final AccountController account;
  final AccountDeletionController deletion;

  const _AccountDeletionSection({
    required this.account,
    required this.deletion,
  });

  @override
  Widget build(BuildContext context) {
    if (deletion.busy) {
      final text = switch (deletion.status) {
        AccountDeletionStatus.reauthenticating => '본인 확인 중…',
        AccountDeletionStatus.blockingCloud => '삭제를 준비하는 중…',
        AccountDeletionStatus.deletingCloud =>
          '클라우드 백업 삭제 중… (${deletion.deletedThisRun}개) 앱을 닫지 말아 주세요.',
        AccountDeletionStatus.deletingAccount => '계정 삭제 중…',
        _ => '마무리하는 중…',
      };
      return Row(
        key: const Key('accountDeletionProgress'),
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(child: _Note(text)),
        ],
      );
    }

    final message = deletion.message;
    final pending = deletion.pending;
    final resumable = pending != null && pending.uid == account.user?.uid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              message,
              key: const Key('accountDeletionMessage'),
              style: const TextStyle(fontSize: 13, color: AppColors.danger),
            ),
          )
        else if (resumable)
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              '계정 삭제가 끝나지 않았어요. 계속하면 남은 클라우드 백업과 계정을 '
              '삭제해요. 그때까지 동기화는 멈춰 있어요.',
              key: Key('accountDeletionPendingNotice'),
              style: TextStyle(fontSize: 13, color: AppColors.danger),
            ),
          ),
        TextButton.icon(
          key: Key(
            resumable ? 'accountDeletionResumeButton' : 'accountDeleteButton',
          ),
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          onPressed: () async {
            if (resumable) {
              // Already confirmed when it started; only the rest is left.
              await deletion.deleteAccount();
              return;
            }
            final ok = await confirmAccountDeletion(context);
            if (ok == true) await deletion.deleteAccount();
          },
          icon: const Icon(Icons.delete_forever_rounded, size: 18),
          label: Text(resumable ? '계정 삭제 계속하기' : '계정 및 클라우드 데이터 삭제'),
        ),
      ],
    );
  }
}

/// "계정과 클라우드 백업을 삭제할까요?" — true only for the delete button.
Future<bool?> confirmAccountDeletion(BuildContext context) {
  const points = [
    'UtaNote에 연결된 Google 로그인 계정 정보가 삭제돼요.',
    '클라우드에 백업된 노래와 폴더 데이터가 삭제돼요.',
    '이 기기에 저장된 노래와 폴더는 그대로 유지돼요.',
    '삭제된 클라우드 백업은 복구할 수 없어요.',
    '나중에 원하면 다시 Google 계정을 연결해서 새 백업을 만들 수 있어요.',
  ];
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('accountDeleteDialog'),
      backgroundColor: AppColors.surfaceHigh,
      title: const Text('계정과 클라우드 백업을 삭제할까요?', style: AppTextStyles.sheetTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final p in points)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '•  ',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        p,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.45,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            const Text(
              '계속하면 본인 확인을 위해 Google 계정을 한 번 더 선택해요.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            if (kAccountDeletionRequestUrl case final url?) ...[
              const SizedBox(height: 8),
              SelectableText(
                '앱 밖에서 삭제 요청: $url',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('accountDeleteCancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const Key('accountDeleteConfirm'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.danger,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('계정 및 백업 삭제'),
        ),
      ],
    ),
  );
}

/// Local-time display of a UTC epoch-ms sync time, e.g. "10월 22일 15:04".
String formatSyncTime(int utcMs) {
  final t = DateTime.fromMillisecondsSinceEpoch(utcMs, isUtc: true).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.month}월 ${t.day}일 ${two(t.hour)}:${two(t.minute)}';
}
