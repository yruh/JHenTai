import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Mutable controller for [EHBatchProgressDialog].
///
/// Call [setPhase] / [setProgress] / [clearProgress] from the long-running
/// operation; the dialog listens via [ChangeNotifier].
class EHBatchProgressController extends ChangeNotifier {
  String phase = '';
  int current = 0;
  int total = 0;
  bool hasDeterminateProgress = false;
  bool isCancelled = false;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  void setPhase(String value) {
    if (_disposed || phase == value) {
      return;
    }
    phase = value;
    notifyListeners();
  }

  /// Show determinate progress. When [total] is 0, falls back to indeterminate.
  void setProgress({required int current, required int total}) {
    if (_disposed) {
      return;
    }
    this.current = current;
    this.total = total;
    hasDeterminateProgress = total > 0;
    notifyListeners();
  }

  void clearProgress() {
    if (_disposed) {
      return;
    }
    current = 0;
    total = 0;
    hasDeterminateProgress = false;
    notifyListeners();
  }

  /// Soft-cancel: in-flight requests finish; callers stop starting new ones.
  void cancel() {
    if (_disposed || isCancelled) {
      return;
    }
    isCancelled = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Non-dismissible progress dialog with phase text, optional determinate bar,
/// and a cancel button.
class EHBatchProgressDialog extends StatelessWidget {
  final String title;
  final EHBatchProgressController controller;

  const EHBatchProgressDialog({
    Key? key,
    required this.title,
    required this.controller,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: AnimatedBuilder(
          animation: controller,
          builder: (BuildContext context, Widget? child) {
            final double? value = controller.hasDeterminateProgress && controller.total > 0
                ? (controller.current / controller.total).clamp(0.0, 1.0).toDouble()
                : null;

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (controller.phase.isNotEmpty)
                  Text(
                    controller.phase,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ).marginOnly(bottom: 16),
                LinearProgressIndicator(value: value),
                if (controller.hasDeterminateProgress)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${controller.current} / ${controller.total}',
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (controller.isCancelled)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'operationCancelled'.tr,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.error,
                          ),
                    ),
                  ),
              ],
            );
          },
        ),
        actions: [
          AnimatedBuilder(
            animation: controller,
            builder: (BuildContext context, Widget? child) {
              return TextButton(
                onPressed: controller.isCancelled ? null : controller.cancel,
                child: Text('cancel'.tr),
              );
            },
          ),
        ],
        actionsPadding: const EdgeInsets.only(left: 24, right: 24, bottom: 12),
      ),
    );
  }
}
