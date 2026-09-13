import 'package:flutter/material.dart';

import '../../models/folder.dart';
import '../../models/song_options.dart';
import 'choice_chip_row.dart';

/// Small dialogs shared by the song list and folder detail screens for bulk
/// (multi-select) actions.
Future<int?> pickFolderDialog(BuildContext context, List<Folder> folders) {
  return showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('폴더에 추가'),
      children: [
        if (folders.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text('폴더가 없습니다. 먼저 폴더를 만들어주세요.'),
          ),
        for (final folder in folders)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(folder.id),
            child: Text(folder.name),
          ),
      ],
    ),
  );
}

Future<String?> pickStatusDialog(BuildContext context) {
  String? selected = kPracticeStatuses.first;
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('상태 변경'),
        content: ChoiceChipRow<String>(
          options: kPracticeStatuses,
          value: selected,
          labelBuilder: (s) => s,
          onChanged: (s) => setState(() => selected = s),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(selected),
            child: const Text('적용'),
          ),
        ],
      ),
    ),
  );
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('확인'),
        ),
      ],
    ),
  );
  return result ?? false;
}
