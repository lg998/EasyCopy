import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderSliver;
import 'package:reader/models/app_preferences.dart';
import 'package:reader/models/chapter_comment.dart';
import 'package:reader/models/page_models.dart';
import 'package:reader/reader/internal/reader_environment.dart';
import 'package:reader/reader/internal/reader_restore_target.dart';
import 'package:reader/reader/reader_controller/chapter_boundary.dart';
import 'package:reader/reader/reader_controller/comments.dart';
import 'package:reader/reader/reader_controller/zoom_state.dart';
import 'package:reader/services/app_preferences_controller.dart';
import 'package:reader/services/debug_trace.dart';
import 'package:reader/services/deferred_viewport_coordinator.dart';
import 'package:reader/services/image_cache.dart';
import 'package:reader/services/reader_history_recorder.dart';
import 'package:reader/services/reader_platform_bridge.dart';
import 'package:reader/services/reader_progress_store.dart';
import 'package:reader/services/site_api_client.dart';
import 'package:reader/services/site_session.dart';

const double _pullTriggerDistance = 120;
const double _continuousPullTriggerDistance = 266;
const double _pagedTriggerDistance = 90;
const double _readerScrollProgressStep = 96;
const double _readerPagedProgressStep = 48;

typedef ReaderChapterNavigationCallback =
    Future<void> Function(
      String href, {
      String prevHref,
      String nextHref,
      String catalogHref,
      bool openAtEnd,
    });

/// 连续阅读时预加载相邻章节的数据（不切换路由）。
typedef ReaderAdjacentChapterLoader =
    Future<ReaderPageData?> Function(
      String href, {
      required String prevHref,
      required String catalogHref,
    });

/// 连续阅读最多保留当前章之前的章节数，更早的章节会被移出列表并释放图片缓存。
const int _continuousRetainedChaptersBehind = 1;

/// 距离列表底部不足这么多屏时开始预加载下一章。
const double _continuousPreloadViewports = 2.5;

String readerChapterIdForPage(ReaderPageData page) {
  final Uri uri = Uri.parse(page.uri);
  final List<String> segments = uri.pathSegments;
  final int chapterIndex = segments.indexOf('chapter');
  if (chapterIndex < 0 || chapterIndex + 1 >= segments.length) {
    return '';
  }
  return segments[chapterIndex + 1].trim();
}

class ReaderController extends ChangeNotifier {
  ReaderController({
    required this.preferencesController,
    required this.progressStore,
    required this.platformBridge,
    required this.apiClient,
    required this.session,
    required this.historyRecorder,
    required this.onRequestChapterNavigation,
    required this.onRequestAuth,
    required this.onLogoutForExpiredSession,
    required this.onShowMessage,
    this.loadAdjacentChapter,
    this.onActiveChapterChanged,
  }) {
    _comments = ReaderCommentsController(
      apiClient: apiClient,
      session: session,
      preferences: () => preferences,
      currentPage: () => _page,
      isChapterActive: _isChapterIdRetained,
      chapterIdForPage: readerChapterIdForPage,
      isDisposed: () => _disposed,
      notify: notifyListeners,
      onRequestAuth: onRequestAuth,
      onLogoutForExpiredSession: onLogoutForExpiredSession,
      onShowMessage: onShowMessage,
    );
    _zoom = ReaderZoomController();
    _chapterBoundary = ReaderChapterBoundaryController(
      triggerDistance: () => _nextChapterTriggerDistance,
      readingDirection: () => preferences.readingDirection,
      isZoomLocked: () => isZoomGestureLocked,
      flushProgress: flushProgressPersistence,
      onRequestChapterNavigation: onRequestChapterNavigation,
      notify: () {
        if (!_disposed) {
          notifyListeners();
        }
      },
    );
  }

  final AppPreferencesController preferencesController;
  final ReaderProgressStore progressStore;
  final ReaderPlatformBridge platformBridge;
  final SiteApiClient apiClient;
  final SiteSession session;
  final ReaderHistoryRecorder historyRecorder;
  final ReaderChapterNavigationCallback onRequestChapterNavigation;
  final Future<void> Function() onRequestAuth;
  final Future<void> Function() onLogoutForExpiredSession;
  final void Function(String message) onShowMessage;

  /// 连续阅读：加载下一章数据。为空时不启用连续阅读。
  final ReaderAdjacentChapterLoader? loadAdjacentChapter;

  /// 连续阅读：滚动进入另一章后通知上层同步当前章节（历史、路由）。
  final void Function(ReaderPageData page)? onActiveChapterChanged;

  /// 连续阅读：章节被移出列表后，由界面层释放这些图片的内存缓存。
  void Function(List<ReaderPageData> evicted)? onSegmentsEvicted;

  PageController pageController = PageController();
  Future<void> Function(int index)? turnBook;
  double Function(int index)? imageOffset;
  final ScrollController scrollController = ScrollController();
  final GlobalKey viewportKey = GlobalKey();
  final Map<int, ScrollController> _pagedScrollControllers =
      <int, ScrollController>{};

  /// 每章图片条目的 key（按章节 uri 分组），连续阅读时列表里会同时有多章。
  final Map<String, Map<int, GlobalKey>> _segmentItemKeys =
      <String, Map<int, GlobalKey>>{};
  final Map<String, GlobalKey> _segmentSliverKeys = <String, GlobalKey>{};
  final Map<String, GlobalKey> _segmentCommentKeys = <String, GlobalKey>{};
  final Map<String, double> _segmentBases = <String, double>{};
  final Map<String, double> _imageAspectRatios = <String, double>{};

  /// 连续阅读列表里的章节，按阅读顺序排列；单章模式下只有当前章。
  List<ReaderPageData> _segments = const <ReaderPageData>[];

  /// 已通知上层、等待上层回传的章节，回传时不能当成新的跳转去重置列表。
  final List<String> _pendingCommitUris = <String>[];
  int _scrollSession = 0;
  int _segmentGeneration = 0;
  bool _isAppendingSegment = false;
  String _appendError = '';
  double _segmentTopPadding = 0;
  bool _suppressScrollTracking = false;
  final DeferredViewportCoordinator restoreCoordinator =
      DeferredViewportCoordinator();
  late final ReaderCommentsController _comments;
  late final ReaderZoomController _zoom;
  late final ReaderChapterBoundaryController _chapterBoundary;

  StreamSubscription<int>? _batterySubscription;
  StreamSubscription<ReaderVolumeKeyAction>? _volumeKeySubscription;
  Timer? _progressDebounce;
  Timer? _autoTurnTimer;
  bool _disposed = false;

  ReaderPageData? _page;
  int _currentPageIndex = 0;
  int _visibleImageIndex = 0;
  ReaderPosition? _lastPersistedPosition;
  ReaderPosition? _lastScheduledProgressPosition;
  AppliedReaderEnvironment? _appliedEnvironment;
  ReaderPreferences? _lastObservedPreferences;
  bool _presentationSyncScheduled = false;
  bool _visibleIndexUpdateQueued = false;
  bool _wide = false;
  DeferredViewportTicket? _positionTicket;

  bool _isSettingsOpen = false;
  bool _isChapterControlsVisible = false;
  int? _batteryLevel;

  ReaderPageData? get page => _page;

  ReaderPreferences get preferences => preferencesController.readerPreferences;

  bool _usesBook(ReaderPreferences prefs) => prefs.bookMode && _wide;

  bool get isBook => _usesBook(preferences);

  bool get isPaged => isBook || preferences.isPaged;

  /// 从上到下滚动阅读且开启了连续阅读。
  bool get isContinuous =>
      !isPaged && preferences.continuousChapters && loadAdjacentChapter != null;

  /// 当前列表里的章节（单章模式下只有当前章）。
  List<ReaderPageData> get segments {
    if (_segments.isNotEmpty) return _segments;
    final ReaderPageData? page = _page;
    return page == null ? const <ReaderPageData>[] : <ReaderPageData>[page];
  }

  /// 列表重建标识：换章或重置时变化，追加 / 移除章节时保持不变以维持滚动位置。
  int get scrollSession => _scrollSession;

  bool get isAppendingSegment => _isAppendingSegment;

  String get appendError => _appendError;

  /// 列表顶部留白，界面每次构建时同步，用于把章节偏移换算成单章坐标。
  set segmentTopPadding(double value) => _segmentTopPadding = value;

  Map<int, GlobalKey> get _imageItemKeys => _itemKeysFor(_page?.uri ?? '');

  Map<int, GlobalKey> _itemKeysFor(String uri) =>
      _segmentItemKeys.putIfAbsent(uri, () => <int, GlobalKey>{});

  GlobalKey imageItemKeyForSegment(String uri, int index) =>
      _itemKeysFor(uri).putIfAbsent(index, GlobalKey.new);

  GlobalKey segmentSliverKeyFor(String uri) =>
      _segmentSliverKeys.putIfAbsent(uri, GlobalKey.new);

  GlobalKey commentSectionKeyForSegment(String uri) =>
      _segmentCommentKeys.putIfAbsent(uri, GlobalKey.new);

  bool _isChapterIdRetained(String chapterId) {
    if (chapterId.isEmpty) return false;
    final ReaderPageData? current = _page;
    if (current != null && readerChapterIdForPage(current) == chapterId) {
      return true;
    }
    return _segments.any(
      (ReaderPageData segment) => readerChapterIdForPage(segment) == chapterId,
    );
  }

  void _retainActiveCommentEntries() {
    final Set<String> retainedIds = <String>{
      if (_page != null) readerChapterIdForPage(_page!),
      for (final ReaderPageData segment in _segments)
        readerChapterIdForPage(segment),
    }..remove('');
    _comments.retainChapters(retainedIds);
  }

  bool get _loadingPosition =>
      _positionTicket != null && restoreCoordinator.isActive(_positionTicket!);

  void setViewport(Size size) {
    final bool wide = size.width > size.height;
    if (_wide == wide) return;
    final ReaderPageData? page = _page;
    if (!preferences.bookMode || page == null || _loadingPosition) {
      _wide = wide;
      return;
    }
    final ReaderRestoreTarget? target = captureCurrentRestoreTarget(
      page,
      preferences: preferences,
    );
    _wide = wide;
    final DeferredViewportTicket ticket = restoreCoordinator.beginRequest();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed ||
          _page?.uri != page.uri ||
          !restoreCoordinator.isActive(ticket)) {
        return;
      }
      _handlePageLoaded(
        page,
        previousUri: page.uri,
        forceRestore: true,
        preferredRestoreTarget: target,
      );
    });
  }

  int get currentPageIndex => _currentPageIndex;

  int get visibleImageIndex => _visibleImageIndex;

  bool get isSettingsOpen => _isSettingsOpen;

  bool get isChapterControlsVisible => _isChapterControlsVisible;

  TextEditingController get commentController => _comments.textController;

  ScrollController get commentScrollController => _comments.scrollController;

  bool get isNextChapterLoading => _chapterBoundary.isLoading;

  bool get isScaleGestureActive => _zoom.isScaleGestureActive;

  bool get isZoomGestureLocked => _zoom.isLocked;

  double get zoomScale => _zoom.scale;

  double get panOffsetX => _zoom.panOffsetX;

  double get panOffsetY => _zoom.panOffsetY;

  double get previousChapterPullDistance => _chapterBoundary.previousDistance;

  double get nextChapterPullDistance => _chapterBoundary.nextDistance;

  bool get previousChapterPullReady => _chapterBoundary.previousReady;

  bool get nextChapterPullReady => _chapterBoundary.nextReady;

  double get chapterPullTriggerDistance => _nextChapterTriggerDistance;

  double get _nextChapterTriggerDistance => isPaged
      ? _pagedTriggerDistance
      // 连续阅读只剩顶部下拉回上一章，保持较长距离防止往回快速滑动时误触。
      : (isContinuous ? _continuousPullTriggerDistance : _pullTriggerDistance);

  List<ChapterComment> get chapterComments => _comments.items;

  String get commentsChapterId => _comments.chapterId;

  String get commentsError => _comments.error;

  bool get isCommentsLoading => _comments.isLoading;

  bool get isCommentSubmitting => _comments.isSubmitting;

  List<ChapterComment> commentsFor(ReaderPageData page) =>
      _comments.itemsFor(page);

  String commentsErrorFor(ReaderPageData page) => _comments.errorFor(page);

  bool isCommentsLoadingFor(ReaderPageData page) =>
      _comments.isLoadingFor(page);

  bool isCommentSubmittingFor(ReaderPageData page) =>
      _comments.isSubmittingFor(page);

  TextEditingController commentControllerFor(ReaderPageData page) =>
      _comments.textControllerFor(page);

  ScrollController commentScrollControllerFor(ReaderPageData page) =>
      _comments.scrollControllerFor(page);

  int? get batteryLevel => _batteryLevel;

  Map<String, double> get imageAspectRatios => _imageAspectRatios;

  ScrollController pagedScrollControllerFor(int pageIndex) {
    return _pagedScrollControllers.putIfAbsent(pageIndex, () {
      final ScrollController controller = ScrollController();
      controller.addListener(() => _handlePagedInnerScroll(pageIndex));
      return controller;
    });
  }

  GlobalKey imageItemKeyFor(int index) {
    return _imageItemKeys.putIfAbsent(index, GlobalKey.new);
  }

  bool shouldShowChapterComments(ReaderPageData page) {
    return preferences.showChapterComments &&
        readerChapterIdForPage(page).isNotEmpty;
  }

  bool shouldShowCommentTailPage(ReaderPageData page) {
    return !isContinuous && shouldShowChapterComments(page);
  }

  int readerPagedPageCount(ReaderPageData page) {
    return page.imageUrls.length + (shouldShowCommentTailPage(page) ? 1 : 0);
  }

  ReaderRestoreTarget? captureCurrentRestoreTarget(
    ReaderPageData page, {
    required ReaderPreferences preferences,
  }) {
    final bool book = _usesBook(preferences);
    if (book || preferences.isPaged) {
      final int maxPageIndex = math.max(0, readerPagedPageCount(page) - 1);
      final int pageIndex = _currentPageIndex.clamp(0, maxPageIndex);
      final ScrollController? controller = _pagedScrollControllers[pageIndex];
      return ReaderRestoreTarget(
        position: ReaderPosition.paged(
          pageIndex: pageIndex,
          pageOffset: !book && controller != null && controller.hasClients
              ? controller.offset
              : 0,
        ),
        visibleImageIndex: page.imageUrls.isEmpty
            ? null
            : (pageIndex >= page.imageUrls.length
                  ? page.imageUrls.length - 1
                  : pageIndex),
      );
    }
    final double? offset = scrollController.hasClients
        ? math.max(0, _relativeScrollOffset(page.uri)).toDouble()
        : null;
    return ReaderRestoreTarget(
      position: offset == null ? null : ReaderPosition.scroll(offset: offset),
      visibleImageIndex: page.imageUrls.isEmpty
          ? null
          : _visibleImageIndex.clamp(0, page.imageUrls.length - 1),
    );
  }

  void attachPlatformSubscriptions() {
    if (platformBridge.isAndroidSupported) {
      _batterySubscription = platformBridge.batteryStream.listen((int level) {
        if (_disposed || _batteryLevel == level) {
          return;
        }
        _batteryLevel = level;
        notifyListeners();
      });
      _volumeKeySubscription = platformBridge.volumeKeyEventStream.listen(
        _handleVolumeKeyAction,
      );
    }
    scrollController.addListener(_handleScroll);
    preferencesController.addListener(_handlePreferencesChanged);
    _lastObservedPreferences = preferencesController.readerPreferences;
  }

  void setPage(
    ReaderPageData page, {
    String? previousUri,
    bool forceRestore = false,
    ReaderRestoreTarget? preferredRestoreTarget,
    bool openAtEnd = false,
  }) {
    // 连续阅读滚动进入下一章后上层回传的同一章：只同步数据，不重置列表。
    final int pendingIndex = _pendingCommitUris.indexOf(page.uri);
    if (pendingIndex >= 0 && !forceRestore) {
      _pendingCommitUris.removeRange(0, pendingIndex + 1);
      _replaceSegment(page);
      notifyListeners();
      return;
    }
    _page = page;
    if (previousUri == page.uri && !forceRestore) {
      _replaceSegment(page);
    }
    _handlePageLoaded(
      page,
      previousUri: previousUri,
      forceRestore: forceRestore,
      preferredRestoreTarget: preferredRestoreTarget,
      openAtEnd: openAtEnd,
    );
    notifyListeners();
  }

  Future<void> flushProgressPersistence() async {
    _progressDebounce?.cancel();
    _progressDebounce = null;
    _lastScheduledProgressPosition = null;
    await _persistCurrentProgress();
  }

  Future<void> restoreDefaultEnvironment() async {
    await platformBridge.restoreDefaultPresentation();
    await platformBridge.setKeepScreenOn(false);
    await platformBridge.setVolumePagingEnabled(false);
    _appliedEnvironment = const AppliedReaderEnvironment.standard();
  }

  @override
  void dispose() {
    _disposed = true;
    AppImageCaches.clearReaderPrefetchWindow();
    _progressDebounce?.cancel();
    _autoTurnTimer?.cancel();
    _batterySubscription?.cancel();
    _volumeKeySubscription?.cancel();
    preferencesController.removeListener(_handlePreferencesChanged);
    scrollController.removeListener(_handleScroll);
    final List<ScrollController> pagedControllers = _pagedScrollControllers
        .values
        .toList(growable: false);
    _pagedScrollControllers.clear();
    for (final ScrollController controller in pagedControllers) {
      controller.dispose();
    }
    pageController.dispose();
    scrollController.dispose();
    _comments.dispose();
    super.dispose();
  }

  void toggleChapterControls() {
    if (_disposed) return;
    _isChapterControlsVisible = !_isChapterControlsVisible;
    notifyListeners();
  }

  void hideChapterControls() {
    if (_disposed || !_isChapterControlsVisible) return;
    _isChapterControlsVisible = false;
    notifyListeners();
  }

  void setSettingsSheetOpen(bool open) {
    if (_isSettingsOpen == open) return;
    _isSettingsOpen = open;
    _scheduleReaderPresentationSync();
    notifyListeners();
  }

  void noteUserInteraction() {
    restoreCoordinator.noteUserInteraction();
  }

  int _stepIndex(int direction) {
    if (!isBook) return _currentPageIndex + direction;
    final int count = _page!.imageUrls.length;
    if (direction > 0) {
      return _currentPageIndex >= count
          ? _currentPageIndex + 1
          : math.min((_currentPageIndex ~/ 2 + 1) * 2, count);
    }
    return _currentPageIndex >= count
        ? (count == 0 ? -1 : (count - 1) ~/ 2 * 2)
        : (_currentPageIndex ~/ 2 - 1) * 2;
  }

  Future<void> stepForward() async {
    if (isZoomGestureLocked) return;
    restoreCoordinator.noteUserInteraction();
    if (isPaged) {
      final ReaderPageData? page = _page;
      if (page == null) return;
      final int totalPageCount = readerPagedPageCount(page);
      final int nextPageIndex = _stepIndex(1);
      if (nextPageIndex >= totalPageCount) {
        if (page.nextHref.trim().isNotEmpty) {
          await triggerNextChapter(page);
        } else {
          onShowMessage('已经是最后一话');
        }
        return;
      }
      await animateToPage(nextPageIndex);
      return;
    }
    if (!scrollController.hasClients) return;
    final double viewportExtent = scrollController.position.viewportDimension;
    final double maxExtent = scrollController.position.maxScrollExtent;
    final double nextOffset = (scrollController.offset + viewportExtent)
        .clamp(0, maxExtent)
        .toDouble();
    if ((nextOffset - scrollController.offset).abs() < 1) {
      final ReaderPageData? page = _page;
      if (isContinuous &&
          _segments.isNotEmpty &&
          _segments.last.nextHref.trim().isNotEmpty) {
        // 连续阅读：下一章会接在后面，不跳转。
        if (!_isAppendingSegment) unawaited(retryAppendNextSegment());
        return;
      }
      if (page != null && page.nextHref.trim().isNotEmpty) {
        await triggerNextChapter(page);
      }
      return;
    }
    await scrollController.animateTo(
      nextOffset,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    _restartAutoTurn();
  }

  Future<void> stepBackward() async {
    if (isZoomGestureLocked) return;
    restoreCoordinator.noteUserInteraction();
    if (isPaged) {
      if (_page == null) return;
      final int previousPageIndex = _stepIndex(-1);
      if (previousPageIndex < 0) {
        final ReaderPageData? page = _page;
        if (page != null && page.prevHref.trim().isNotEmpty) {
          await triggerPreviousChapter(page);
        } else {
          onShowMessage('已经是第一话');
        }
        return;
      }
      await animateToPage(previousPageIndex);
      return;
    }
    if (!scrollController.hasClients) return;
    final double viewportExtent = scrollController.position.viewportDimension;
    final double previousOffset = (scrollController.offset - viewportExtent)
        .clamp(0, scrollController.position.maxScrollExtent)
        .toDouble();
    if ((previousOffset - scrollController.offset).abs() < 1) return;
    await scrollController.animateTo(
      previousOffset,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    _restartAutoTurn();
  }

  Future<void> scrollCurrentPageDown() => _scrollCurrentPageBy(1);

  Future<void> scrollCurrentPageUp() => _scrollCurrentPageBy(-1);

  Future<void> _scrollCurrentPageBy(int direction) async {
    if (isZoomGestureLocked || isBook) return;
    restoreCoordinator.noteUserInteraction();
    final ScrollController? controller = isPaged
        ? _pagedScrollControllers[_currentPageIndex]
        : scrollController;
    if (controller == null || !controller.hasClients) return;
    final ScrollPosition position = controller.position;
    final double delta = position.viewportDimension * 0.72 * direction;
    final double targetOffset = (controller.offset + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((targetOffset - controller.offset).abs() < 1) return;
    await controller.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
    );
    _restartAutoTurn();
  }

  Future<void> animateToPage(int pageIndex) async {
    if (isBook) {
      await turnBook?.call(pageIndex);
      _restartAutoTurn();
      return;
    }
    if (!pageController.hasClients) return;
    if (preferences.disablePageTransitionAnimation) {
      pageController.jumpToPage(pageIndex);
      if (_currentPageIndex != pageIndex) {
        handlePageChanged(pageIndex);
      }
      return;
    }
    await pageController.animateToPage(
      pageIndex,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    _restartAutoTurn();
  }

  void seekToImageIndex({
    required ReaderPageData page,
    required int imageIndex,
    required double estimatedScrollOffset,
  }) {
    if (isZoomGestureLocked || page.imageUrls.isEmpty) return;
    final int clampedIndex = imageIndex.clamp(0, page.imageUrls.length - 1);
    final DeferredViewportTicket ticket = restoreCoordinator.beginRequest();

    if (isPaged) {
      _jumpToPage(page.uri, clampedIndex, attempts: 8, ticket: ticket);
      if (!isBook) {
        _jumpPageOffset(
          page.uri,
          clampedIndex,
          offset: 0,
          attempts: 8,
          ticket: ticket,
        );
      }
      return;
    }
    _jumpToOffset(page.uri, estimatedScrollOffset, attempts: 8, ticket: ticket);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToImageIndex(
        page.uri,
        clampedIndex,
        attempts: 8,
        ticket: ticket,
        alignment: 0,
      );
    });
  }

  void cancelAutoTurn() {
    _autoTurnTimer?.cancel();
    _autoTurnTimer = null;
  }

  void restartAutoTurnAfterScroll() {
    _restartAutoTurn();
  }

  void _scheduleReaderPresentationSync() {
    if (_presentationSyncScheduled) return;
    _presentationSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _presentationSyncScheduled = false;
      if (_disposed) return;
      unawaited(_applyEnvironment(_page));
    });
  }

  Future<void> _applyEnvironment(ReaderPageData? page) async {
    final AppliedReaderEnvironment nextEnvironment = page == null
        ? const AppliedReaderEnvironment.standard()
        : AppliedReaderEnvironment.reader(
            orientation: preferences.screenOrientation,
            fullscreen: preferences.fullscreen,
            keepScreenOn: preferences.keepScreenOn,
            volumePagingEnabled:
                platformBridge.isAndroidSupported &&
                preferences.useVolumeKeysForPaging,
          );
    if (_appliedEnvironment != nextEnvironment) {
      if (page == null) {
        await restoreDefaultEnvironment();
      } else {
        await platformBridge.applyReaderPresentation(
          orientation: nextEnvironment.orientation,
          fullscreen: nextEnvironment.fullscreen,
        );
        await platformBridge.setKeepScreenOn(nextEnvironment.keepScreenOn);
        await platformBridge.setVolumePagingEnabled(
          nextEnvironment.volumePagingEnabled,
        );
        _appliedEnvironment = nextEnvironment;
      }
    }

    if (page == null) {
      _autoTurnTimer?.cancel();
      _autoTurnTimer = null;
      return;
    }
    _restartAutoTurn();
  }

  void _restartAutoTurn() {
    _autoTurnTimer?.cancel();
    final ReaderPageData? page = _page;
    if (page == null ||
        preferences.autoPageTurnSeconds <= 0 ||
        _isSettingsOpen ||
        isZoomGestureLocked) {
      return;
    }
    _autoTurnTimer = Timer(
      Duration(seconds: preferences.autoPageTurnSeconds),
      () async {
        if (_disposed || _page == null) return;
        if (isPaged) {
          final int totalPageCount = readerPagedPageCount(page);
          final int nextPageIndex = _stepIndex(1);
          if (nextPageIndex >= totalPageCount) return;
          await animateToPage(nextPageIndex);
          return;
        }
        if (!scrollController.hasClients) return;
        final double maxExtent = scrollController.position.maxScrollExtent;
        final double viewportExtent =
            scrollController.position.viewportDimension;
        final double nextOffset = (scrollController.offset + viewportExtent)
            .clamp(0, maxExtent)
            .toDouble();
        if ((nextOffset - scrollController.offset).abs() < 1) return;
        await scrollController.animateTo(
          nextOffset,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
        _restartAutoTurn();
      },
    );
  }

  void _handlePageLoaded(
    ReaderPageData page, {
    String? previousUri,
    bool forceRestore = false,
    ReaderRestoreTarget? preferredRestoreTarget,
    bool openAtEnd = false,
  }) {
    unawaited(_markChapterVisited(page));
    final bool changedPage = previousUri != page.uri;
    if (changedPage || forceRestore || _segments.isEmpty) {
      _resetSegments(page);
    }
    if (changedPage || forceRestore) {
      _chapterBoundary.reset();
      _resetZoomState();
    }
    if (changedPage) {
      _currentPageIndex = 0;
      _visibleImageIndex = 0;
      _lastScheduledProgressPosition = null;
      _visibleIndexUpdateQueued = false;
      _isChapterControlsVisible = false;
      _disposePagedScrollControllers();
      _imageAspectRatios.clear();
      if (!isPaged && scrollController.hasClients) {
        scrollController.jumpTo(0);
      }
    }
    _comments.prepare(page, resetForNewChapter: changedPage);
    _scheduleReaderPresentationSync();
    if (changedPage || forceRestore) {
      unawaited(
        _restorePosition(
          page,
          resetControllers: changedPage || forceRestore,
          preferredRestoreTarget: preferredRestoreTarget,
          openAtEnd: openAtEnd,
        ),
      );
    } else {
      _refreshReaderPrefetchWindow(page, _visibleImageIndex);
    }
  }

  void _refreshReaderPrefetchWindow(
    ReaderPageData page,
    int currentImageIndex,
  ) {
    List<String> urls = page.imageUrls;
    // 连续阅读时，本章快读完就顺带预取下一章开头的图片。
    final int segmentIndex = _segmentIndexOf(page.uri);
    if (isContinuous &&
        segmentIndex >= 0 &&
        segmentIndex + 1 < _segments.length) {
      urls = <String>[...urls, ..._segments[segmentIndex + 1].imageUrls];
    }
    AppImageCaches.replaceReaderPrefetchWindow(
      readerPrefetchUrlsAfter(urls, currentIndex: currentImageIndex),
      referer: page.uri,
    );
  }

  int _segmentIndexOf(String uri) =>
      _segments.indexWhere((ReaderPageData segment) => segment.uri == uri);

  /// 重新开始一个只含 [page] 的列表（换章、强制恢复位置时）。
  void _resetSegments(ReaderPageData page) {
    _segmentGeneration += 1;
    _scrollSession += 1;
    _segments = <ReaderPageData>[page];
    _pendingCommitUris.clear();
    _segmentItemKeys.clear();
    _segmentSliverKeys.clear();
    _segmentCommentKeys.clear();
    _segmentBases.clear();
    _isAppendingSegment = false;
    _appendError = '';
    _retainActiveCommentEntries();
  }

  void _replaceSegment(ReaderPageData page) {
    final int index = _segmentIndexOf(page.uri);
    if (index >= 0 && !identical(_segments[index], page)) {
      _segments = List<ReaderPageData>.of(_segments)..[index] = page;
    }
    if (_page?.uri == page.uri) {
      _page = page;
    }
  }

  /// 某章在连续列表里的起点，换算成「单章列表」坐标：第一章为 0。
  ///
  /// 阅读进度按单章坐标保存，这样以后单独打开这一章也能回到同一位置。
  double _segmentBaseOffset(String uri) {
    if (_segments.length <= 1 || _segments.first.uri == uri) {
      return 0;
    }
    final RenderObject? renderObject = _segmentSliverKeys[uri]?.currentContext
        ?.findRenderObject();
    if (renderObject is RenderSliver && renderObject.attached) {
      try {
        final double base = math.max(
          0,
          renderObject.constraints.precedingScrollExtent - _segmentTopPadding,
        );
        _segmentBases[uri] = base;
        return base;
      } catch (_) {
        // 尚未完成首次布局时没有 constraints。
      }
    }
    return _segmentBases[uri] ?? 0;
  }

  double _relativeScrollOffset(String uri) {
    if (!scrollController.hasClients) return 0;
    return scrollController.offset - _segmentBaseOffset(uri);
  }

  /// 连续阅读：快到列表底部时预加载下一章并接在后面。
  void _maybeAppendNextSegment() {
    if (!isContinuous ||
        _isAppendingSegment ||
        _appendError.isNotEmpty ||
        _segments.isEmpty ||
        _loadingPosition ||
        !scrollController.hasClients) {
      return;
    }
    final ReaderPageData last = _segments.last;
    if (last.nextHref.trim().isEmpty || _page?.uri != last.uri) return;
    final ScrollPosition position = scrollController.position;
    if (!position.hasContentDimensions ||
        position.extentAfter >
            position.viewportDimension * _continuousPreloadViewports) {
      return;
    }
    unawaited(_appendNextSegment(last));
  }

  Future<void> retryAppendNextSegment() async {
    if (_segments.isEmpty) return;
    _appendError = '';
    await _appendNextSegment(_segments.last);
  }

  Future<void> _appendNextSegment(ReaderPageData last) async {
    final ReaderAdjacentChapterLoader? loader = loadAdjacentChapter;
    final String href = last.nextHref.trim();
    if (loader == null || href.isEmpty || _isAppendingSegment) return;
    final int generation = _segmentGeneration;
    _isAppendingSegment = true;
    _appendError = '';
    notifyListeners();
    ReaderPageData? next;
    String error = '';
    try {
      next = await loader(
        href,
        prevHref: last.uri,
        catalogHref: last.catalogHref,
      );
      if (next == null || next.imageUrls.isEmpty) {
        error = '下一章加载失败';
      }
    } catch (_) {
      error = '下一章加载失败';
    }
    if (_disposed || generation != _segmentGeneration) return;
    _isAppendingSegment = false;
    _appendError = error;
    if (next != null &&
        error.isEmpty &&
        identical(_segments.last, last) &&
        _segmentIndexOf(next.uri) < 0) {
      final ReaderPageData appended = next.mergeMissingNavigation(
        prevHref: last.uri,
        catalogHref: last.catalogHref,
      );
      _segments = <ReaderPageData>[..._segments, appended];
      _comments.prepare(appended, resetForNewChapter: false);
      final ReaderPageData? page = _page;
      if (page != null) {
        _refreshReaderPrefetchWindow(page, _visibleImageIndex);
      }
    }
    notifyListeners();
  }

  /// 连续阅读：滚动进入另一章，把它设为当前章（进度、历史、标题都跟着它走）。
  void _activateSegment(String uri, int imageIndex) {
    final int index = _segmentIndexOf(uri);
    final ReaderPageData? previous = _page;
    if (index < 0 || previous == null || previous.uri == uri) return;
    _progressDebounce?.cancel();
    _progressDebounce = null;
    unawaited(_persistProgressFor(previous));
    final ReaderPageData segment = _segments[index];
    _page = segment;
    _visibleImageIndex = imageIndex.clamp(
      0,
      math.max(0, segment.imageUrls.length - 1),
    );
    _lastPersistedPosition = null;
    _lastScheduledProgressPosition = null;
    _chapterBoundary.reset();
    unawaited(_markChapterVisited(segment));
    _comments.prepare(segment, resetForNewChapter: false);
    _refreshReaderPrefetchWindow(segment, _visibleImageIndex);
    _pendingCommitUris.add(segment.uri);
    onActiveChapterChanged?.call(segment);
    _scheduleProgressPersistence();
    if (!_disposed) notifyListeners();
  }

  /// 滚动停下后由界面调用：此时移除过早的章节不会打断手势。
  void handleScrollIdle() {
    if (_disposed) return;
    // 推迟到当前滚动状态切换完成之后，避免在 ScrollEnd 回调里嵌套 jumpTo。
    scheduleMicrotask(() {
      if (_disposed) return;
      _maybeEvictSegments();
      _maybeAppendNextSegment();
    });
  }

  /// 连续阅读：只保留当前章和前 [_continuousRetainedChaptersBehind] 章，
  /// 更早的章节移出列表，并修正滚动位置让画面保持不动。
  void _maybeEvictSegments() {
    if (!isContinuous || _segments.length < 2) return;
    final ReaderPageData? page = _page;
    if (page == null || !scrollController.hasClients) return;
    final int activeIndex = _segmentIndexOf(page.uri);
    final int keepFrom = activeIndex - _continuousRetainedChaptersBehind;
    if (activeIndex < 0 || keepFrom <= 0) return;
    final ScrollPosition position = scrollController.position;
    if (position.isScrollingNotifier.value) return;
    final ReaderPageData newFirst = _segments[keepFrom];
    final RenderObject? renderObject = _segmentSliverKeys[newFirst.uri]
        ?.currentContext
        ?.findRenderObject();
    if (renderObject is! RenderSliver || !renderObject.attached) return;
    final double removedExtent;
    try {
      removedExtent =
          renderObject.constraints.precedingScrollExtent - _segmentTopPadding;
    } catch (_) {
      return;
    }
    if (removedExtent <= 0) return;

    final List<ReaderPageData> evicted = _segments.sublist(0, keepFrom);
    _segments = _segments.sublist(keepFrom);
    for (final ReaderPageData segment in evicted) {
      _segmentItemKeys.remove(segment.uri);
      _segmentSliverKeys.remove(segment.uri);
      _segmentCommentKeys.remove(segment.uri);
      _segmentBases.remove(segment.uri);
      for (final String url in segment.imageUrls) {
        _imageAspectRatios.remove(url);
      }
    }
    _retainActiveCommentEntries();
    _segmentBases.clear();
    // 移除顶部内容的同一帧把偏移减掉相同高度，画面不会跳动。
    _suppressScrollTracking = true;
    try {
      position.jumpTo(math.max(0, position.pixels - removedExtent));
    } finally {
      _suppressScrollTracking = false;
    }
    onSegmentsEvicted?.call(evicted);
    DebugTrace.log('reader.continuous_evict', <String, Object?>{
      'evicted': evicted.length,
      'removedExtent': removedExtent.round(),
      'retained': _segments.length,
    });
    if (!_disposed) notifyListeners();
  }

  Future<void> _markChapterVisited(ReaderPageData page) {
    unawaited(historyRecorder.recordVisit(page));
    return progressStore.markChapterOpened(
      catalogHref: page.catalogHref,
      chapterHref: page.uri,
    );
  }

  Future<void> _restorePosition(
    ReaderPageData page, {
    required bool resetControllers,
    ReaderRestoreTarget? preferredRestoreTarget,
    bool openAtEnd = false,
  }) async {
    final DeferredViewportTicket ticket = restoreCoordinator.beginRequest();
    final bool restoreAtEnd =
        openAtEnd && resetControllers && preferredRestoreTarget == null;
    ReaderPosition? savedPosition;
    if (preferredRestoreTarget == null) {
      _positionTicket = ticket;
      try {
        savedPosition = await progressStore.readPosition(
          catalogHref: page.catalogHref,
          chapterHref: page.uri,
        );
      } finally {
        if (identical(_positionTicket, ticket)) _positionTicket = null;
      }
    }
    if (_disposed ||
        _page?.uri != page.uri ||
        !restoreCoordinator.isActive(ticket)) {
      return;
    }

    final ReaderRestoreTarget restoreTarget =
        preferredRestoreTarget ?? ReaderRestoreTarget(position: savedPosition);

    if (isPaged) {
      final int maxPageIndex = math.max(0, readerPagedPageCount(page) - 1);
      final int? preferredImageIndex = restoreTarget.imageIndexFor(page);
      final ReaderPosition? sourcePosition =
          restoreTarget.position ?? savedPosition;
      final int pageIndex = restoreAtEnd
          ? (page.imageUrls.isEmpty ? 0 : page.imageUrls.length - 1).clamp(
              0,
              maxPageIndex,
            )
          : (sourcePosition?.isPaged == true
                ? sourcePosition!.pageIndex.clamp(0, maxPageIndex)
                : (preferredImageIndex ?? 0));
      final double? pageOffset = isBook
          ? 0
          : restoreAtEnd
          ? null
          : (sourcePosition?.isPaged == true
                ? sourcePosition!.pageOffset
                : null);
      if (resetControllers) {
        _disposePagedScrollControllers();
        if (!isBook) _replacePageController(initialPage: pageIndex);
      }
      _lastPersistedPosition = ReaderPosition.paged(
        pageIndex: pageIndex,
        pageOffset: pageOffset ?? 0,
      );
      _currentPageIndex = pageIndex;
      _visibleImageIndex = page.imageUrls.isEmpty
          ? 0
          : (pageIndex >= page.imageUrls.length
                ? page.imageUrls.length - 1
                : pageIndex);
      _refreshReaderPrefetchWindow(page, _visibleImageIndex);
      if (!_disposed) notifyListeners();
      if (isBook) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isActiveRestore(ticket, pageUri: page.uri, isPaged: true)) return;
        _jumpToPage(page.uri, pageIndex, attempts: 10, ticket: ticket);
        _jumpPageOffset(
          page.uri,
          pageIndex,
          offset: pageOffset,
          attempts: 10,
          ticket: ticket,
        );
      });
      return;
    }

    final int? restoreImageIndex = restoreAtEnd
        ? (page.imageUrls.isEmpty ? null : page.imageUrls.length - 1)
        : restoreTarget.imageIndexFor(page);
    final ReaderPosition? sourcePosition =
        restoreTarget.position ?? savedPosition;
    final double? savedOffset = sourcePosition?.isScroll == true
        ? sourcePosition!.offset
        : null;
    _lastPersistedPosition = savedOffset == null
        ? null
        : ReaderPosition.scroll(offset: savedOffset);
    _refreshReaderPrefetchWindow(page, restoreImageIndex ?? 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isActiveRestore(ticket, pageUri: page.uri, isPaged: false)) return;
      if (restoreImageIndex != null) {
        _jumpToImageIndex(
          page.uri,
          restoreImageIndex,
          attempts: 10,
          ticket: ticket,
          alignment: restoreAtEnd
              ? 1
              : (preferredRestoreTarget == null &&
                        preferences.openingPosition == ReaderOpeningPosition.top
                    ? 0
                    : 0.5),
        );
      } else {
        _jumpToOffset(page.uri, savedOffset ?? 0, attempts: 10, ticket: ticket);
      }
      _scheduleVisibleIndexUpdate();
    });
  }

  bool _isActiveRestore(
    DeferredViewportTicket ticket, {
    required String pageUri,
    required bool isPaged,
  }) {
    return !_disposed &&
        restoreCoordinator.isActive(ticket) &&
        _page != null &&
        _page!.uri == pageUri &&
        this.isPaged == isPaged;
  }

  void _jumpToOffset(
    String pageUri,
    double? offset, {
    required int attempts,
    required DeferredViewportTicket ticket,
  }) {
    if (!_isActiveRestore(ticket, pageUri: pageUri, isPaged: false)) return;
    if (!scrollController.hasClients) {
      if (attempts > 0) {
        Future<void>.delayed(
          const Duration(milliseconds: 250),
          () => _jumpToOffset(
            pageUri,
            offset,
            attempts: attempts - 1,
            ticket: ticket,
          ),
        );
      }
      return;
    }
    final double maxExtent = scrollController.position.maxScrollExtent;
    final double targetOffset =
        _segmentBaseOffset(pageUri) +
        (offset ??
            (preferences.openingPosition == ReaderOpeningPosition.center
                ? (scrollController.position.viewportDimension * 0.5)
                : 0));
    if (targetOffset > maxExtent && attempts > 0) {
      Future<void>.delayed(
        const Duration(milliseconds: 250),
        () => _jumpToOffset(
          pageUri,
          offset,
          attempts: attempts - 1,
          ticket: ticket,
        ),
      );
      return;
    }
    final double clampedOffset = targetOffset.clamp(0, maxExtent).toDouble();
    scrollController.jumpTo(clampedOffset);
  }

  void _jumpToImageIndex(
    String pageUri,
    int imageIndex, {
    required int attempts,
    required DeferredViewportTicket ticket,
    required double alignment,
  }) {
    if (!_isActiveRestore(ticket, pageUri: pageUri, isPaged: false)) return;
    final BuildContext? itemContext = imageItemKeyFor(
      imageIndex,
    ).currentContext;
    if (itemContext == null) {
      double? offset = imageOffset?.call(imageIndex);
      if (offset != null && scrollController.hasClients) {
        int? anchor;
        RenderBox? box;
        for (final entry in _imageItemKeys.entries) {
          final RenderObject? item = entry.value.currentContext
              ?.findRenderObject();
          if (item is! RenderBox ||
              !item.attached ||
              (anchor != null &&
                  (entry.key - imageIndex).abs() >=
                      (anchor - imageIndex).abs())) {
            continue;
          }
          anchor = entry.key;
          box = item;
        }
        if (anchor != null) {
          final RenderObject viewport = viewportKey.currentContext!
              .findRenderObject()!;
          offset +=
              scrollController.offset +
              box!.localToGlobal(Offset.zero, ancestor: viewport).dy -
              imageOffset!(anchor);
        } else {
          offset += _segmentBaseOffset(pageUri);
        }
        scrollController.jumpTo(
          offset.clamp(0, scrollController.position.maxScrollExtent).toDouble(),
        );
      }
      if (attempts > 0) {
        Future<void>.delayed(
          const Duration(milliseconds: 250),
          () => _jumpToImageIndex(
            pageUri,
            imageIndex,
            attempts: attempts - 1,
            ticket: ticket,
            alignment: alignment,
          ),
        );
      }
      return;
    }
    Scrollable.ensureVisible(
      itemContext,
      duration: Duration.zero,
      alignment: alignment,
      alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
    );
  }

  void _jumpToPage(
    String pageUri,
    int pageIndex, {
    required int attempts,
    required DeferredViewportTicket ticket,
  }) {
    if (!_isActiveRestore(ticket, pageUri: pageUri, isPaged: true)) return;
    if (isBook) {
      handlePageChanged(pageIndex);
      return;
    }
    if (!pageController.hasClients) {
      if (attempts > 0) {
        Future<void>.delayed(
          const Duration(milliseconds: 250),
          () => _jumpToPage(
            pageUri,
            pageIndex,
            attempts: attempts - 1,
            ticket: ticket,
          ),
        );
      }
      return;
    }
    pageController.jumpToPage(pageIndex);
  }

  void _jumpPageOffset(
    String pageUri,
    int pageIndex, {
    required double? offset,
    required int attempts,
    required DeferredViewportTicket ticket,
  }) {
    if (!_isActiveRestore(ticket, pageUri: pageUri, isPaged: true)) return;
    final ScrollController? controller = _pagedScrollControllers[pageIndex];
    if (controller == null || !controller.hasClients) {
      if (attempts > 0) {
        Future<void>.delayed(
          const Duration(milliseconds: 250),
          () => _jumpPageOffset(
            pageUri,
            pageIndex,
            offset: offset,
            attempts: attempts - 1,
            ticket: ticket,
          ),
        );
      }
      return;
    }
    final double maxExtent = controller.position.maxScrollExtent;
    final double targetOffset =
        offset ??
        (preferences.openingPosition == ReaderOpeningPosition.center
            ? maxExtent * 0.5
            : 0);
    controller.jumpTo(targetOffset.clamp(0, maxExtent).toDouble());
  }

  void _disposePagedScrollControllers() {
    final List<ScrollController> controllers = _pagedScrollControllers.values
        .toList(growable: false);
    _pagedScrollControllers.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final ScrollController controller in controllers) {
        controller.dispose();
      }
    });
  }

  void _replacePageController({required int initialPage}) {
    final PageController previousController = pageController;
    pageController = PageController(initialPage: initialPage);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previousController.dispose();
    });
  }

  void _handleScroll() {
    final ReaderPageData? page = _page;
    if (page == null ||
        !scrollController.hasClients ||
        isPaged ||
        _suppressScrollTracking) {
      return;
    }
    final double currentOffset = _relativeScrollOffset(page.uri);
    if (_shouldScheduleScrollProgress(currentOffset)) {
      _lastScheduledProgressPosition = ReaderPosition.scroll(
        offset: currentOffset,
      );
      _scheduleProgressPersistence();
    }
    _scheduleVisibleIndexUpdate();
    _maybeAppendNextSegment();
  }

  void handlePageChanged(int index) {
    if (_currentPageIndex == index) return;
    final ReaderPageData? currentPage = _page;
    final int visibleImageIndex =
        currentPage != null && currentPage.imageUrls.isNotEmpty
        ? (index >= currentPage.imageUrls.length
              ? currentPage.imageUrls.length - 1
              : index)
        : index;
    _chapterBoundary.reset();
    _currentPageIndex = index;
    _visibleImageIndex = visibleImageIndex;
    if (currentPage != null) {
      _refreshReaderPrefetchWindow(currentPage, visibleImageIndex);
    }
    if (!_disposed) notifyListeners();
    _scheduleProgressPersistence();
    _restartAutoTurn();
  }

  void _handlePagedInnerScroll(int pageIndex) {
    if (pageIndex != _currentPageIndex) return;
    final ScrollController? controller = _pagedScrollControllers[pageIndex];
    if (controller == null || !controller.hasClients) return;
    if (_shouldSchedulePagedProgress(pageIndex, controller.offset)) {
      _lastScheduledProgressPosition = ReaderPosition.paged(
        pageIndex: pageIndex,
        pageOffset: controller.offset,
      );
      _scheduleProgressPersistence();
    }
  }

  void _scheduleVisibleIndexUpdate() {
    if (_visibleIndexUpdateQueued) return;
    _visibleIndexUpdateQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibleIndexUpdateQueued = false;
      if (_disposed || isPaged) return;
      _updateVisibleImageIndex();
      _maybeAppendNextSegment();
    });
  }

  bool _shouldScheduleScrollProgress(double offset) {
    final ReaderPosition? last =
        _lastScheduledProgressPosition ?? _lastPersistedPosition;
    if (last == null || !last.isScroll) return true;
    return (offset - last.offset).abs() >= _readerScrollProgressStep;
  }

  bool _shouldSchedulePagedProgress(int pageIndex, double pageOffset) {
    final ReaderPosition? last =
        _lastScheduledProgressPosition ?? _lastPersistedPosition;
    if (last == null || !last.isPaged || last.pageIndex != pageIndex) {
      return true;
    }
    return (pageOffset - last.pageOffset).abs() >= _readerPagedProgressStep;
  }

  void _updateVisibleImageIndex() {
    if (!scrollController.hasClients) return;
    final BuildContext? viewportContext = viewportKey.currentContext;
    if (viewportContext == null) return;
    final RenderObject? viewportRenderObject = viewportContext
        .findRenderObject();
    if (viewportRenderObject is! RenderBox) return;
    final double viewportTop = viewportRenderObject
        .localToGlobal(Offset.zero)
        .dy;
    final double viewportCenter =
        viewportTop + (viewportRenderObject.size.height / 2);
    final ReaderPageData? activePage = _page;
    String bestUri = activePage?.uri ?? '';
    int bestIndex = _visibleImageIndex;
    double bestDistance = double.infinity;
    // 连续阅读时列表里有多章，按「谁占据屏幕中线」决定当前章。
    final List<ReaderPageData> candidateSegments = isContinuous
        ? _segments
        : (activePage == null
              ? const <ReaderPageData>[]
              : <ReaderPageData>[activePage]);
    void considerBox(RenderObject? renderObject, String uri, int index) {
      if (renderObject is! RenderBox || !renderObject.attached) return;
      final Offset topLeft = renderObject.localToGlobal(Offset.zero);
      final double height = renderObject.size.height;
      final double distance =
          topLeft.dy <= viewportCenter && topLeft.dy + height >= viewportCenter
          ? 0
          : (topLeft.dy + height / 2 - viewportCenter).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = index;
        bestUri = uri;
      }
    }

    for (final ReaderPageData segment in candidateSegments) {
      final String uri = segment.uri;
      final Map<int, GlobalKey>? keys = _segmentItemKeys[uri];
      if (keys != null) {
        for (final MapEntry<int, GlobalKey> entry in keys.entries) {
          considerBox(
            entry.value.currentContext?.findRenderObject(),
            uri,
            entry.key,
          );
        }
      }
      final GlobalKey? commentKey = _segmentCommentKeys[uri];
      if (commentKey != null && segment.imageUrls.isNotEmpty) {
        considerBox(
          commentKey.currentContext?.findRenderObject(),
          uri,
          segment.imageUrls.length - 1,
        );
      }
    }
    if (activePage != null && bestUri != activePage.uri) {
      _activateSegment(bestUri, bestIndex);
      return;
    }
    if (bestIndex == _visibleImageIndex) return;
    _visibleImageIndex = bestIndex;
    final ReaderPageData? currentPage = _page;
    if (currentPage != null) {
      _refreshReaderPrefetchWindow(currentPage, bestIndex);
    }
    if (!_disposed) notifyListeners();
  }

  void recordImageAspectRatio(String imageUrl, double aspectRatio) {
    if (_imageAspectRatios[imageUrl] == aspectRatio) return;
    _imageAspectRatios[imageUrl] = aspectRatio;
    if (!_disposed) notifyListeners();
  }

  void handlePinchZoomStart() {
    _mutateZoom(_zoom.startPinch);
  }

  void handlePinchZoomUpdate(double relativeScale) {
    _mutateZoom(() => _zoom.updatePinch(relativeScale));
  }

  void handlePinchZoomEnd() {
    _mutateZoom(_zoom.endPinch);
  }

  void updatePanOffset({required double x, required double y}) {
    _mutateZoom(() => _zoom.updatePanOffset(x: x, y: y));
  }

  void handleZoomedOverscroll(ReaderPageData page, double overscrollDy) {
    final bool hasPreviousChapter = page.prevHref.trim().isNotEmpty;
    final bool hasNextChapter = page.nextHref.trim().isNotEmpty;
    if (overscrollDy < -0.5 && hasNextChapter) {
      _chapterBoundary.clearPrevious();
      _chapterBoundary.addNextDistance(overscrollDy.abs());
    } else if (overscrollDy > 0.5 && hasPreviousChapter) {
      _chapterBoundary.clearNext();
      _chapterBoundary.addPreviousDistance(overscrollDy.abs());
    }
  }

  void handleZoomedPanEnd(ReaderPageData page) {
    if (previousChapterPullReady) {
      unawaited(triggerPreviousChapter(page));
    } else if (nextChapterPullReady) {
      unawaited(triggerNextChapter(page));
    } else {
      _chapterBoundary.clearPrevious();
      _chapterBoundary.clearNext();
    }
  }

  Future<void> triggerPreviousChapter(ReaderPageData page) {
    return _chapterBoundary.triggerPrevious(page);
  }

  Future<void> triggerNextChapter(ReaderPageData page) {
    return _chapterBoundary.triggerNext(page);
  }

  void handleChapterPull(
    ScrollNotification notification, {
    required ReaderPageData page,
    required ScrollController controller,
    Axis axis = Axis.vertical,
  }) {
    _chapterBoundary.handlePull(
      notification,
      page: page,
      controller: controller,
      controllerAtTop: _scrollControllerAtTop,
      controllerAtBottom: _scrollControllerAtBottom,
      axis: axis,
    );
  }

  Future<void> loadComments(ReaderPageData page, {bool append = false}) {
    return _comments.load(page, append: append);
  }

  Future<void> submitComment(ReaderPageData page) {
    return _comments.submit(page);
  }

  void _resetZoomState() {
    _mutateZoom(_zoom.reset);
  }

  void _mutateZoom(bool Function() mutation) {
    final bool wasLocked = _zoom.isLocked;
    final bool changed = mutation();
    if (changed && !_disposed) {
      notifyListeners();
    }
    _handleZoomLockChanged(wasLocked);
  }

  void _handleZoomLockChanged(bool wasLocked) {
    final bool isLocked = isZoomGestureLocked;
    if (wasLocked == isLocked) return;
    if (isLocked) {
      _autoTurnTimer?.cancel();
      _chapterBoundary.reset();
      hideChapterControls();
      return;
    }
    _restartAutoTurn();
  }

  bool _scrollControllerAtBottom(
    ScrollController controller, {
    double tolerance = 1,
  }) {
    if (!controller.hasClients) return false;
    return controller.position.maxScrollExtent - controller.position.pixels <=
        tolerance;
  }

  bool _scrollControllerAtTop(
    ScrollController controller, {
    double tolerance = 1,
  }) {
    if (!controller.hasClients) return false;
    return controller.position.pixels - controller.position.minScrollExtent <=
        tolerance;
  }

  void _handleVolumeKeyAction(ReaderVolumeKeyAction action) {
    if (_page == null ||
        !preferences.useVolumeKeysForPaging ||
        isZoomGestureLocked) {
      return;
    }
    switch (action) {
      case ReaderVolumeKeyAction.previous:
        unawaited(stepBackward());
      case ReaderVolumeKeyAction.next:
        unawaited(stepForward());
    }
  }

  void _scheduleProgressPersistence() {
    _progressDebounce?.cancel();
    _progressDebounce = Timer(const Duration(milliseconds: 900), () {
      _progressDebounce = null;
      unawaited(_persistCurrentProgress());
    });
  }

  Future<void> _persistCurrentProgress() async {
    final ReaderPageData? page = _page;
    if (page == null) return;
    await _persistProgressFor(page);
  }

  Future<void> _persistProgressFor(ReaderPageData page) async {
    if (isPaged) {
      final ScrollController? pageScrollController =
          _pagedScrollControllers[_currentPageIndex];
      final ReaderPosition position = ReaderPosition.paged(
        pageIndex: _currentPageIndex,
        pageOffset:
            !isBook &&
                pageScrollController != null &&
                pageScrollController.hasClients
            ? pageScrollController.offset
            : 0,
      );
      _lastPersistedPosition = position;
      _lastScheduledProgressPosition = position;
      await progressStore.writePosition(
        position,
        catalogHref: page.catalogHref,
        chapterHref: page.uri,
      );
      return;
    }
    if (!scrollController.hasClients) return;
    final ReaderPosition position = ReaderPosition.scroll(
      offset: math.max(0, _relativeScrollOffset(page.uri)),
    );
    if (_page?.uri == page.uri) {
      _lastPersistedPosition = position;
      _lastScheduledProgressPosition = position;
    }
    await progressStore.writePosition(
      position,
      catalogHref: page.catalogHref,
      chapterHref: page.uri,
    );
  }

  void _handlePreferencesChanged() {
    final ReaderPreferences previousPreferences =
        _lastObservedPreferences ?? preferences;
    final ReaderPreferences nextPreferences = preferences;
    _lastObservedPreferences = nextPreferences;
    if (_disposed) return;

    final ReaderPageData? page = _page;
    final bool loading = _loadingPosition;
    final ReaderRestoreTarget? readerRestoreTarget = page != null && !loading
        ? captureCurrentRestoreTarget(page, preferences: previousPreferences)
        : null;
    notifyListeners();

    final bool requiresReaderRestore =
        previousPreferences.bookMode != nextPreferences.bookMode ||
        previousPreferences.readingDirection !=
            nextPreferences.readingDirection ||
        previousPreferences.pageFit != nextPreferences.pageFit ||
        previousPreferences.openingPosition !=
            nextPreferences.openingPosition ||
        previousPreferences.showChapterComments !=
            nextPreferences.showChapterComments ||
        previousPreferences.continuousChapters !=
            nextPreferences.continuousChapters;
    if (requiresReaderRestore && page != null && !loading) {
      _handlePageLoaded(
        page,
        previousUri: page.uri,
        forceRestore: true,
        preferredRestoreTarget: readerRestoreTarget,
      );
      return;
    }
    _scheduleReaderPresentationSync();
  }
}
