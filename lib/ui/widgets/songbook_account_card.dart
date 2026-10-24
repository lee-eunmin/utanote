import 'package:flutter/material.dart';

import '../../account/account_controller.dart';
import '../../account/auth_gateway.dart';
import '../../sync/cloud_sync_controller.dart';
import '../../theme/app_theme.dart';
import 'account_button.dart';

/// Account / cloud backup card under an empty song list (no songs at all),
/// so a new or reinstalled device can find its way to sign-in and restore
/// without songs first. Reuses the account sheet's flows; protection states
/// (other account's device, previous binding, unfinished deletion) only
/// point to the account sheet, never offer a shortcut around it. Takes no
/// space without account support (Web, tests) or while sign-in is
/// unavailable/starting.
class SongbookAccountCard extends StatelessWidget {
  final AccountController? account;

  const SongbookAccountCard({super.key, required this.account});

  @override
  Widget build(BuildContext context) {
    final account = this.account;
    if (account == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([
        account,
        ?account.cloudSync,
        ?account.deletion,
      ]),
      builder: (context, _) {
        final content = _content(context, account);
        if (content == null) return const SizedBox.shrink();
        return Container(
          key: const Key('songbookAccountCard'),
          margin: const EdgeInsets.only(top: 8, bottom: 12),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: content,
          ),
        );
      },
    );
  }

  List<Widget>? _content(BuildContext context, AccountController account) {
    final deletion = account.deletion;
    final deletionOpen =
        deletion != null && (deletion.busy || deletion.pending != null);
    switch (account.phase) {
      case AccountPhase.initializing:
      case AccountPhase.unavailable:
        return null;
      case AccountPhase.signedOut:
      case AccountPhase.signingIn:
        if (deletionOpen) {
          return _openSheet(
            context,
            account,
            '계정 삭제가 끝나지 않았어요. 계정 메뉴에서 이어서 진행해 주세요.',
          );
        }
        final busy = account.phase == AccountPhase.signingIn;
        return [
          const _Title('백업한 노래장이 있나요?'),
          const SizedBox(height: 4),
          const _Body(
            'Google 계정을 연결하면 클라우드에 백업한 노래와 폴더를 불러오거나 '
            '새로 백업할 수 있어요.',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('songbookAccountSignIn'),
            onPressed: busy ? null : () => _signIn(context, account),
            icon: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login_rounded, size: 18),
            label: Text(busy ? '로그인 중…' : 'Google 계정 연결'),
          ),
        ];
      case AccountPhase.signedIn:
        final link = account.linkStatus;
        if (link != AccountLinkStatus.unlinked &&
            link != AccountLinkStatus.sameAccount) {
          return _openSheet(
            context,
            account,
            '이 기기의 클라우드 연결을 확인해야 해요. 계정 메뉴에서 확인해 주세요.',
          );
        }
        if (deletionOpen) {
          return _openSheet(
            context,
            account,
            '계정 삭제가 진행 중이거나 끝나지 않았어요. 계정 메뉴에서 확인해 주세요.',
          );
        }
        final cloud = account.cloudSync;
        if (cloud == null || cloud.phase == CloudSyncPhase.unavailable) {
          return null;
        }
        return [
          const _Title('클라우드 백업'),
          const SizedBox(height: 2),
          Text(account.user?.email ?? '', style: AppTextStyles.meta),
          const SizedBox(height: 10),
          if (cloud.phase == CloudSyncPhase.notConnected &&
              cloud.findingBackup &&
              cloud.restoreOffer == null)
            const Row(
              key: Key('songbookAccountFindingBackup'),
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 10),
                Expanded(child: _Body('클라우드 백업을 확인하는 중…')),
              ],
            )
          else
            CloudBackupSection(cloud: cloud),
        ];
    }
  }

  /// Sign-in from the card. A failure / blocked-account notice is shown
  /// here as a snackbar (the account sheet shows its own).
  Future<void> _signIn(BuildContext context, AccountController account) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await account.signIn();
    final message = account.message;
    if (message != null && account.phase != AccountPhase.signedIn) {
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  List<Widget> _openSheet(
    BuildContext context,
    AccountController account,
    String text,
  ) => [
    _Body(text),
    const SizedBox(height: 10),
    OutlinedButton.icon(
      key: const Key('songbookAccountOpenSheet'),
      onPressed: () => showAccountSheet(context, account),
      icon: const Icon(Icons.account_circle_outlined, size: 18),
      label: const Text('계정 열기'),
    ),
  ];
}

class _Title extends StatelessWidget {
  final String text;

  const _Title(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: AppColors.textPrimary,
    ),
  );
}

class _Body extends StatelessWidget {
  final String text;

  const _Body(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 13,
      height: 1.45,
      color: AppColors.textSecondary,
    ),
  );
}
