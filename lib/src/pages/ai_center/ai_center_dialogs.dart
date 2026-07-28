import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/model/ai_xp.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/service/ai_xp_service.dart';
import 'package:jhentai/src/setting/ai_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';
import 'package:jhentai/src/utils/snack_util.dart';

/// Stable max content height for preview dialogs; shrinks on short screens.
double _previewDialogContentHeight(BuildContext context) {
  final double viewHeight = MediaQuery.sizeOf(context).height;
  return math.min(420.0, viewHeight * 0.55);
}

/// Edits remote AI endpoint settings. Never logs secrets.
class AiSettingsDialog extends StatefulWidget {
  const AiSettingsDialog({super.key});

  @override
  State<AiSettingsDialog> createState() => _AiSettingsDialogState();
}

class _AiSettingsDialogState extends State<AiSettingsDialog> {
  late bool _enabled;
  late final TextEditingController _endpointController;
  late final TextEditingController _modelController;
  late final TextEditingController _apiKeyController;
  bool _obscureApiKey = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _enabled = aiSetting.enabled.value;
    _endpointController = TextEditingController(text: aiSetting.endpoint.value);
    _modelController = TextEditingController(text: aiSetting.model.value);
    _apiKeyController = TextEditingController(text: aiSetting.apiKey.value);
  }

  @override
  void dispose() {
    _endpointController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _onSave() async {
    if (_saving) {
      return;
    }
    setStateSafely(() => _saving = true);
    try {
      // aiSetting.saveConfig intentionally omits apiKey from log output.
      // Do not log or surface the API key on failure either.
      await aiSetting.saveConfig(
        enabled: _enabled,
        endpoint: _endpointController.text,
        model: _modelController.text,
        apiKey: _apiKeyController.text,
      );
      backRoute(result: true);
    } catch (_) {
      // Keep dialog open; never include apiKey in feedback.
      snack('aiSettings'.tr, 'aiOperationFailed'.tr, isShort: true);
    } finally {
      if (mounted) {
        setStateSafely(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('aiSettings'.tr),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('enableRemoteAi'.tr),
                value: _enabled,
                onChanged: (bool value) => setStateSafely(() => _enabled = value),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _endpointController,
                decoration: InputDecoration(
                  labelText: 'aiEndpoint'.tr,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _modelController,
                decoration: InputDecoration(
                  labelText: 'aiModel'.tr,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKeyController,
                obscureText: _obscureApiKey,
                decoration: InputDecoration(
                  labelText: 'aiApiKey'.tr,
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: IconButton(
                    icon: Icon(_obscureApiKey ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setStateSafely(() => _obscureApiKey = !_obscureApiKey),
                  ),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _onSave(),
              ),
              const SizedBox(height: 12),
              Text(
                'remoteAiDataNotice'.tr,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : backRoute, child: Text('cancel'.tr)),
        TextButton(
          onPressed: _saving ? null : _onSave,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('OK'.tr),
        ),
      ],
      actionsPadding: const EdgeInsets.only(left: 24, right: 24, bottom: 12),
    );
  }
}

/// Selectable organization moves. Returns selected moves via [backRoute]; does not mutate.
class AiOrganizationPreviewDialog extends StatefulWidget {
  final AiXpOrganizationPlanResult planResult;
  final Set<int> initiallySelectedGids;
  final String Function(int? index, {String? fallback}) categoryNameResolver;

  const AiOrganizationPreviewDialog({
    super.key,
    required this.planResult,
    required this.initiallySelectedGids,
    required this.categoryNameResolver,
  });

  @override
  State<AiOrganizationPreviewDialog> createState() => _AiOrganizationPreviewDialogState();
}

class _AiOrganizationPreviewDialogState extends State<AiOrganizationPreviewDialog> {
  late final Set<int> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set<int>.from(widget.initiallySelectedGids);
  }

  void _submit() {
    final List<AiXpOrganizationMove> selected = widget.planResult.plan.moves
        .where((AiXpOrganizationMove m) => _selected.contains(m.gid))
        .toList();
    backRoute(result: selected);
  }

  @override
  Widget build(BuildContext context) {
    final List<AiXpOrganizationMove> moves = widget.planResult.plan.moves;
    final Map<int, Gallery> galleries = widget.planResult.galleriesByGid;

    return AlertDialog(
      title: Text('organizationPreviewTitle'.tr),
      content: SizedBox(
        width: 480,
        height: _previewDialogContentHeight(context),
        child: moves.isEmpty
            ? Center(child: Text('noOrganizationChanges'.tr))
            : ListView.separated(
                itemCount: moves.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (BuildContext context, int index) {
                  final AiXpOrganizationMove move = moves[index];
                  final Gallery? gallery = galleries[move.gid];
                  final String title = gallery?.title ?? 'gid:${move.gid}';
                  final String from = widget.categoryNameResolver(
                    move.fromIndex,
                    fallback: gallery?.favoriteTagName,
                  );
                  final String to = move.targetName.isNotEmpty
                      ? move.targetName
                      : widget.categoryNameResolver(move.targetIndex);
                  final String label = 'organizationMoveLabel'.trParams({
                    'title': title,
                    'from': from,
                    'to': to,
                  });

                  return CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _selected.contains(move.gid),
                    onChanged: (bool? value) {
                      setStateSafely(() {
                        if (value == true) {
                          _selected.add(move.gid);
                        } else {
                          _selected.remove(move.gid);
                        }
                      });
                    },
                    title: Text(label, maxLines: 3, overflow: TextOverflow.ellipsis),
                    subtitle: move.matchedTerm.isEmpty
                        ? null
                        : Text(
                            move.matchedTerm,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(onPressed: backRoute, child: Text('cancel'.tr)),
        TextButton(
          onPressed: _selected.isEmpty ? null : _submit,
          child: Text('applySelectedMoves'.tr),
        ),
      ],
      actionsPadding: const EdgeInsets.only(left: 24, right: 24, bottom: 12),
    );
  }
}

/// Grouped duplicate preview. Returns selected groups via [backRoute]; does not mutate.
class AiDuplicatePreviewDialog extends StatefulWidget {
  final AiXpDuplicatePlanResult planResult;
  final Set<int> initiallySelectedKeeperGids;

  const AiDuplicatePreviewDialog({
    super.key,
    required this.planResult,
    required this.initiallySelectedKeeperGids,
  });

  @override
  State<AiDuplicatePreviewDialog> createState() => _AiDuplicatePreviewDialogState();
}

class _AiDuplicatePreviewDialogState extends State<AiDuplicatePreviewDialog> {
  late final Set<int> _selectedKeepers;

  @override
  void initState() {
    super.initState();
    _selectedKeepers = Set<int>.from(widget.initiallySelectedKeeperGids);
  }

  void _submit() {
    final List<AiXpDuplicateGroup> selected = widget.planResult.groups
        .where((AiXpDuplicateGroup g) => _selectedKeepers.contains(g.keeperGid))
        .toList();
    backRoute(result: selected);
  }

  String _titleFor(int gid) {
    return widget.planResult.galleriesByGid[gid]?.title ?? 'gid:$gid';
  }

  @override
  Widget build(BuildContext context) {
    final List<AiXpDuplicateGroup> groups = widget.planResult.groups;

    return AlertDialog(
      title: Text('duplicatePreviewTitle'.tr),
      content: SizedBox(
        width: 480,
        height: _previewDialogContentHeight(context),
        child: groups.isEmpty
            ? Center(child: Text('noAiDuplicates'.tr))
            : ListView.builder(
                itemCount: groups.length,
                itemBuilder: (BuildContext context, int index) {
                  final AiXpDuplicateGroup group = groups[index];
                  final bool selected = _selectedKeepers.contains(group.keeperGid);
                  final String header = 'duplicateGroupLabel'.trParams({
                    'title': group.normalizedTitle.isNotEmpty
                        ? group.normalizedTitle
                        : _titleFor(group.keeperGid),
                    'count': (group.duplicateGids.length + 1).toString(),
                  });

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: Theme.of(context).dividerColor.withOpacity(0.5)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          CheckboxListTile(
                            dense: true,
                            value: selected,
                            onChanged: (bool? value) {
                              setStateSafely(() {
                                if (value == true) {
                                  _selectedKeepers.add(group.keeperGid);
                                } else {
                                  _selectedKeepers.remove(group.keeperGid);
                                }
                              });
                            },
                            title: Text(header, maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(group.normalizedCategory),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${'duplicateKeeper'.tr}: ${_titleFor(group.keeperGid)}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(height: 4),
                                ...group.duplicateGids.map(
                                  (int gid) => Text(
                                    '${'duplicateRemove'.tr}: ${_titleFor(gid)}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: Theme.of(context).colorScheme.error,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(onPressed: backRoute, child: Text('cancel'.tr)),
        TextButton(
          onPressed: _selectedKeepers.isEmpty ? null : _submit,
          child: Text('duplicateRemove'.tr),
        ),
      ],
      actionsPadding: const EdgeInsets.only(left: 24, right: 24, bottom: 12),
    );
  }
}
