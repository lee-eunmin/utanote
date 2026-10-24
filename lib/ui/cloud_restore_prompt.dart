import 'dart:async';

import 'package:flutter/material.dart';

import '../account/account_controller.dart';
import '../sync/cloud_sync_controller.dart';
import '../sync/sync_records.dart';
import '../theme/app_theme.dart';

/// Shows "클라우드 백업을 찾았어요" once when, right after the user signed in,
/// [CloudSyncController] found a backup this song-less, unbound device can
/// restore. "복원하기" starts the normal first connection
/// ([CloudSyncController.startSetup]); "나중에" only closes the dialog (the
/// account sheet and the empty song list keep offering the restore).
class CloudRestorePromptGate extends StatefulWidget {
  final AccountController? account;
  final Widget child;

  const CloudRestorePromptGate({
    super.key,
    required this.account,
    required this.child,
  });

  @override
  State<CloudRestorePromptGate> createState() => _CloudRestorePromptGateState();
}

class _CloudRestorePromptGateState extends State<CloudRestorePromptGate> {
  CloudSyncController? _cloud;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(CloudRestorePromptGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account?.cloudSync != widget.account?.cloudSync) {
      _cloud?.removeListener(_onChanged);
      _attach();
    }
  }

  @override
  void dispose() {
    _cloud?.removeListener(_onChanged);
    super.dispose();
  }

  void _attach() {
    _cloud = widget.account?.cloudSync;
    _cloud?.addListener(_onChanged);
    _onChanged();
  }

  void _onChanged() {
    final cloud = _cloud;
    if (cloud == null || _showing || !mounted) return;
    final offer = cloud.takeRestorePrompt();
    if (offer == null) return;
    _showing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _show(cloud, offer));
  }

  Future<void> _show(CloudSyncController cloud, CloudRestoreOffer offer) async {
    if (!mounted) {
      _showing = false;
      return;
    }
    final restore = await showDialog<bool>(
      context: context,
      builder: (_) => CloudRestoreDialog(summary: offer.cloud),
    );
    _showing = false;
    // Only for the account the backup was found for, and only if it is
    // still on offer (not signed out, bound or changed meanwhile).
    if (restore == true && cloud.restoreOffer?.uid == offer.uid) {
      unawaited(cloud.startSetup());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// "클라우드 백업을 찾았어요" — pops `true` for 복원하기, `false` for 나중에.
class CloudRestoreDialog extends StatelessWidget {
  final SyncDataSummary summary;

  const CloudRestoreDialog({super.key, required this.summary});

  @override
  Widget build(BuildContext context) {
    const countStyle = TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w700,
      color: AppColors.textPrimary,
    );
    return AlertDialog(
      key: const Key('cloudRestoreDialog'),
      backgroundColor: AppColors.surfaceHigh,
      title: const Text('클라우드 백업을 찾았어요', style: AppTextStyles.sheetTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '이 계정에 저장된 UtaNote 노래장이 있어요.\n이 기기로 복원할까요?',
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.surfacePressed,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '노래 ${summary.songs}곡',
                    key: const Key('cloudRestoreSongCount'),
                    style: countStyle,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '폴더 ${summary.folders}개',
                    key: const Key('cloudRestoreFolderCount'),
                    style: countStyle,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('cloudRestoreLater'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('나중에'),
        ),
        FilledButton(
          key: const Key('cloudRestoreConfirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('복원하기'),
        ),
      ],
    );
  }
}
