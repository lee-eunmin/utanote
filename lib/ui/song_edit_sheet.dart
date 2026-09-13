import 'package:flutter/material.dart';

import '../models/song.dart';
import '../models/song_options.dart';
import '../storage/local_storage.dart';
import '../theme/app_theme.dart';
import 'widgets/choice_chip_row.dart';

/// Width at or above which the add/edit form shows as a centered dialog
/// instead of a mobile-style bottom sheet.
const double _wideLayoutBreakpoint = 720;

/// Opens the song add/edit form.
///
/// On narrow (mobile) viewports this is the polished modal bottom sheet.
/// On wide (web/desktop) viewports it's shown as a centered modal dialog
/// with a sensible max width/height instead, since a full-height bottom
/// sheet reads as a mobile pattern there.
///
/// Karaoke-company (TJ/KY) selection is intentionally not exposed here:
/// new songs always default to 'TJ', while an existing song (which may be
/// legacy 'KY' data) keeps its original [Song.karaokeType] untouched. The
/// legacy [Song.memo] field is never read or written by this form either.
Future<void> showSongEditSheet({
  required BuildContext context,
  required LocalStorage storage,
  Song? existing,
}) {
  final isWide = MediaQuery.sizeOf(context).width >= _wideLayoutBreakpoint;
  if (isWide) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
          child: _SongEditSheet(
            storage: storage,
            existing: existing,
            isDialog: true,
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => _SongEditSheet(storage: storage, existing: existing),
  );
}

class _SongEditSheet extends StatefulWidget {
  final LocalStorage storage;
  final Song? existing;
  final bool isDialog;

  const _SongEditSheet({
    required this.storage,
    this.existing,
    this.isDialog = false,
  });

  @override
  State<_SongEditSheet> createState() => _SongEditSheetState();
}

class _SongEditSheetState extends State<_SongEditSheet> {
  late final TextEditingController _numberController;
  late final TextEditingController _titleController;
  late final TextEditingController _artistController;
  final _aliasInputController = TextEditingController();

  late List<String> _aliases;
  late String _keyType;
  late int _keyOffset;
  late String _difficulty;
  late String _practiceStatus;
  bool _addingAlias = false;
  bool _saving = false;

  Song? get _existing => widget.existing;

  @override
  void initState() {
    super.initState();
    final existing = _existing;
    _numberController = TextEditingController(text: existing?.songNumber ?? '');
    _titleController = TextEditingController(text: existing?.title ?? '');
    _artistController = TextEditingController(text: existing?.artist ?? '');
    _aliases = List.of(existing?.searchAliases ?? const []);
    _keyType = existing?.keyType ?? kKeyTypes.first;
    _keyOffset = existing?.keyOffset ?? 0;
    _difficulty = existing?.difficulty ?? '보통';
    _practiceStatus = existing?.practiceStatus ?? kPracticeStatuses.first;
  }

  @override
  void dispose() {
    _numberController.dispose();
    _titleController.dispose();
    _artistController.dispose();
    _aliasInputController.dispose();
    super.dispose();
  }

  void _commitAlias(String value) {
    final v = value.trim();
    setState(() {
      if (v.isNotEmpty && !_aliases.contains(v)) {
        _aliases.add(v);
      }
      _aliasInputController.clear();
      _addingAlias = false;
    });
  }

  Future<void> _save() async {
    final number = _numberController.text.trim();
    final title = _titleController.text.trim();
    if (number.isEmpty || title.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('번호와 제목을 입력해주세요.')));
      return;
    }
    setState(() => _saving = true);
    final now = DateTime.now();
    final base =
        _existing ??
        Song(
          karaokeType: 'TJ',
          songNumber: '',
          title: '',
          createdAt: now,
          updatedAt: now,
        );
    final song = base.copyWith(
      songNumber: number,
      title: title,
      artist: _artistController.text.trim().isEmpty
          ? null
          : _artistController.text.trim(),
      keyType: _keyType,
      keyOffset: _keyOffset,
      difficulty: _difficulty,
      practiceStatus: _practiceStatus,
      searchAliases: _aliases,
      updatedAt: now,
    );
    if (_existing == null) {
      await widget.storage.songs.create(song);
    } else {
      await widget.storage.songs.update(song);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isDialog) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: _formFields(context),
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Container(
          decoration: const BoxDecoration(
            color: AppColors.surfaceHigh,
            borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: AppColors.hairline,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                ..._formFields(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _formFields(BuildContext context) {
    final isEditing = _existing != null;
    return [
      Row(
        children: [
          Text(isEditing ? '노래 수정' : '노래 추가', style: AppTextStyles.sheetTitle),
          const Spacer(),
          InkResponse(
            onTap: () => Navigator.of(context).pop(),
            radius: 20,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(
                Icons.close_rounded,
                size: 20,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _Field(
              label: '번호',
              child: TextField(
                key: const Key('songNumberField'),
                controller: _numberController,
                decoration: const InputDecoration(hintText: '곡 번호'),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: _Field(
              label: '제목',
              child: TextField(
                key: const Key('songTitleField'),
                controller: _titleController,
                decoration: const InputDecoration(hintText: '노래 제목'),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      _Field(
        label: '가수 (선택)',
        child: TextField(
          key: const Key('songArtistField'),
          controller: _artistController,
          decoration: const InputDecoration(hintText: '가수'),
        ),
      ),
      const SizedBox(height: 14),
      _Field(
        label: '검색 별칭',
        child: Wrap(
          spacing: 7,
          runSpacing: 7,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final alias in _aliases)
              _AliasChip(
                label: alias,
                onRemove: () => setState(() => _aliases.remove(alias)),
              ),
            if (_addingAlias)
              SizedBox(
                width: 150,
                height: 30,
                child: TextField(
                  key: const Key('songAliasField'),
                  autofocus: true,
                  controller: _aliasInputController,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '별칭 입력',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    suffixIcon: InkResponse(
                      key: const Key('confirmAliasButton'),
                      onTap: () => _commitAlias(_aliasInputController.text),
                      child: const Icon(Icons.check_rounded, size: 16),
                    ),
                    suffixIconConstraints: const BoxConstraints(minWidth: 32),
                  ),
                  onSubmitted: _commitAlias,
                ),
              )
            else
              _AddAliasChip(onTap: () => setState(() => _addingAlias = true)),
          ],
        ),
      ),
      const SizedBox(height: 14),
      _Field(
        label: '기준키',
        child: ChoiceChipRow<String>(
          options: kKeyTypes,
          value: _keyType,
          labelBuilder: (v) => v,
          onChanged: (v) => setState(() => _keyType = v),
        ),
      ),
      const SizedBox(height: 14),
      _Field(
        label: '키 조정',
        child: ChoiceChipRow<int>(
          options: kKeyOffsets,
          value: _keyOffset,
          labelBuilder: formatKeyOffset,
          onChanged: (v) => setState(() => _keyOffset = v),
        ),
      ),
      const SizedBox(height: 14),
      _Field(
        label: '난이도',
        child: ChoiceChipRow<String>(
          options: kDifficulties,
          value: _difficulty,
          labelBuilder: (v) => v,
          onChanged: (v) => setState(() => _difficulty = v),
        ),
      ),
      const SizedBox(height: 14),
      _Field(
        label: '상태',
        child: ChoiceChipRow<String>(
          options: kPracticeStatuses,
          value: _practiceStatus,
          labelBuilder: (v) => v,
          onChanged: (v) => setState(() => _practiceStatus = v),
        ),
      ),
      const SizedBox(height: 24),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              key: const Key('cancelSongButton'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('취소'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton(
              key: const Key('saveSongButton'),
              onPressed: _saving ? null : _save,
              child: const Text('저장'),
            ),
          ),
        ],
      ),
    ];
  }
}

class _Field extends StatelessWidget {
  final String label;
  final Widget child;

  const _Field({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.label),
        const SizedBox(height: 7),
        child,
      ],
    );
  }
}

/// A lightweight, low-chrome alias chip: hairline border, no filled
/// background — matches the app's flat, editorial aesthetic instead of the
/// default Material [Chip] look.
class _AliasChip extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;

  const _AliasChip({required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4),
      height: 30,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
          ),
          InkResponse(
            onTap: onRemove,
            radius: 14,
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Icon(
                Icons.close_rounded,
                size: 14,
                color: AppColors.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddAliasChip extends StatelessWidget {
  final VoidCallback onTap;

  const _AddAliasChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(7),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: AppColors.hairline,
            style: BorderStyle.solid,
          ),
        ),
        child: const Text(
          '+ 별칭 추가',
          style: TextStyle(
            fontSize: 13,
            color: AppColors.accent,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
