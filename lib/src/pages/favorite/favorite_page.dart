import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../base/base_page.dart';
import 'favorite_page_logic.dart';
import 'favorite_page_state.dart';

class FavoritePage extends BasePage {
  const FavoritePage({
    Key? key,
    bool showMenuButton = false,
    bool showTitle = false,
    String? name,
  }) : super(
          key: key,
          showMenuButton: showMenuButton,
          showJumpButton: true,
          showFilterButton: true,
          showScroll2TopButton: true,
          showTitle: showTitle,
          name: name,
        );

  @override
  FavoritePageLogic get logic => Get.put<FavoritePageLogic>(FavoritePageLogic(), permanent: true);

  @override
  FavoritePageState get state => Get.find<FavoritePageLogic>().state;

  @override
  List<Widget> buildAppBarActions() {
    return [
      if (state.galleries.isNotEmpty) IconButton(icon: Icon(Icons.send, size: 20), onPressed: logic.handleTapJumpButton),
      if (state.galleries.isNotEmpty) IconButton(icon: const Icon(Icons.sort), onPressed: logic.handleChangeSortOrder),
      IconButton(icon: const Icon(Icons.filter_alt_outlined, size: 28), onPressed: logic.handleTapFilterButton),
      _buildBatchOperationsAction(),
    ];
  }

  Widget _buildBatchOperationsAction() {
    return GetBuilder<FavoritePageLogic>(
      id: logic.batchOperationId,
      builder: (_) {
        if (state.batchOperationRunning) {
          return const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        return PopupMenuButton<String>(
          tooltip: 'favoriteBatchOperations'.tr,
          icon: const Icon(Icons.more_vert),
          onSelected: (String value) {
            switch (value) {
              case 'batchFetchFavoriteTorrents':
                logic.handleBatchFetchFavoriteTorrents();
                break;
              case 'deduplicateFavorites':
                logic.handleDeduplicateFavorites();
                break;
            }
          },
          itemBuilder: (BuildContext context) {
            return [
              PopupMenuItem<String>(
                value: 'batchFetchFavoriteTorrents',
                child: Row(
                  children: [
                    const Icon(FontAwesomeIcons.magnet, size: 16),
                    const SizedBox(width: 12),
                    Flexible(child: Text('batchFetchFavoriteTorrents'.tr)),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'deduplicateFavorites',
                child: Row(
                  children: [
                    const Icon(Icons.filter_none, size: 18),
                    const SizedBox(width: 12),
                    Flexible(child: Text('deduplicateFavorites'.tr)),
                  ],
                ),
              ),
            ];
          },
        );
      },
    );
  }
}
