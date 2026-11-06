part of '../app_screen.dart';

extension _AppScreenReaderNavigation on _AppScreenState {
  void _handleReaderChaptersChanged() {
    if (_page is DetailPageData) _setStateIfMounted();
  }

  bool _shouldBypassUnknownCache(Uri uri, SitePage page) {
    if (page is! UnknownPageData) {
      return false;
    }
    final String path = uri.path.toLowerCase();
    return path == '/' ||
        path.startsWith('/comics') ||
        path.startsWith('/search') ||
        path.startsWith('/rank') ||
        path.startsWith('/recommend') ||
        path.startsWith('/newest') ||
        path.startsWith('/comic/') ||
        path.startsWith('/person') ||
        path.startsWith('/web/login');
  }

  CachedChapterNavigationContext _resolvedCachedChapterContext(
    Uri targetUri, {
    required CachedChapterNavigationContext context,
  }) {
    final SitePage? currentPage = _page;
    CachedChapterNavigationContext resolvedContext = context;
    if (currentPage is ReaderPageData && !context.hasAnyValue) {
      final String targetKey = _chapterKeys.pathKey(targetUri.toString());
      final String currentKey = _chapterKeys.pathKey(currentPage.uri);
      final String prevKey = _chapterKeys.pathKey(currentPage.prevHref);
      final String nextKey = _chapterKeys.pathKey(currentPage.nextHref);

      if (targetKey == currentKey) {
        resolvedContext = CachedChapterNavigationContext(
          prevHref: currentPage.prevHref,
          nextHref: currentPage.nextHref,
          catalogHref: currentPage.catalogHref,
        );
      } else if (targetKey == prevKey) {
        resolvedContext = CachedChapterNavigationContext(
          nextHref: currentPage.uri,
          catalogHref: currentPage.catalogHref,
        );
      } else if (targetKey == nextKey) {
        resolvedContext = CachedChapterNavigationContext(
          prevHref: currentPage.uri,
          catalogHref: currentPage.catalogHref,
        );
      } else {
        resolvedContext = CachedChapterNavigationContext(
          catalogHref: currentPage.catalogHref,
        );
      }
    }

    final CachedChapterNavigationContext detailContext = _cachedChapterContext(
      targetUri,
      preferredCatalogHref: resolvedContext.catalogHref,
    );
    return resolvedContext.mergeMissing(detailContext);
  }

  CachedChapterNavigationContext _cachedChapterContext(
    Uri targetUri, {
    String preferredCatalogHref = '',
  }) {
    final String targetKey = _chapterKeys.pathKey(targetUri.toString());
    if (targetKey.isEmpty) {
      return const CachedChapterNavigationContext();
    }
    final List<PrimaryTabRouteEntry> stackEntries = _tabSessionStore
        .stackForTab(_nav.selectedIndex);
    final List<DetailPageData> detailPages = <DetailPageData>[
      ...stackEntries
          .map((PrimaryTabRouteEntry entry) => entry.page)
          .whereType<DetailPageData>()
          .toList(growable: false)
          .reversed,
      ..._nav.readerCatalogs.values,
    ];
    if (detailPages.isEmpty) {
      return const CachedChapterNavigationContext();
    }

    CachedChapterNavigationContext contextForPage(DetailPageData page) {
      final List<ChapterData> chapters = ChapterNavigation.sequenceFor(
        page,
        targetUri.toString(),
      );
      final int index = chapters.indexWhere(
        (ChapterData chapter) =>
            _chapterKeys.pathKey(chapter.href) == targetKey,
      );
      if (index == -1) {
        return const CachedChapterNavigationContext();
      }
      return CachedChapterNavigationContext(
        prevHref: index > 0 ? chapters[index - 1].href : '',
        nextHref: index + 1 < chapters.length ? chapters[index + 1].href : '',
        catalogHref: page.uri,
        isResolved: true,
      );
    }

    final String preferredCatalogRouteKey = preferredCatalogHref.trim().isEmpty
        ? ''
        : AppConfig.routeKeyForUri(Uri.parse(preferredCatalogHref));
    if (preferredCatalogRouteKey.isNotEmpty) {
      for (final DetailPageData page in detailPages) {
        if (AppConfig.routeKeyForUri(Uri.parse(page.uri)) !=
            preferredCatalogRouteKey) {
          continue;
        }
        final CachedChapterNavigationContext context = contextForPage(page);
        if (context.hasAnyValue) {
          return context;
        }
      }
    }

    for (final DetailPageData page in detailPages) {
      final CachedChapterNavigationContext context = contextForPage(page);
      if (context.hasAnyValue) {
        return context;
      }
    }
    return const CachedChapterNavigationContext();
  }

  ReaderPageData _mergeReaderPageNavigation(
    ReaderPageData page,
    CachedChapterNavigationContext context,
  ) {
    if (context.isResolved) {
      return page.copyWith(
        prevHref: context.prevHref,
        nextHref: context.nextHref,
        catalogHref: context.catalogHref,
      );
    }
    return page.mergeMissingNavigation(
      prevHref: context.prevHref,
      nextHref: context.nextHref,
      catalogHref: context.catalogHref,
    );
  }

  bool _didReaderNavigationChange(ReaderPageData before, ReaderPageData after) {
    return before.prevHref != after.prevHref ||
        before.nextHref != after.nextHref ||
        before.catalogHref != after.catalogHref;
  }

  Future<void> _persistReaderPageCache(ReaderPageData page) async {
    try {
      final String authScope = _pageQueryKeyForUri(
        Uri.parse(page.uri),
      ).authScope;
      await _pageRepository.writeCachedPage(page, authScope: authScope);
    } catch (_) {
      // 缓存修复失败不影响当前页面。
    }
  }

  Future<ReaderPageData?> _loadRepairReaderPage(
    Uri uri, {
    required String authScope,
  }) async {
    final SitePage page = await _pageRepository.loadFresh(
      uri,
      authScope: authScope,
    );
    if (page is ReaderPageData && page.imageUrls.isNotEmpty) {
      return page;
    }
    return null;
  }

  Future<DetailPageData?> _loadRepairDetailPage(
    Uri uri, {
    required String authScope,
  }) async {
    final String routeKey = AppConfig.routeKeyForUri(uri);
    final DetailPageData? known = _nav.readerCatalogs[routeKey];
    if (known != null) return known;
    final SitePage page = await _pageRepository.loadFresh(
      uri,
      authScope: authScope,
    );
    if (page is! DetailPageData) return null;
    _nav.readerCatalogs[routeKey] = page;
    return page;
  }

  Future<void> _repairCachedReaderNavigation(
    ReaderPageData page, {
    required Uri targetUri,
    required CachedChapterNavigationContext context,
    required NavigationRequestContext requestContext,
    required bool persistToPageCache,
  }) async {
    if (context.isResolved) {
      return;
    }
    final PageQueryKey key = _pageQueryKeyForUri(targetUri);
    if (!_nav.repairRouteKeys.add(key.routeKey)) {
      return;
    }
    try {
      DebugTrace.log('reader.navigation_repair_start', <String, Object?>{
        'bootId': _shell.bootId,
        'uri': targetUri.toString(),
        'persistToPageCache': persistToPageCache,
      });
      final ReaderPageData repairedPage = await ReaderNavigationRepairer.repair(
        page,
        authScope: key.authScope,
        preferredCatalogHref: context.catalogHref,
        loadReaderPage: _loadRepairReaderPage,
        loadDetailPage: _loadRepairDetailPage,
      );
      if (!_didReaderNavigationChange(page, repairedPage)) {
        DebugTrace.log('reader.navigation_repair_noop', <String, Object?>{
          'bootId': _shell.bootId,
          'uri': targetUri.toString(),
        });
        return;
      }
      if (persistToPageCache) {
        await _persistReaderPageCache(repairedPage);
      }
      DebugTrace.log('reader.navigation_repair_complete', <String, Object?>{
        'bootId': _shell.bootId,
        'uri': targetUri.toString(),
        'prevHref': repairedPage.prevHref,
        'nextHref': repairedPage.nextHref,
        'catalogHref': repairedPage.catalogHref,
      });
      if (!_canCommitRequest(requestContext)) {
        return;
      }
      _applyLoadedPage(
        repairedPage,
        requestContext: requestContext,
        switchToTab: false,
      );
    } catch (error) {
      DebugTrace.log('reader.navigation_repair_failed', <String, Object?>{
        'bootId': _shell.bootId,
        'uri': targetUri.toString(),
        'error': error.toString(),
      });
    } finally {
      _nav.repairRouteKeys.remove(key.routeKey);
    }
  }

  Future<bool> _tryOpenCachedChapterReader(
    Uri targetUri, {
    required NavigationRequestContext requestContext,
    CachedChapterNavigationContext context =
        const CachedChapterNavigationContext(),
  }) async {
    final CachedChapterNavigationContext resolvedContext =
        _resolvedCachedChapterContext(targetUri, context: context);
    final ReaderPageData? cachedPage = await _services.downloadService
        .loadCachedReaderPage(
          targetUri.toString(),
          prevHref: resolvedContext.prevHref,
          nextHref: resolvedContext.nextHref,
          catalogHref: resolvedContext.catalogHref,
        );
    if (cachedPage == null) {
      return false;
    }
    return _applyLoadedPage(
      cachedPage,
      requestContext: requestContext,
      switchToTab: true,
      persistReaderNavigationToCache: false,
    );
  }

  /// 连续阅读：只加载下一章的数据，不切换路由、不改动当前页面。
  ///
  /// 加载顺序与正常打开章节一致：已下载的本地章节 → 页面缓存 → 网络。
  Future<ReaderPageData?> _loadContinuousReaderChapter(
    String href, {
    required String prevHref,
    required String catalogHref,
  }) async {
    final Uri targetUri = AppConfig.rewriteToCurrentHost(
      AppConfig.resolveNavigationUri(href, currentUri: _currentUri),
    );
    if (!isReaderChapterUri(targetUri)) {
      return null;
    }
    final CachedChapterNavigationContext context =
        CachedChapterNavigationContext(
          prevHref: prevHref,
          catalogHref: catalogHref,
        ).mergeMissing(
          _cachedChapterContext(targetUri, preferredCatalogHref: catalogHref),
        );
    final bool bypassLocalCaches =
        _downloadQueueManager.shouldBypassCachedReaderLookup;
    final PageQueryKey key = _pageQueryKeyForUri(targetUri);
    DebugTrace.log('reader.continuous_load_start', <String, Object?>{
      'bootId': _shell.bootId,
      'uri': targetUri.toString(),
    });

    ReaderPageData? cachedReaderPage;
    if (!bypassLocalCaches) {
      cachedReaderPage = await _services.downloadService.loadCachedReaderPage(
        targetUri.toString(),
        prevHref: context.prevHref,
        nextHref: context.nextHref,
        catalogHref: context.catalogHref,
      );
    }
    ReaderPageData page;
    if (cachedReaderPage != null) {
      page = cachedReaderPage;
    } else {
      final CachedPageHit? cachedHit = bypassLocalCaches
          ? null
          : await _pageRepository.readCached(key);
      final SitePage? cachedPage = cachedHit?.page;
      if (cachedPage is ReaderPageData && cachedPage.imageUrls.isNotEmpty) {
        page = cachedPage;
      } else {
        final SitePage freshPage = await _pageRepository.loadFresh(
          targetUri,
          authScope: key.authScope,
        );
        if (freshPage is! ReaderPageData || freshPage.imageUrls.isEmpty) {
          return null;
        }
        page = freshPage;
      }
    }
    page = _mergeReaderPageNavigation(page, context);
    if (!context.isResolved) {
      try {
        page = await ReaderNavigationRepairer.repair(
          page,
          authScope: key.authScope,
          preferredCatalogHref: context.catalogHref,
          loadReaderPage: _loadRepairReaderPage,
          loadDetailPage: _loadRepairDetailPage,
        );
      } catch (_) {
        // 修复失败只是拿不到再下一章的链接，本章仍可阅读。
      }
    }
    DebugTrace.log('reader.continuous_load_complete', <String, Object?>{
      'bootId': _shell.bootId,
      'uri': page.uri,
      'imageCount': page.imageUrls.length,
      'hasNext': page.nextHref.trim().isNotEmpty,
    });
    return page;
  }

  /// 连续阅读：滚动进入另一章后，把它记为当前路由（返回、重启恢复都以它为准），
  /// 但不重新加载阅读页。
  void _commitContinuousReaderChapter(ReaderPageData page) {
    if (!mounted || _page is! ReaderPageData) {
      return;
    }
    final int tabIndex = _nav.selectedIndex;
    final Uri pageUri = AppConfig.rewriteToCurrentHost(Uri.parse(page.uri));
    _mutateSessionState(() {
      // 旧章节的后台刷新 / 导航修复不能再覆盖当前章。
      _abandonCurrentRequest(tabIndex, phase: 'continuous-reader');
      _tabSessionStore.updateCurrent(
        tabIndex,
        (PrimaryTabRouteEntry entry) => entry.copyWith(
          uri: pageUri,
          page: page,
          isLoading: false,
          clearError: true,
        ),
      );
    });
  }

  void _openDetailChapter(DetailPageData page, String href) {
    if (href.trim().isEmpty) {
      return;
    }
    final AdjacentChapterLinks links = _adjacentChapterLinksForDetail(
      page,
      href,
    );
    unawaited(
      _openHref(
        href,
        prevHref: links.prevHref,
        nextHref: links.nextHref,
        catalogHref: page.uri,
      ),
    );
  }

  List<ChapterData> _detailChapterList(DetailPageData page) {
    if (page.chapters.isNotEmpty) {
      return page.chapters;
    }
    if (page.chapterGroups.isNotEmpty) {
      return page.chapterGroups
          .expand((ChapterGroupData group) => group.chapters)
          .toList(growable: false);
    }
    return page.chapters;
  }

  AdjacentChapterLinks _adjacentChapterLinksForDetail(
    DetailPageData page,
    String href,
  ) {
    final List<ChapterData> chapters = ChapterNavigation.sequenceFor(
      page,
      href,
    );
    final String targetKey = _chapterKeys.pathKey(href);
    final int index = chapters.indexWhere(
      (ChapterData chapter) => _chapterKeys.pathKey(chapter.href) == targetKey,
    );
    if (index == -1) {
      return const AdjacentChapterLinks();
    }
    return AdjacentChapterLinks(
      prevHref: index > 0 ? chapters[index - 1].href : '',
      nextHref: index + 1 < chapters.length ? chapters[index + 1].href : '',
    );
  }

  Future<void> _handleBackNavigation() async {
    if (_ui.mobileSearchFocusNode.hasFocus) {
      _ui.mobileSearchFocusNode.unfocus();
      return;
    }
    if (_isReaderMode) {
      await _runReaderExitTransition(() async {
        await _handleReaderBack();
      });
      return;
    }
    await _handleReaderBack();
  }

  Future<void> _handleReaderBack() async {
    final SitePage? page = _page;
    if (page is ReaderPageData) {
      await _ui.readerScreenKey.currentState?.controller
          .flushProgressPersistence();
    }
    _scrollState.persistVisiblePageState();
    if (page is ReaderPageData && await _handleReaderBackNavigation(page)) {
      return;
    }
    _scrollState.pauseTrackingForRoute();
    final PrimaryTabRouteEntry? previousEntry = _tabSessionStore.pop(
      _nav.selectedIndex,
    );
    if (previousEntry != null) {
      if (previousEntry.page is ProfilePageData &&
          AppConfig.profileSubviewForUri(previousEntry.uri) ==
              ProfileSubview.collections) {
        _mutateSessionState(() {
          _abandonCurrentRequest(
            _nav.selectedIndex,
            phase: 'restore-collections',
          );
        });
        _scrollState.restoreStandardScrollPosition(
          previousEntry.standardScrollOffset,
          tabIndex: _nav.selectedIndex,
          routeKey: previousEntry.routeKey,
        );
        return;
      }
      await _loadUri(
        previousEntry.uri,
        preserveVisiblePage: _page != null,
        skipPersistVisiblePageState: true,
        sourceTabIndex: _nav.selectedIndex,
        historyMode: NavigationIntent.preserve,
      );
      return;
    }
    if (_nav.selectedIndex != AppConfig.defaultPrimaryTabIndex) {
      await _onItemTapped(AppConfig.defaultPrimaryTabIndex);
      return;
    }
    if (_shouldConfirmBackToExit()) {
      return;
    }
    await SystemNavigator.pop();
  }

  /// 移动端根路由需二次返回退出，避免误触。
  bool _shouldConfirmBackToExit() {
    if (PlatformCapabilities.isDesktop) {
      return false;
    }
    final DateTime now = DateTime.now();
    final DateTime? lastPrompt = _shell.backToExitPromptedAt;
    if (lastPrompt != null &&
        now.difference(lastPrompt) <= _backToExitConfirmWindow) {
      return false;
    }
    _shell.backToExitPromptedAt = now;
    _showNotice('再按一次返回退出应用');
    return true;
  }

  Future<void> _runReaderExitTransition(Future<void> Function() action) async {
    if (!_isReaderMode || _shell.isReaderExitTransitionActive || !mounted) {
      await action();
      return;
    }

    _setStateIfMounted(() {
      _shell.isReaderExitTransitionActive = true;
    });

    final Future<void> fadeFuture = Future<void>.delayed(
      _readerExitFadeDuration,
    );
    try {
      await action();
      await fadeFuture;
    } finally {
      if (!mounted) {
        _shell.isReaderExitTransitionActive = false;
      } else if (_page is ReaderPageData) {
        _setStateIfMounted(() {
          _shell.isReaderExitTransitionActive = false;
        });
      } else {
        _shell.isReaderExitTransitionActive = false;
      }
    }
  }

  Future<bool> _handleReaderBackNavigation(ReaderPageData page) async {
    final String catalogHref = page.catalogHref.trim();
    if (catalogHref.isEmpty) {
      return false;
    }
    final Uri catalogUri = AppConfig.resolveNavigationUri(
      catalogHref,
      currentUri: Uri.parse(page.uri),
    );
    final PrimaryTabRouteEntry? existingCatalogEntry = _tabSessionStore
        .popToRoute(_nav.selectedIndex, catalogUri);
    if (existingCatalogEntry != null) {
      await _loadUri(
        existingCatalogEntry.uri,
        preserveVisiblePage: existingCatalogEntry.page != null,
        skipPersistVisiblePageState: true,
        sourceTabIndex: _nav.selectedIndex,
        historyMode: NavigationIntent.preserve,
      );
      return true;
    }
    // 直接进入阅读时，用目录替换阅读页，保留下面的来源页。
    _scrollState.pauseTrackingForRoute();
    await _loadUri(
      catalogUri,
      skipPersistVisiblePageState: true,
      sourceTabIndex: _nav.selectedIndex,
      historyMode: NavigationIntent.preserve,
    );
    return true;
  }

  String _resolveHistoryCoverForCatalog(String catalogHref) {
    final String catalogPath = Uri.tryParse(catalogHref)?.path ?? '';
    if (catalogPath.isEmpty) {
      return '';
    }
    for (final PrimaryTabRouteEntry entry in _tabSessionStore.stackForTab(
      _nav.selectedIndex,
    )) {
      final SitePage? entryPage = entry.page;
      if (entryPage is DetailPageData &&
          Uri.parse(entryPage.uri).path == catalogPath) {
        return entryPage.coverUrl;
      }
    }
    final CachedComicLibraryEntry? cachedEntry = _library.cachedComics
        .cast<CachedComicLibraryEntry?>()
        .firstWhere(
          (CachedComicLibraryEntry? item) =>
              item != null && Uri.tryParse(item.comicHref)?.path == catalogPath,
          orElse: () => null,
        );
    return cachedEntry?.coverUrl ?? '';
  }

  Future<void> _handleReaderExitToHome() async {
    await _runReaderExitTransition(() async {
      final SitePage? page = _page;
      if (page is ReaderPageData) {
        await _ui.readerScreenKey.currentState?.controller
            .flushProgressPersistence();
      }
      await _onItemTapped(_nav.selectedIndex);
    });
  }

  Future<void> _reloadReaderChapter(ReaderPageData currentPage) async {
    await _ui.readerScreenKey.currentState?.controller
        .flushProgressPersistence();
    final Uri targetUri = AppConfig.rewriteToCurrentHost(
      Uri.parse(currentPage.uri),
    );
    await _loadUri(
      targetUri,
      bypassCache: true,
      preserveVisiblePage: false,
      skipPersistVisiblePageState: true,
      sourceTabIndex: _nav.selectedIndex,
      historyMode: NavigationIntent.preserve,
      cachedChapterContext: CachedChapterNavigationContext(
        prevHref: currentPage.prevHref,
        nextHref: currentPage.nextHref,
        catalogHref: currentPage.catalogHref,
      ),
    );
  }

  Future<DetailPageData?> _loadReaderCatalogDetail(
    ReaderPageData currentPage,
  ) async {
    final String catalogHref = currentPage.catalogHref.trim();
    if (catalogHref.isEmpty) {
      return null;
    }
    final Uri catalogUri = AppConfig.rewriteToCurrentHost(
      AppConfig.resolveNavigationUri(
        catalogHref,
        currentUri: Uri.parse(currentPage.uri),
      ),
    );
    final String targetRouteKey = AppConfig.routeKeyForUri(catalogUri);
    for (final PrimaryTabRouteEntry entry
        in _tabSessionStore.stackForTab(_nav.selectedIndex).reversed) {
      final SitePage? entryPage = entry.page;
      if (entryPage is DetailPageData &&
          AppConfig.routeKeyForUri(Uri.parse(entryPage.uri)) ==
              targetRouteKey &&
          _detailChapterList(entryPage).isNotEmpty) {
        return entryPage;
      }
    }
    final PageQueryKey key = _pageQueryKeyForUri(catalogUri);
    final CachedPageHit? cachedHit = await _pageRepository.readCached(key);
    final SitePage? cachedPage = cachedHit?.page;
    if (cachedPage is DetailPageData &&
        _detailChapterList(cachedPage).isNotEmpty) {
      return cachedPage;
    }
    final SitePage freshPage = await _pageRepository.loadFresh(
      catalogUri,
      authScope: key.authScope,
    );
    return freshPage is DetailPageData ? freshPage : null;
  }

  bool get _isReaderMode => _currentEntry.page is ReaderPageData;

  Widget _buildReaderLoadingScreen(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: const Center(child: CircularProgressIndicator()),
    );
  }
}
