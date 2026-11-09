import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart'
    show DragStartBehavior, PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:reader/models/app_preferences.dart';
import 'package:reader/models/chapter_comment.dart';
import 'package:reader/models/page_models.dart';
import 'package:reader/reader/dependencies.dart';
import 'package:reader/reader/internal/reader_comment_layout.dart';
import 'package:reader/reader/internal/reader_paged_scroll_physics.dart';
import 'package:reader/reader/reader_book.dart';
import 'package:reader/reader/reader_controller.dart';
import 'package:reader/reader/reader_image.dart';
import 'package:reader/reader/reader_pinch_zoom.dart';
import 'package:reader/reader/reader_progress_seek_bar.dart';
import 'package:reader/reader/reader_sheet_swipe_dismiss.dart';
import 'package:reader/reader/reader_status_label.dart';
import 'package:reader/services/app_preferences_controller.dart';
import 'package:reader/services/chinese_converter.dart';
import 'package:reader/services/document_tree_image_provider.dart';
import 'package:reader/services/image_cache.dart';
import 'package:reader/services/reader_comment_utils.dart';
import 'package:reader/services/reader_history_recorder.dart';
import 'package:reader/services/site_session.dart';
import 'package:reader/services/tree_image_provider.dart';
import 'package:reader/utils/platform_capabilities.dart';
import 'package:reader/widgets/responsive_layout.dart';
import 'package:reader/widgets/settings_ui.dart';
import 'package:reader/widgets/top_notice.dart';

part 'reader_screen/chapter_boundary.dart';
part 'reader_screen/comment_cloud.dart';
part 'reader_screen/hud_overlay.dart';
part 'reader_screen/settings_sheet.dart';

const Duration _readerExitFadeDuration = Duration(milliseconds: 220);
const double _tapTurnSideZoneRatio = 0.33;
const double _settingsDismissDistance = 72;
const double _instantPageSwipeDistance = 72;
const double _instantPageSwipeVelocity = 220;

/// 桌面端把鼠标补进可拖拽设备。
///
/// Flutter 默认的 [MaterialScrollBehavior.dragDevices] 只含触摸／触控笔／触控板，
/// 不含鼠标，所以 Windows 上按住左键拖动阅读器是完全没反应的——只能滚轮。
/// 只覆盖 dragDevices，滚动条等其它行为沿用 Material 默认。
class _ReaderMouseDragScrollBehavior extends MaterialScrollBehavior {
  const _ReaderMouseDragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => <PointerDeviceKind>{
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    required this.services,
    required this.page,
    required this.isExitTransitionActive,
    required this.onRequestChapterNavigation,
    required this.onRequestAuth,
    required this.onLogoutForExpiredSession,
    required this.onResolveHistoryCover,
    this.openAtEnd = false,
    this.onOpenAtEndConsumed,
    this.onLoadContinuousChapter,
    this.onContinuousChapterChanged,
    this.onExitReader,
    this.onExitToHome,
    this.onReloadChapter,
    this.onLoadCatalog,
    super.key,
  });

  final ReaderPageData page;
  final ReaderScreenServices services;
  final bool isExitTransitionActive;
  final ReaderChapterNavigationCallback onRequestChapterNavigation;
  final Future<void> Function() onRequestAuth;
  final Future<void> Function() onLogoutForExpiredSession;
  final ResolveReaderHistoryCover onResolveHistoryCover;

  /// 本章打开后定位末页。
  final bool openAtEnd;

  /// 清除末页定位意图。
  final VoidCallback? onOpenAtEndConsumed;

  /// 连续阅读：加载下一章数据（不切换路由）。
  final ReaderAdjacentChapterLoader? onLoadContinuousChapter;

  /// 连续阅读：滚动进入另一章后同步给上层。
  final void Function(ReaderPageData page)? onContinuousChapterChanged;

  /// 退出阅读页（返回上一页 / 漫画详情）。
  final Future<void> Function()? onExitReader;

  /// 退出阅读页并回到主标签根页。
  final Future<void> Function()? onExitToHome;

  /// 重新加载当前章节。
  final Future<void> Function(ReaderPageData page)? onReloadChapter;

  /// 加载当前漫画的目录数据供阅读器内章节选择面板使用。
  final Future<DetailPageData?> Function(ReaderPageData page)? onLoadCatalog;

  @override
  State<ReaderScreen> createState() => ReaderScreenState();
}

class ReaderScreenState extends State<ReaderScreen> {
  static double _cachedPortraitTopSafeInset = 0;

  late final ReaderController _controller;
  final ScrollController _settingsSheetScrollController = ScrollController();
  GlobalKey<ReaderBookState> _bookKey = GlobalKey<ReaderBookState>();
  double _instantPageDragDx = 0;

  ReaderController get controller => _controller;

  @override
  void initState() {
    super.initState();
    _controller = ReaderController(
      preferencesController: widget.services.preferencesController,
      progressStore: widget.services.progressStore,
      platformBridge: widget.services.platformBridge,
      apiClient: widget.services.apiClient,
      session: widget.services.session,
      historyRecorder: ReaderHistoryRecorder(
        resolveCoverUrl: widget.onResolveHistoryCover,
        localLibraryStore: widget.services.localLibraryStore,
        session: widget.services.session,
      ),
      onRequestChapterNavigation: widget.onRequestChapterNavigation,
      onRequestAuth: widget.onRequestAuth,
      onLogoutForExpiredSession: widget.onLogoutForExpiredSession,
      onShowMessage: _showNotice,
      loadAdjacentChapter: widget.onLoadContinuousChapter,
      onActiveChapterChanged: widget.onContinuousChapterChanged,
    );
    _controller.attachPlatformSubscriptions();
    _controller.onSegmentsEvicted = _evictSegmentImages;
    _controller.imageOffset = (int index) => _estimateOffsetForImage(
      context,
      _controller.page ?? widget.page,
      index,
    );
    _controller.turnBook = (int index) async {
      final int count = widget.page.imageUrls.length;
      await _bookKey.currentState?.turnTo(
        index >= count ? (count + 1) ~/ 2 : index ~/ 2,
      );
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.setPage(widget.page, openAtEnd: widget.openAtEnd);
      _consumeOpenAtEndIntent();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.setViewport(MediaQuery.sizeOf(context));
  }

  @override
  void didUpdateWidget(covariant ReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.page, widget.page)) {
      if (oldWidget.page.uri != widget.page.uri) {
        _bookKey = GlobalKey<ReaderBookState>();
      }
      _controller.setPage(
        widget.page,
        previousUri: oldWidget.page.uri,
        openAtEnd: widget.openAtEnd,
      );
      _consumeOpenAtEndIntent();
    }
  }

  void _consumeOpenAtEndIntent() {
    // 阅读器切换到新章节后，无论本次是否使用了 openAtEnd，都通知上层清除
    // 这个一次性意图：避免加载失败 / 被其它导航打断 / 经目录等入口再次打开
    // 同一章节时，残留的 key 误判 openAtEnd 直接跳到末页。
    widget.onOpenAtEndConsumed?.call();
  }

  @override
  void dispose() {
    _settingsSheetScrollController.dispose();
    _controller.dispose();
    unawaited(_controller.restoreDefaultEnvironment());
    super.dispose();
  }

  void _showNotice(String message) {
    if (!mounted) return;
    TopNotice.show(context, message, tone: TopNotice.toneForMessage(message));
  }

  void _handleReaderTapUp(TapUpDetails details) {
    final BuildContext? viewportContext =
        _controller.viewportKey.currentContext;
    final RenderBox? renderBox =
        viewportContext?.findRenderObject() as RenderBox?;
    final double viewportWidth = renderBox != null && renderBox.hasSize
        ? renderBox.size.width
        : MediaQuery.sizeOf(context).width;
    final double dx = details.localPosition.dx;
    final ReaderPreferences preferences = _controller.preferences;

    if (preferences.tapToTurnPage) {
      final double sideZoneWidth = viewportWidth * _tapTurnSideZoneRatio;
      if (dx <= sideZoneWidth) {
        _handleTapPageTurn(tappedLeft: true);
        return;
      }
      if (dx >= viewportWidth - sideZoneWidth) {
        _handleTapPageTurn(tappedLeft: false);
        return;
      }
    }
  }

  void _handleTapPageTurn({required bool tappedLeft}) {
    _controller.hideChapterControls();
    final bool isRightToLeft =
        _controller.preferences.readingDirection ==
        ReaderReadingDirection.rightToLeft;
    final bool forward = isRightToLeft ? tappedLeft : !tappedLeft;
    if (forward) {
      unawaited(_controller.stepForward());
    } else {
      unawaited(_controller.stepBackward());
    }
  }

  Future<void> _showReaderSettingsSheet() async {
    if (_controller.isSettingsOpen) return;
    _controller.setSettingsSheetOpen(true);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: false,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: _buildReaderSettingsSheet,
    );
    _controller.setSettingsSheetOpen(false);
  }

  double _readerTopSafeInset(BuildContext context) {
    final Size size = MediaQuery.sizeOf(context);
    final bool isPortrait = size.height >= size.width;
    final double viewTop = MediaQuery.viewPaddingOf(context).top;
    if (isPortrait && viewTop > 0) {
      _cachedPortraitTopSafeInset = math.max(
        _cachedPortraitTopSafeInset,
        viewTop,
      );
    }
    if (!isPortrait) {
      return viewTop;
    }
    if (viewTop > 0) {
      return viewTop;
    }
    if (_cachedPortraitTopSafeInset > 0) {
      return _cachedPortraitTopSafeInset;
    }
    if (_controller.platformBridge.isAndroidSupported) {
      return 36;
    }
    return 0;
  }

  Widget _buildReaderOverlay(
    BuildContext context,
    ReaderPageData page, {
    required double topSafeInset,
  }) {
    final ReaderPreferences preferences = _controller.preferences;
    final int? batteryLevel = _controller.batteryLevel;
    final bool hideTopStatus = _controller.isChapterControlsVisible;
    final List<Widget> statusItems = <Widget>[
      if (preferences.showProgress)
        ReaderStatusLabel(
          label: _readerPageCountLabel(page),
          fontSize: 12,
        ),
      if (_controller.platformBridge.isAndroidSupported &&
          preferences.showBattery)
        ReaderStatusLabel(
          label: batteryLevel == null ? '--%' : '$batteryLevel%',
          icon: Icons.bolt_rounded,
          fontSize: 12,
        ),
      if (preferences.showClock) const _ReaderClockLabel(),
    ];
    return IgnorePointer(
      child: Stack(
        children: <Widget>[
          if (statusItems.isNotEmpty && !hideTopStatus)
            Positioned(
              top: topSafeInset + 6,
              right: 6,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0x7A000000),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (int i = 0; i < statusItems.length; i += 1) ...<Widget>[
                        if (i > 0) const SizedBox(width: 8),
                        statusItems[i],
                      ],
                    ],
                  ),
                ),
              ),
            ),
          if (page.nextHref.trim().isNotEmpty)
            _buildNextChapterCue(context, page),
        ],
      ),
    );
  }

  String _readerPageCountLabel(ReaderPageData page) {
    if (page.imageUrls.isEmpty) return '--/--';
    final int visibleIndex =
        (_controller.isPaged
                ? _controller.currentPageIndex
                : _controller.visibleImageIndex)
            .clamp(0, page.imageUrls.length - 1);
    if (_controller.isBook &&
        _controller.currentPageIndex < page.imageUrls.length) {
      final int first = visibleIndex ~/ 2 * 2 + 1;
      final int last = math.min(first + 1, page.imageUrls.length);
      return '${first == last ? first : '$first–$last'}/${page.imageUrls.length}';
    }
    return '${visibleIndex + 1}/${page.imageUrls.length}';
  }

  Future<void> _navigateToHref(String href, ReaderPageData currentPage) {
    final bool isPrev = currentPage.prevHref == href;
    return widget.onRequestChapterNavigation(
      href,
      prevHref: isPrev ? '' : currentPage.uri,
      nextHref: isPrev ? currentPage.uri : '',
      catalogHref: currentPage.catalogHref,
      openAtEnd: isPrev,
    );
  }

  void goToNextChapter() {
    final ReaderPageData page = widget.page;
    if (page.nextHref.trim().isEmpty) return;
    unawaited(_navigateToHref(page.nextHref, page));
  }

  void goToPreviousChapter() {
    final ReaderPageData page = widget.page;
    if (page.prevHref.trim().isEmpty) return;
    unawaited(_navigateToHref(page.prevHref, page));
  }

  void _seekReaderToImageIndex(
    BuildContext context,
    ReaderPageData page,
    int imageIndex,
  ) {
    if (_controller.isZoomGestureLocked || page.imageUrls.isEmpty) return;
    _bookKey.currentState?.cancelTurn();
    final int clampedIndex = imageIndex.clamp(0, page.imageUrls.length - 1);
    final double estimatedOffset = _controller.isPaged
        ? 0
        : _estimateOffsetForImage(context, page, clampedIndex);
    _controller.seekToImageIndex(
      page: page,
      imageIndex: clampedIndex,
      estimatedScrollOffset: estimatedOffset,
    );
  }

  double _estimateOffsetForImage(
    BuildContext context,
    ReaderPageData page,
    int imageIndex,
  ) {
    final Size screenSize = MediaQuery.sizeOf(context);
    final ReaderPreferences preferences = _controller.preferences;
    final bool showGap = preferences.showPageGap;
    final double topPadding = preferences.fullscreen && showGap ? 0 : 8;
    final double itemSpacing = showGap ? 10 : 0;

    if (preferences.pageFit == ReaderPageFit.fitScreen) {
      final double viewportHeight = screenSize.height * 0.72;
      return topPadding + (viewportHeight + itemSpacing) * imageIndex;
    }

    double offset = topPadding;
    final double maxReaderWidth = wideReaderMaxWidth(
      context,
      preferences.pageFit,
    );
    final double contentWidth = maxReaderWidth.isFinite
        ? math.min(screenSize.width, maxReaderWidth)
        : screenSize.width;
    final Map<String, double> aspectRatios = _controller.imageAspectRatios;
    for (int index = 0; index < imageIndex; index += 1) {
      final String imageUrl = page.imageUrls[index];
      final double rawAspectRatio = aspectRatios[imageUrl] ?? 0.72;
      final double safeAspectRatio =
          rawAspectRatio.isFinite && rawAspectRatio > 0.05
          ? rawAspectRatio
          : 0.72;
      offset += (contentWidth / safeAspectRatio) + itemSpacing;
    }
    return offset;
  }

  Widget _buildReaderScrollableContent(
    BuildContext context,
    ReaderPageData page,
  ) {
    final ReaderPreferences preferences = _controller.preferences;
    final bool showGap = preferences.showPageGap;
    final double topPadding = preferences.fullscreen && showGap ? 0 : 8;
    final bool continuous = _controller.isContinuous;
    final List<ReaderPageData> segments = _controller.segments.isEmpty
        ? <ReaderPageData>[page]
        : _controller.segments;
    final bool showCommentTail = _controller.shouldShowCommentTailPage(page);
    final bool showComments = preferences.showChapterComments;
    final bool hasNextChapter = page.nextHref.trim().isNotEmpty;
    final double? viewportHeight =
        preferences.pageFit == ReaderPageFit.fitScreen
        ? MediaQuery.sizeOf(context).height * 0.72
        : null;
    _controller.segmentTopPadding = topPadding;
    // 连续阅读时下一章自动接在后面，只保留顶部下拉回上一章。
    final ReaderPageData pullPage = continuous
        ? segments.first.copyWith(nextHref: '')
        : page;
    final ScrollPhysics scrollPhysics =
        (_controller.isScaleGestureActive || _controller.zoomScale > 1.01)
        ? const NeverScrollableScrollPhysics()
        : const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics());
    final Widget tail = continuous
        ? _buildContinuousChapterTail(context, segments.last)
        : showCommentTail
        ? _buildReaderCommentTailPage(context, page)
        : hasNextChapter
        ? _buildReaderNextChapterFooter(context, page)
        : const SizedBox.shrink();
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        _handleScrollLifecycle(notification);
        if (!_controller.isZoomGestureLocked) {
          _controller.handleChapterPull(
            notification,
            page: pullPage,
            controller: _controller.scrollController,
          );
        }
        if (notification.depth == 0 && notification is ScrollEndNotification) {
          _controller.handleScrollIdle();
        }
        if (_isUserDrivenScrollNotification(notification)) {
          _controller.noteUserInteraction();
        }
        return false;
      },
      child: CustomScrollView(
        key: ValueKey<String>(
          'reader-scroll-${_controller.scrollSession}-${preferences.pageFit.name}-$showGap-$showComments-$continuous',
        ),
        controller: _controller.scrollController,
        physics: scrollPhysics,
        slivers: <Widget>[
          SliverToBoxAdapter(
            key: const ValueKey<String>('reader-top-padding'),
            child: SizedBox(height: topPadding),
          ),
          for (int index = 0; index < segments.length; index += 1) ...<Widget>[
            if (index > 0)
              SliverToBoxAdapter(
                key: ValueKey<String>('reader-divider-${segments[index].uri}'),
                child: _buildContinuousChapterDivider(context, segments[index]),
              ),
            _buildReaderSegmentSliver(
              context,
              segments[index],
              showGap: showGap,
              viewportHeight: viewportHeight,
            ),
            if (continuous &&
                _controller.shouldShowChapterComments(segments[index]))
              SliverToBoxAdapter(
                key: ValueKey<String>('reader-comments-${segments[index].uri}'),
                child: _buildContinuousSegmentComments(
                  context,
                  segments[index],
                ),
              ),
          ],
          SliverToBoxAdapter(
            key: const ValueKey<String>('reader-tail'),
            child: tail,
          ),
          const SliverToBoxAdapter(
            key: ValueKey<String>('reader-bottom-padding'),
            child: SizedBox(height: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildReaderSegmentSliver(
    BuildContext context,
    ReaderPageData segment, {
    required bool showGap,
    required double? viewportHeight,
  }) {
    final ReaderPreferences preferences = _controller.preferences;
    return SliverList(
      key: _controller.segmentSliverKeyFor(segment.uri),
      delegate: SliverChildBuilderDelegate(
        (BuildContext context, int index) {
          return Padding(
            key: _controller.imageItemKeyForSegment(segment.uri, index),
            padding: EdgeInsets.only(bottom: showGap ? 10 : 0),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: wideReaderMaxWidth(context, preferences.pageFit),
                ),
                child: _buildReaderImageFrame(
                  context,
                  page: segment,
                  imageIndex: index,
                  imageUrl: segment.imageUrls[index],
                  viewportHeight: viewportHeight,
                ),
              ),
            ),
          );
        },
        childCount: segment.imageUrls.length,
        addAutomaticKeepAlives: false,
      ),
    );
  }

  /// 连续阅读移除的章节：把它们的图片从内存缓存里清掉。
  void _evictSegmentImages(List<ReaderPageData> evicted) {
    for (final ReaderPageData segment in evicted) {
      for (final String imageUrl in segment.imageUrls) {
        unawaited(_readerImageProvider(segment, imageUrl).evict());
      }
    }
  }

  Widget _buildBook(BuildContext context, ReaderPageData page) {
    final ReaderPreferences prefs = _controller.preferences;
    final int count = page.imageUrls.length;
    final int spreads = (count + 1) ~/ 2;
    final bool reverse =
        prefs.readingDirection == ReaderReadingDirection.rightToLeft;
    return SafeArea(
      top: false,
      bottom: !prefs.fullscreen,
      child: Padding(
        padding: EdgeInsets.all(prefs.showPageGap ? 8 : 0),
        child: ReaderBook(
          key: _bookKey,
          index: _controller.currentPageIndex >= count
              ? spreads
              : _controller.currentPageIndex ~/ 2,
          count: math.max(
            1,
            spreads + (_controller.shouldShowCommentTailPage(page) ? 1 : 0),
          ),
          reverse: reverse,
          enabled:
              !_controller.isZoomGestureLocked &&
              !_controller.isNextChapterLoading,
          animate: !prefs.disablePageTransitionAnimation,
          onStart: () {
            _controller.noteUserInteraction();
            _controller.cancelAutoTurn();
            _controller.hideChapterControls();
          },
          onEnd: _controller.restartAutoTurnAfterScroll,
          onChanged: (int index) =>
              _controller.handlePageChanged(math.min(index * 2, count)),
          onEdge: (bool forward) => unawaited(
            forward ? _controller.stepForward() : _controller.stepBackward(),
          ),
          pageBuilder: (BuildContext context, int index, bool right) {
            final int side = right != reverse ? 1 : 0;
            return LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                if (index == spreads &&
                    _controller.shouldShowCommentTailPage(page)) {
                  return side == 0
                      ? _buildReaderCommentTailPage(
                          context,
                          page,
                          minHeight: constraints.maxHeight,
                        )
                      : const SizedBox.expand();
                }
                final int image = index * 2 + side;
                if (image >= count) return const SizedBox.expand();
                return _buildReaderImageFrame(
                  context,
                  page: page,
                  imageIndex: image,
                  imageUrl: page.imageUrls[image],
                  viewportHeight: constraints.maxHeight,
                  fit: BoxFit.contain,
                  alignment: right
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  color: ReaderBook.paper,
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildReaderPagedContent(BuildContext context, ReaderPageData page) {
    final ReaderPreferences preferences = _controller.preferences;
    final bool reverse =
        preferences.readingDirection == ReaderReadingDirection.rightToLeft;
    final double topPadding = preferences.fullscreen && preferences.showPageGap
        ? 0
        : 8;
    final bool showCommentTail = _controller.shouldShowCommentTailPage(page);
    final bool hasNextChapter = page.nextHref.trim().isNotEmpty;
    final bool instantPageSwitch = preferences.disablePageTransitionAnimation;
    final ScrollPhysics pagePhysics =
        _controller.isZoomGestureLocked || instantPageSwitch
        ? const NeverScrollableScrollPhysics()
        : const ReaderPagedScrollPhysics(
            triggerPageRatio: 0.65,
            parent: BouncingScrollPhysics(),
          );
    final Widget pageView = PageView.builder(
      key: ValueKey<String>(
        'reader-paged-${page.uri}-${preferences.readingDirection.name}-${preferences.pageFit.name}-${preferences.showPageGap}-$showCommentTail',
      ),
      controller: _controller.pageController,
      physics: pagePhysics,
      reverse: reverse,
      itemCount: _controller.readerPagedPageCount(page),
      onPageChanged: _controller.handlePageChanged,
      itemBuilder: (BuildContext context, int index) {
        final ScrollController scrollController = _controller
            .pagedScrollControllerFor(index);
        final bool isCommentPage = index >= page.imageUrls.length;
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Widget pageBody = isCommentPage
                ? _buildReaderCommentTailPage(
                    context,
                    page,
                    minHeight: constraints.maxHeight,
                  )
                : _buildReaderPagedPageBody(
                    context,
                    page: page,
                    imageIndex: index,
                    imageUrl: page.imageUrls[index],
                    constraints: constraints,
                    showNextChapterFooter:
                        !showCommentTail &&
                        hasNextChapter &&
                        index == page.imageUrls.length - 1,
                  );
            final Widget wrappedBody = isCommentPage
                ? pageBody
                : NotificationListener<ScrollNotification>(
                    onNotification: (ScrollNotification notification) {
                      _handleScrollLifecycle(notification);
                      if (_isUserDrivenScrollNotification(notification)) {
                        _controller.noteUserInteraction();
                      }
                      return false;
                    },
                    child: SingleChildScrollView(
                      controller: scrollController,
                      physics: _controller.isZoomGestureLocked
                          ? const NeverScrollableScrollPhysics()
                          : const BouncingScrollPhysics(),
                      child: pageBody,
                    ),
                  );
            return Padding(
              padding: preferences.showPageGap
                  ? EdgeInsets.only(top: topPadding, bottom: 8)
                  : EdgeInsets.zero,
              child: wrappedBody,
            );
          },
        );
      },
    );
    final Widget pagedContent = instantPageSwitch
        ? GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) => _instantPageDragDx = 0,
            onHorizontalDragUpdate: (DragUpdateDetails details) {
              _instantPageDragDx += details.primaryDelta ?? 0;
            },
            onHorizontalDragEnd: (DragEndDetails details) =>
                _handleInstantPageSwipe(details, reverse: reverse),
            onHorizontalDragCancel: () => _instantPageDragDx = 0,
            child: pageView,
          )
        : pageView;
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        _handleScrollLifecycle(notification);
        final int pageCount = _controller.readerPagedPageCount(page);
        final bool isLastReaderPage =
            _controller.currentPageIndex >= pageCount - 1;
        final bool isFirstReaderPage = _controller.currentPageIndex <= 0;
        final bool hasPreviousChapter = page.prevHref.trim().isNotEmpty;
        if (!_controller.isZoomGestureLocked &&
            ((isLastReaderPage && hasNextChapter) ||
                (isFirstReaderPage && hasPreviousChapter))) {
          _controller.handleChapterPull(
            notification,
            page: page,
            controller: _controller.pageController,
            axis: Axis.horizontal,
          );
        }
        if (_isUserDrivenScrollNotification(notification)) {
          _controller.noteUserInteraction();
        }
        return false;
      },
      child: pagedContent,
    );
  }

  void _handleInstantPageSwipe(
    DragEndDetails details, {
    required bool reverse,
  }) {
    final double dragDx = _instantPageDragDx;
    _instantPageDragDx = 0;
    if (_controller.isZoomGestureLocked) {
      return;
    }
    final double velocity = details.primaryVelocity ?? 0;
    final bool isFling = velocity.abs() >= _instantPageSwipeVelocity;
    final bool isDrag = dragDx.abs() >= _instantPageSwipeDistance;
    final double direction = isFling ? velocity : dragDx;
    if (!isFling && !isDrag) {
      return;
    }
    final bool forward = reverse ? direction > 0 : direction < 0;
    if (forward) {
      unawaited(_controller.stepForward());
    } else {
      unawaited(_controller.stepBackward());
    }
  }

  /// 阅读图片的 provider；同一张图每次构造出的 provider 相等，便于按 key 释放缓存。
  ImageProvider<Object> _readerImageProvider(
    ReaderPageData page,
    String imageUrl,
  ) {
    final Uri? parsedUri = Uri.tryParse(imageUrl);
    if (parsedUri != null && parsedUri.scheme == 'file') {
      return FileImage(File.fromUri(parsedUri));
    }
    if (parsedUri != null && parsedUri.scheme == treeImageScheme) {
      return TreeImageProvider.fromUri(parsedUri);
    }
    if (parsedUri != null && parsedUri.scheme == 'content') {
      return DocumentTreeImageProvider(imageUrl);
    }
    return CachedNetworkImageProvider(
      imageUrl,
      cacheManager: AppImageCaches.readerCache,
      headers: AppImageCaches.readerImageHeaders(page.uri),
    );
  }

  Widget _buildReaderImageFrame(
    BuildContext context, {
    required ReaderPageData page,
    required int imageIndex,
    required String imageUrl,
    double? viewportHeight,
    BoxFit? fit,
    Alignment alignment = Alignment.center,
    Color? color,
  }) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final ReaderPreferences preferences = _controller.preferences;
    final bool showGap = preferences.showPageGap;
    fit ??= preferences.pageFit == ReaderPageFit.fitWidth
        ? BoxFit.fitWidth
        : BoxFit.contain;
    final ImageProvider<Object> imageProvider = _readerImageProvider(
      page,
      imageUrl,
    );
    return ColoredBox(
      color:
          color ??
          (showGap ? colorScheme.surface : colorScheme.surfaceContainerLowest),
      child: ReaderChapterImage(
        key: ValueKey<String>('reader-image-$imageUrl-$viewportHeight'),
        imageProvider: imageProvider,
        debugUrl: imageUrl,
        fit: fit,
        alignment: alignment,
        viewportHeight: viewportHeight,
        aspectRatio: _controller.imageAspectRatios[imageUrl],
        onResolvedAspectRatio: (double aspectRatio) {
          if (!aspectRatio.isFinite || aspectRatio <= 0) return;
          _controller.recordImageAspectRatio(imageUrl, aspectRatio);
        },
      ),
    );
  }

  Widget _buildReaderPagedPageBody(
    BuildContext context, {
    required ReaderPageData page,
    required int imageIndex,
    required String imageUrl,
    required BoxConstraints constraints,
    required bool showNextChapterFooter,
  }) {
    final ReaderPreferences preferences = _controller.preferences;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: constraints.maxHeight),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: wideReaderMaxWidth(context, preferences.pageFit),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildReaderImageFrame(
                context,
                page: page,
                imageIndex: imageIndex,
                imageUrl: imageUrl,
                viewportHeight: preferences.pageFit == ReaderPageFit.fitScreen
                    ? constraints.maxHeight
                    : null,
              ),
              if (showNextChapterFooter)
                _buildReaderNextChapterFooter(context, page),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContinuousSegmentComments(
    BuildContext context,
    ReaderPageData segment,
  ) {
    final List<ChapterComment> comments = _controller.commentsFor(segment);
    final Size screenSize = MediaQuery.sizeOf(context);
    final double commentCloudMaxHeight = screenSize.height > 188
        ? screenSize.height - 108
        : 80;
    return Center(
      key: _controller.commentSectionKeyForSegment(segment.uri),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: wideReaderMaxWidth(
            context,
            _controller.preferences.pageFit,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: commentCloudMaxHeight),
                child: _buildReaderCommentCloud(
                  context,
                  segment,
                  comments: comments,
                ),
              ),
              const SizedBox(height: 6),
              _buildReaderCommentComposer(context, segment),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReaderCommentTailPage(
    BuildContext context,
    ReaderPageData page, {
    double minHeight = 0,
  }) {
    final List<ChapterComment> comments = _controller.commentsFor(page);
    final Size screenSize = MediaQuery.sizeOf(context);
    final bool isPagedCommentPage = minHeight > 0;
    final double panelMaxHeight = isPagedCommentPage
        ? minHeight
        : screenSize.height;
    final double commentCloudMaxHeight = panelMaxHeight > 188
        ? panelMaxHeight - 108
        : 80;
    final Widget commentSection = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: commentCloudMaxHeight),
            child: _buildReaderCommentCloud(context, page, comments: comments),
          ),
        ),
        const SizedBox(height: 6),
        _buildReaderCommentComposer(context, page),
      ],
    );
    final bool hasNextChapter = page.nextHref.trim().isNotEmpty;
    if (isPagedCommentPage) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: SizedBox(
          height: minHeight,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const SizedBox(height: 12),
              Flexible(child: commentSection),
              if (hasNextChapter)
                _buildReaderNextChapterFooter(context, page)
              else
                const SizedBox(height: 16),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: screenSize.height),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SizedBox(height: 12),
            Flexible(child: commentSection),
            if (hasNextChapter)
              _buildReaderNextChapterFooter(context, page)
            else
              const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  bool _isUserDrivenScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    return switch (notification) {
      ScrollStartNotification(:final DragStartDetails? dragDetails) =>
        dragDetails != null,
      ScrollUpdateNotification(:final DragUpdateDetails? dragDetails) =>
        dragDetails != null,
      OverscrollNotification(:final DragUpdateDetails? dragDetails) =>
        dragDetails != null,
      _ => false,
    };
  }

  void _handleScrollLifecycle(ScrollNotification notification) {
    if (notification.depth != 0) return;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _controller.cancelAutoTurn();
      _controller.hideChapterControls();
      return;
    }
    if (notification is ScrollEndNotification &&
        notification.dragDetails != null) {
      _controller.restartAutoTurnAfterScroll();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? _) {
        // 连续阅读时当前章由滚动位置决定，可能比上层传进来的 page 更新。
        final ReaderPageData page = _controller.page ?? widget.page;
        final ColorScheme colorScheme = Theme.of(context).colorScheme;
        final bool isZoomed = _controller.zoomScale > 1.01;

        Widget readerContent = _controller.isBook
            ? _buildBook(context, page)
            : (_controller.isPaged
                  ? _buildReaderPagedContent(context, page)
                  : _buildReaderScrollableContent(context, page));

        if (PlatformCapabilities.isDesktop) {
          readerContent = ScrollConfiguration(
            behavior: const _ReaderMouseDragScrollBehavior(),
            child: readerContent,
          );
        }

        readerContent = ClipRect(
          child: Transform.translate(
            offset: isZoomed
                ? Offset(_controller.panOffsetX, _controller.panOffsetY)
                : Offset.zero,
            child: Transform.scale(
              scale: _controller.zoomScale,
              alignment: Alignment.center,
              child: readerContent,
            ),
          ),
        );

        if (isZoomed) {
          final Size screenSize = MediaQuery.sizeOf(context);
          final double maxPanX =
              screenSize.width * (_controller.zoomScale - 1) / 2;
          final double maxPanY =
              screenSize.height * (_controller.zoomScale - 1) / 2;
          readerContent = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: _controller.isZoomGestureLocked
                ? null
                : _controller.toggleChapterControls,
            dragStartBehavior: DragStartBehavior.down,
            onPanUpdate: (DragUpdateDetails details) {
              if (_controller.isScaleGestureActive) return;
              final double dy = details.delta.dy;
              final double proposedPanY = _controller.panOffsetY + dy;
              final double clampedPanY = proposedPanY.clamp(-maxPanY, maxPanY);
              final double consumedDy = clampedPanY - _controller.panOffsetY;
              final double remainingDy = dy - consumedDy;
              double overscrollDy = 0;
              if (!_controller.isBook && remainingDy.abs() > 0.5) {
                final ScrollController vc = _controller.isPaged
                    ? _controller.pagedScrollControllerFor(
                        _controller.currentPageIndex,
                      )
                    : _controller.scrollController;
                if (vc.hasClients) {
                  final double oldOffset = vc.offset;
                  final double rawOffset =
                      oldOffset - remainingDy / _controller.zoomScale;
                  final double newOffset = rawOffset.clamp(
                    vc.position.minScrollExtent,
                    vc.position.maxScrollExtent,
                  );
                  vc.jumpTo(newOffset);
                  final double scrolledScreen =
                      (oldOffset - newOffset) * _controller.zoomScale;
                  overscrollDy = remainingDy - scrolledScreen;
                } else {
                  overscrollDy = remainingDy;
                }
              }
              if (overscrollDy.abs() > 0.5) {
                _controller.handleZoomedOverscroll(page, overscrollDy);
              }
              _controller.updatePanOffset(
                x: (_controller.panOffsetX + details.delta.dx).clamp(
                  -maxPanX,
                  maxPanX,
                ),
                y: clampedPanY,
              );
            },
            onPanEnd: (DragEndDetails details) {
              if (_controller.isScaleGestureActive || _controller.isBook) {
                return;
              }
              _controller.handleZoomedPanEnd(page);
              final ScrollController vc = _controller.isPaged
                  ? _controller.pagedScrollControllerFor(
                      _controller.currentPageIndex,
                    )
                  : _controller.scrollController;
              if (vc.hasClients) {
                final double vy = details.velocity.pixelsPerSecond.dy;
                if (vy.abs() > 100) {
                  final double targetOffset =
                      (vc.offset - vy * 0.25 / _controller.zoomScale).clamp(
                        vc.position.minScrollExtent,
                        vc.position.maxScrollExtent,
                      );
                  unawaited(
                    vc.animateTo(
                      targetOffset,
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                    ),
                  );
                }
              }
            },
            child: readerContent,
          );
        } else {
          readerContent = GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: _controller.isZoomGestureLocked
                ? null
                : _handleReaderTapUp,
            onDoubleTap: _controller.isZoomGestureLocked
                ? null
                : _controller.toggleChapterControls,
            child: readerContent,
          );
        }

        final double topSafeInset = _readerTopSafeInset(context);

        return AnimatedOpacity(
          opacity: widget.isExitTransitionActive ? 0 : 1,
          duration: _readerExitFadeDuration,
          curve: Curves.easeOutCubic,
          child: IgnorePointer(
            ignoring: widget.isExitTransitionActive,
            child: Scaffold(
              backgroundColor: colorScheme.surfaceContainerLowest,
              body: SizedBox(
                key: _controller.viewportKey,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    Positioned(
                      top: topSafeInset,
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ReaderPinchZoomDetector(
                        onPinchStart: _controller.handlePinchZoomStart,
                        onPinchUpdate: _controller.handlePinchZoomUpdate,
                        onPinchEnd: _controller.handlePinchZoomEnd,
                        child: readerContent,
                      ),
                    ),
                    _buildReaderOverlay(
                      context,
                      page,
                      topSafeInset: topSafeInset,
                    ),
                    _buildReaderTopHudOverlay(context, page),
                    _buildReaderBottomHudOverlay(context, page),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ReaderClockLabel extends StatefulWidget {
  const _ReaderClockLabel();

  @override
  State<_ReaderClockLabel> createState() => _ReaderClockLabelState();
}

class _ReaderClockLabelState extends State<_ReaderClockLabel> {
  Timer? _timer;
  late String _label;

  @override
  void initState() {
    super.initState();
    _label = _formatNow();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _label = _formatNow();
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static String _formatNow() {
    final DateTime now = DateTime.now();
    final String hour = now.hour.toString().padLeft(2, '0');
    final String minute = now.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return ReaderStatusLabel(label: _label, fontSize: 12);
  }
}
