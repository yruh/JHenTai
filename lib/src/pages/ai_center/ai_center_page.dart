import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/model/ai_xp.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/pages/ai_center/ai_center_page_logic.dart';
import 'package:jhentai/src/pages/ai_center/ai_center_page_state.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/notification/tap_menu_button_notification.dart';
import 'package:jhentai/src/service/ai_xp_service.dart';
import 'package:jhentai/src/setting/ai_setting.dart';
import 'package:jhentai/src/widget/eh_gallery_category_tag.dart';
import 'package:jhentai/src/widget/eh_image.dart';
import 'package:jhentai/src/widget/eh_wheel_speed_controller.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

class AiCenterPage extends StatelessWidget {
  final bool showMenuButton;

  AiCenterPage({super.key, this.showMenuButton = false});

  final AiCenterPageLogic logic = Get.put(AiCenterPageLogic(), permanent: true);
  final AiCenterPageState state = Get.find<AiCenterPageLogic>().state;

  static const double _maxContentWidth = 900;
  static const double _cardRadius = 8;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: showMenuButton
            ? IconButton(
                icon: const Icon(FontAwesomeIcons.bars, size: 20),
                onPressed: () => TapMenuButtonNotification().dispatch(context),
              )
            : null,
        centerTitle: true,
        title: Text('aiCenter'.tr),
        actions: [
          GetBuilder<AiCenterPageLogic>(
            id: AiCenterPageLogic.modeId,
            builder: (_) => Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: _ModeChip(remote: aiSetting.isReady),
              ),
            ),
          ),
          IconButton(
            tooltip: 'aiSettings'.tr,
            icon: const Icon(Icons.settings_outlined),
            onPressed: logic.openSettingsDialog,
          ),
        ],
        bottom: TabBar(
          controller: logic.tabController,
          isScrollable: true,
          tabs: [
            Tab(text: 'aiXpTab'.tr),
            Tab(text: 'aiRecommendTab'.tr),
            Tab(text: 'aiManageTab'.tr),
            Tab(text: 'aiSearchTab'.tr),
          ],
        ),
      ),
      body: Column(
        children: [
          _buildProgressBanner(context),
          _buildFallbackBanner(context),
          Expanded(
            child: TabBarView(
              controller: logic.tabController,
              children: [
                _buildProfileTab(context),
                _buildRecommendTab(context),
                _buildManageTab(context),
                _buildSearchTab(context),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Banners
  // ---------------------------------------------------------------------------

  Widget _buildProgressBanner(BuildContext context) {
    return GetBuilder<AiCenterPageLogic>(
      id: AiCenterPageLogic.progressId,
      builder: (_) {
        final AiXpProgress? progress = state.progress;
        if (progress == null) {
          return const SizedBox.shrink();
        }
        final bool determinate = progress.total > 0;
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  logic.formatProgress(progress),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: determinate
                      ? (progress.current / progress.total).clamp(0.0, 1.0).toDouble()
                      : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFallbackBanner(BuildContext context) {
    return GetBuilder<AiCenterPageLogic>(
      id: AiCenterPageLogic.modeId,
      builder: (_) {
        if (!state.showRemoteFallback) {
          return const SizedBox.shrink();
        }
        return Material(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          child: ListTile(
            dense: true,
            leading: Icon(
              Icons.info_outline,
              color: Theme.of(context).colorScheme.onTertiaryContainer,
            ),
            title: Text(
              'aiRemoteFallback'.tr,
              style: TextStyle(color: Theme.of(context).colorScheme.onTertiaryContainer),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () {
                state.showRemoteFallback = false;
                logic.update([AiCenterPageLogic.modeId]);
              },
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Shared layout
  // ---------------------------------------------------------------------------

  Widget _constrainedScroll({
    required ScrollController controller,
    required List<Widget> children,
    required Future<void> Function()? onRefresh,
  }) {
    final Widget list = EHWheelSpeedController(
      controller: controller,
      child: ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxContentWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );

    if (onRefresh == null) {
      return list;
    }
    return RefreshIndicator(onRefresh: onRefresh, child: list);
  }

  Widget _sectionCard({
    required BuildContext context,
    required String title,
    required Widget child,
    List<Widget>? actions,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: UIConfig.backGroundColor(context),
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(color: Theme.of(context).dividerColor.withOpacity(0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (actions != null) ...actions,
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }

  Widget _chipWrap(List<String> labels, BuildContext context) {
    if (labels.isEmpty) {
      return Text('-', style: Theme.of(context).textTheme.bodySmall);
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: labels
          .map(
            (String label) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(label, style: Theme.of(context).textTheme.bodySmall),
            ),
          )
          .toList(),
    );
  }

  Widget _emptyBox(BuildContext context, String message, {VoidCallback? onAction, String? actionLabel}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(Icons.inbox_outlined, size: 40, color: Theme.of(context).disabledColor),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (onAction != null && actionLabel != null) ...[
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onAction, child: Text(actionLabel)),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Profile tab
  // ---------------------------------------------------------------------------

  Widget _buildProfileTab(BuildContext context) {
    return GetBuilder<AiCenterPageLogic>(
      id: AiCenterPageLogic.profileId,
      builder: (_) {
        return _constrainedScroll(
          controller: logic.profileScrollController,
          onRefresh: logic.refreshProfile,
          children: [
            _sectionCard(
              context: context,
              title: 'aiXpProfile'.tr,
              actions: [
                if (state.profileLoadingState == LoadingState.loading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: 'refreshAiXp'.tr,
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: logic.refreshProfile,
                  ),
              ],
              child: _buildProfileBody(context),
            ),
          ],
        );
      },
    );
  }

  Widget _buildProfileBody(BuildContext context) {
    if (state.profileLoadingState == LoadingState.loading && state.profile == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (state.profileLoadingState == LoadingState.error && state.profile == null) {
      return _emptyBox(
        context,
        'aiOperationFailed'.tr,
        onAction: logic.loadProfile,
        actionLabel: 'OK'.tr,
      );
    }

    final AiXpProfile? profile = state.profile;
    if (profile == null || profile.isEmpty) {
      return _emptyBox(
        context,
        'aiXpEmpty'.tr,
        onAction: state.profileLoadingState == LoadingState.loading ? null : logic.refreshProfile,
        actionLabel: 'refreshAiXp'.tr,
      );
    }

    final String updatedAt = profile.builtAtMs > 0
        ? DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(profile.builtAtMs))
        : '-';

    final List<MapEntry<String, double>> topTags = logic.topWeighted(profile.tagWeights);
    final List<MapEntry<String, double>> titleTerms = logic.topWeighted(profile.titleWeights);
    final List<AiXpTagPair> pairs = profile.tagPairs.take(20).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('aiXpSourceCount'.trParams({'count': profile.signalCount.toString()})),
        const SizedBox(height: 4),
        Text('aiXpUpdatedAt'.trParams({'time': updatedAt})),
        const SizedBox(height: 14),
        Text('aiTopTags'.tr, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        _chipWrap(
          topTags.map((MapEntry<String, double> e) => '${e.key} (${e.value.toStringAsFixed(2)})').toList(),
          context,
        ),
        const SizedBox(height: 14),
        Text('aiTitlePreferences'.tr, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        _chipWrap(
          titleTerms.map((MapEntry<String, double> e) => '${e.key} (${e.value.toStringAsFixed(2)})').toList(),
          context,
        ),
        const SizedBox(height: 14),
        Text('aiTagPairs'.tr, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        _chipWrap(
          pairs
              .map(
                (AiXpTagPair p) =>
                    '${p.left} + ${p.right} (${p.weight.toStringAsFixed(2)})',
              )
              .toList(),
          context,
        ),
        const SizedBox(height: 14),
        Text('aiSaturatedTags'.tr, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        _chipWrap(profile.saturatedTags, context),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Recommendations tab
  // ---------------------------------------------------------------------------

  Widget _buildRecommendTab(BuildContext context) {
    return GetBuilder<AiCenterPageLogic>(
      id: AiCenterPageLogic.recommendId,
      builder: (_) {
        return _constrainedScroll(
          controller: logic.recommendScrollController,
          onRefresh: null,
          children: [
            // Unframed section header — only repeated recommendation items are framed.
            Row(
              children: [
                Expanded(
                  child: Text(
                    'aiRecommendations'.tr,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: state.recommendLoadingState == LoadingState.loading
                      ? null
                      : logic.generateRecommendations,
                  child: state.recommendLoadingState == LoadingState.loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text('generateAiRecommendations'.tr),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _buildRecommendBody(context),
          ],
        );
      },
    );
  }

  Widget _buildRecommendBody(BuildContext context) {
    if (state.recommendLoadingState == LoadingState.loading && state.recommendations.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (!state.hasProfile && state.recommendations.isEmpty) {
      return _emptyBox(
        context,
        'aiNeedProfile'.tr,
        onAction: state.profileLoadingState == LoadingState.loading ? null : logic.refreshProfile,
        actionLabel: 'refreshAiXp'.tr,
      );
    }
    if (state.recommendations.isEmpty) {
      return _emptyBox(
        context,
        'noAiRecommendations'.tr,
        onAction: state.recommendLoadingState == LoadingState.loading
            ? null
            : logic.generateRecommendations,
        actionLabel: 'generateAiRecommendations'.tr,
      );
    }

    return Column(
      children: [
        for (int i = 0; i < state.recommendations.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _RecommendationTile(
            recommendation: state.recommendations[i],
            onTap: () => logic.openGallery(state.recommendations[i].gallery),
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Manage tab
  // ---------------------------------------------------------------------------

  Widget _buildManageTab(BuildContext context) {
    return GetBuilder<AiCenterPageLogic>(
      id: AiCenterPageLogic.manageId,
      builder: (_) {
        final bool orgBusy = state.organizationLoadingState == LoadingState.loading ||
            state.organizationApplyLoadingState == LoadingState.loading;
        final bool dupBusy = state.duplicateLoadingState == LoadingState.loading ||
            state.duplicateApplyLoadingState == LoadingState.loading;

        return _constrainedScroll(
          controller: logic.manageScrollController,
          onRefresh: null,
          children: [
            _sectionCard(
              context: context,
              title: 'aiFavoriteOrganizer'.tr,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!state.hasProfile)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'organizationRequirement'.tr,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  TextField(
                    controller: logic.organizationController,
                    minLines: 2,
                    maxLines: 4,
                    enabled: state.hasProfile && !orgBusy,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      isDense: true,
                      hintText: 'aiFavoriteOrganizer'.tr,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed: !state.hasProfile || orgBusy ? null : logic.previewOrganization,
                      child: orgBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text('previewOrganization'.tr),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _sectionCard(
              context: context,
              title: 'scanAiDuplicates'.tr,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed: dupBusy ? null : logic.scanDuplicates,
                      child: dupBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text('scanAiDuplicates'.tr),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Search tab
  // ---------------------------------------------------------------------------

  Widget _buildSearchTab(BuildContext context) {
    return GetBuilder<AiCenterPageLogic>(
      id: AiCenterPageLogic.searchId,
      builder: (_) {
        final bool busy = state.searchLoadingState == LoadingState.loading;
        return _constrainedScroll(
          controller: logic.searchScrollController,
          onRefresh: null,
          children: [
            _sectionCard(
              context: context,
              title: 'enhancedAiSearch'.tr,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: logic.searchController,
                    minLines: 1,
                    maxLines: 3,
                    enabled: !busy,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => logic.runEnhancedSearch(),
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      isDense: true,
                      hintText: 'enhancedAiSearch'.tr,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: busy ? null : logic.runEnhancedSearch,
                      child: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text('runEnhancedSearch'.tr),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ModeChip extends StatelessWidget {
  final bool remote;

  const _ModeChip({required this.remote});

  @override
  Widget build(BuildContext context) {
    final String label = remote ? 'remoteAiMode'.tr : 'localAiMode'.tr;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: remote ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: remote ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _RecommendationTile extends StatelessWidget {
  final AiXpRecommendation recommendation;
  final VoidCallback onTap;

  const _RecommendationTile({
    required this.recommendation,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Gallery gallery = recommendation.gallery;
    final String scoreText = 'aiRecommendationScore'.trParams({
      'score': recommendation.score.toStringAsFixed(2),
    });

    return Material(
      color: UIConfig.backGroundColor(context),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Theme.of(context).dividerColor.withOpacity(0.5)),
          ),
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: EHImage(
                  galleryImage: gallery.cover,
                  containerHeight: 96,
                  containerWidth: 72,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      gallery.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        EHGalleryCategoryTag(category: gallery.category),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            scoreText,
                            style: Theme.of(context).textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (recommendation.explanations.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'aiRecommendationReasons'.tr,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      const SizedBox(height: 2),
                      ...recommendation.explanations.take(3).map(
                            (AiXpScoreExplanation e) => Text(
                              '- ${e.detail.isNotEmpty ? e.detail : e.kind} (${e.contribution.toStringAsFixed(2)})',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
