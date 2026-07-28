import 'package:jhentai/src/model/ai_xp.dart';
import 'package:jhentai/src/service/ai_xp_service.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

/// Mutable UI state for the AI Center page.
class AiCenterPageState {
  /// Persisted / last-built XP profile.
  AiXpProfile? profile;

  LoadingState profileLoadingState = LoadingState.idle;
  LoadingState recommendLoadingState = LoadingState.idle;
  LoadingState organizationLoadingState = LoadingState.idle;
  LoadingState organizationApplyLoadingState = LoadingState.idle;
  LoadingState duplicateLoadingState = LoadingState.idle;
  LoadingState duplicateApplyLoadingState = LoadingState.idle;
  LoadingState searchLoadingState = LoadingState.idle;

  List<AiXpRecommendation> recommendations = <AiXpRecommendation>[];

  AiXpOrganizationPlanResult? organizationPlan;
  final Set<int> selectedMoveGids = <int>{};

  AiXpDuplicatePlanResult? duplicatePlan;

  /// Selected group keeper gids whose removals will be applied.
  final Set<int> selectedDuplicateKeeperGids = <int>{};

  /// Latest progress snapshot for the active long-running op.
  AiXpProgress? progress;

  /// True when the last remote-capable op fell back to local.
  bool showRemoteFallback = false;

  bool get hasProfile => profile != null && !profile!.isEmpty;

  bool get isBusy =>
      profileLoadingState == LoadingState.loading ||
      recommendLoadingState == LoadingState.loading ||
      organizationLoadingState == LoadingState.loading ||
      organizationApplyLoadingState == LoadingState.loading ||
      duplicateLoadingState == LoadingState.loading ||
      duplicateApplyLoadingState == LoadingState.loading ||
      searchLoadingState == LoadingState.loading;
}
