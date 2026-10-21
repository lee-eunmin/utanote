import 'package:flutter/material.dart';

import '../../account/account_controller.dart';
import '../../theme/app_theme.dart';
import 'app_header.dart';

/// Header entry for the Google account sheet. Takes no space when there is
/// no account support (Web, tests) or sign-in is unavailable/starting.
class AccountButton extends StatelessWidget {
  final AccountController? account;

  const AccountButton({super.key, required this.account});

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
              onPressed: () => showAccountSheet(context, account),
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
          listenable: account,
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
