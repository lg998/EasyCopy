part of '../app_screen.dart';

extension _AppScreenProfileSections on _AppScreenState {
  List<Widget> _buildProfileSections(ProfilePageData page) {
    final ProfileSubview view = AppConfig.profileSubviewForUri(_currentUri);
    final bool failed =
        _errorMessage != null ||
        (view == ProfileSubview.cached &&
            _library.cachedComicsFailedNotifier.value);
    final bool hasContent = switch (view) {
      ProfileSubview.root => true,
      ProfileSubview.cached => _library.cachedComics.isNotEmpty,
      ProfileSubview.collections => page.collections.isNotEmpty,
      ProfileSubview.history => page.history.isNotEmpty,
      ProfileSubview.blocked => page.blockedItems.isNotEmpty,
    };
    if (view == ProfileSubview.collections) {
      final int collectionsTotal = page.collectionsTotal > 0
          ? page.collectionsTotal
          : page.collections.length;
      final Widget bookshelfSliver = BookshelfSliverSection(
        items: page.collections,
        totalCount: collectionsTotal,
        isLoading: _isLoading,
        hasMore: page.collectionsPager.hasNext,
        isLoadingMore: _library.isLoadingMoreCollections,
        loadMoreError: _library.collectionsLoadMoreError,
        onLoadMore: () => unawaited(_loadMoreCollections()),
        onOpenComic: _navigateToHref,
        hasUnreadUpdate: _hasUnreadCollectionUpdate,
        isUnread: _isUnreadCollection,
        onlyUnread: _library.onlyUnreadCollections,
        onOnlyUnreadChanged: (bool value) {
          _setStateIfMounted(() => _library.onlyUnreadCollections = value);
          _scrollState.resetStandardScrollPosition();
        },
        progressListenable: _services.readerProgressStore.chapterRevision,
        onRemoveCollections: _confirmRemoveCollectedComics,
      );
      return <Widget>[
        if (failed)
          _hPaddedBox(
            AppSurfaceCard(
              child: Center(
                child: TextButton.icon(
                  onPressed: () => unawaited(_retryCurrentPage()),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('加载失败，重试'),
                ),
              ),
            ),
          ),
        if (!failed ||
            (hasContent &&
                AppConfig.routeKeyForUri(Uri.parse(page.uri)) ==
                    AppConfig.routeKeyForUri(_currentUri)))
          SliverLayoutBuilder(
            builder: (BuildContext context, _) {
              final EdgeInsets padding = usesWideLayout(context)
                  ? standardContentPadding(context)
                  : const EdgeInsets.symmetric(horizontal: 12);
              return SliverPadding(padding: padding, sliver: bookshelfSliver);
            },
          ),
      ];
    }

    final Widget profileView = ProfilePageView(
      page: page,
      onAuthenticate: _openAuthFlow,
      onLogout: _logout,
      onOpenComic: _navigateToHref,
      onOpenHistory: (ProfileHistoryItem item) {
        final String targetHref = item.chapterHref.isNotEmpty
            ? item.chapterHref
            : item.comicHref;
        _navigateToHref(targetHref);
      },
      onOpenCollections: () => _openProfileSubview(ProfileSubview.collections),
      onOpenHistoryPage: () => _openProfileSubview(ProfileSubview.history),
      onOpenCachedComicPage: () => _openProfileSubview(ProfileSubview.cached),
      onOpenBlockedPage: () => _openProfileSubview(ProfileSubview.blocked),
      onOpenCollectionsPage: (int page) =>
          _openProfileSubview(ProfileSubview.collections, page: page),
      onOpenHistoryPageNumber: (int page) =>
          _openProfileSubview(ProfileSubview.history, page: page),
      onOpenBlockedPageNumber: (int page) =>
          _openProfileSubview(ProfileSubview.blocked, page: page),
      isLoading: _isLoading,
      isCachedComicsLoading: _library.cachedComicsLoadingNotifier.value,
      currentHost: _services.hostManager.currentHost,
      knownHosts: _services.hostManager.knownHosts,
      candidateHosts: _services.hostManager.candidateHosts,
      candidateHostAliases: _services.hostManager.candidateHostAliases,
      hostSnapshot: _services.hostManager.probeSnapshot,
      isRefreshingHosts: _shell.isUpdatingHostSettings,
      onRefreshHosts: _refreshHostSettings,
      onUseAutomaticHostSelection: _useAutomaticHostSelection,
      onSelectHost: _selectHost,
      onAddHost: _addHost,
      onDeleteHost: _deleteHost,
      chineseConversionMode: _preferencesController.chineseConversionMode,
      onChineseConversionModeChanged: (ChineseConversionMode mode) {
        unawaited(_preferencesController.setChineseConversionMode(mode));
      },
      themePreference: _preferencesController.themePreference,
      onThemePreferenceChanged: (AppThemePreference preference) {
        unawaited(_preferencesController.setThemePreference(preference));
      },
      wallpaperPreferences: _preferencesController.wallpaperPreferences,
      wallpaperActions: buildWallpaperActions(
        preferencesController: _preferencesController,
        showError: (String message) {
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        },
      ),
      versionLabel: _appVersionLabel,
      isCheckingForUpdates: _shell.isCheckingForUpdates,
      onCheckForUpdates: () {
        unawaited(_checkForUpdates());
      },
      onOpenProjectRepository: () {
        unawaited(_openProjectRepository());
      },
      afterContinueReading: _buildDownloadManagementEntry(),
      cachedComicCards: _cachedComicCardsForProfile(),
      activeSubview: view,
      hasCollectionUnreadUpdate: _hasUnreadCollectionUpdate,
      collectionProgressListenable:
          _services.readerProgressStore.chapterRevision,
      onRemoveCollections: _confirmRemoveCollectedComics,
      onOpenCachedComic: _openCachedComicFromProfile,
      onDeleteCachedComic: _deleteCachedComicFromProfile,
      onDeleteHistory: _deleteLocalHistoryFromProfile,
      onRemoveBlocked: (BlockedContentItem item) {
        unawaited(_removeBlockedContent(item));
      },
    );

    return <Widget>[
      if (failed)
        _hPaddedBox(
          AppSurfaceCard(
            child: Center(
              child: TextButton.icon(
                onPressed: () => unawaited(_retryCurrentPage()),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('加载失败，重试'),
              ),
            ),
          ),
        ),
      if (!failed ||
          (hasContent &&
              AppConfig.routeKeyForUri(Uri.parse(page.uri)) ==
                  AppConfig.routeKeyForUri(_currentUri)))
        _hPaddedBox(profileView),
    ];
  }

  Widget _buildDownloadManagementEntry() {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        _downloadQueueSnapshotNotifier,
        _downloadQueueManager.isRestoringNotifier,
        _downloadStorageStateNotifier,
        _storageMigrationProgress,
      ]),
      builder: (BuildContext context, Widget? _) {
        final DownloadQueueSnapshot queueSnapshot = _downloadQueueSnapshot;
        final DownloadStorageState storageState =
            _downloadStorageStateNotifier.value;
        final StorageMigrationProgress? migrationProgress =
            _storageMigrationProgress.value;
        final String statusLabel = queueSnapshot.isEmpty
            ? '空闲'
            : queueSnapshot.isPaused
            ? '已暂停'
            : '缓存中';
        return DownloadManagementEntryCard(
          isLoading: _downloadQueueManager.isRestoringNotifier.value,
          statusLabel: migrationProgress != null ? '迁移中' : statusLabel,
          queueLabel: '${queueSnapshot.remainingCount} 话',
          noteLabel:
              migrationProgress?.message ??
              (storageState.errorMessage.isNotEmpty
                  ? '目录异常：${storageState.errorMessage}'
                  : storageState.isLoading
                  ? '正在读取缓存目录…'
                  : null),
          onTap: _openDownloadManagementPage,
        );
      },
    );
  }

  void _openDownloadManagementPage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) {
          return DownloadManagementPage(
            queueListenable: _downloadQueueSnapshotNotifier,
            queueLoadingListenable: _downloadQueueManager.isRestoringNotifier,
            storageStateListenable: _downloadStorageStateNotifier,
            storageBusyListenable: _downloadStorageBusyNotifier,
            migrationProgressListenable: _storageMigrationProgress,
            cachedComicsListenable: _library.cachedComicsNotifier,
            cachedComicsLoadingListenable: _library.cachedComicsLoadingNotifier,
            cachedComicsFailedListenable: _library.cachedComicsFailedNotifier,
            onOpenCachedComic: (CachedComicLibraryEntry item) {
              _openCachedComicFromProfile(_cachedComicCardKey(item));
            },
            onDeleteCachedComic: (CachedComicLibraryEntry item) {
              unawaited(_confirmDeleteCachedComic(item));
            },
            supportsCustomDirs:
                _services.downloadService.supportsCustomStorageSelection,
            onPauseQueue: () {
              unawaited(_pauseDownloadQueue());
            },
            onResumeQueue: () {
              unawaited(_resumeDownloadQueue());
            },
            onClearQueue: () {
              unawaited(_confirmClearDownloadQueue());
            },
            onStopComicTasks: (DownloadQueueTask task) {
              unawaited(_confirmRemoveQueuedComic(task));
            },
            onRemoveComic: (DownloadQueueTask task) {
              unawaited(_confirmRemoveComicCache(task));
            },
            onRemoveTask: (DownloadQueueTask task) {
              unawaited(_confirmRemoveQueuedTask(task));
            },
            onRetryTask: (DownloadQueueTask task) {
              unawaited(_retryDownloadQueueTask(task));
            },
            onPickStorageDirectory: () {
              unawaited(_pickDownloadStorageDirectory());
            },
            onResetStorageDirectory: () {
              unawaited(_resetDownloadStorageDirectory());
            },
            onRescanStorageDirectory: _rescanCurrentDownloadStorage,
          );
        },
      ),
    );
  }

  List<ComicCardData> _cachedComicCardsForProfile() {
    return _library.cachedComics
        .map((CachedComicLibraryEntry item) {
          final String latestChapterTitle = item.chapters.isEmpty
              ? ''
              : item.chapters.first.chapterTitle;
          return ComicCardData(
            title: item.comicTitle,
            subtitle: '${item.cachedChapterCount}话',
            secondaryText: latestChapterTitle.isEmpty
                ? ''
                : '最近缓存：$latestChapterTitle',
            coverUrl: item.coverUrl,
            href: _cachedComicCardKey(item),
          );
        })
        .toList(growable: false);
  }

  String _cachedComicCardKey(CachedComicLibraryEntry item) {
    if (item.comicHref.isNotEmpty) {
      return item.comicHref;
    }
    return 'cache-title:${item.comicTitle}';
  }

  CachedComicLibraryEntry? _cachedComicByCardKey(String key) {
    return _library.cachedComics.cast<CachedComicLibraryEntry?>().firstWhere(
      (CachedComicLibraryEntry? item) =>
          item != null && _cachedComicCardKey(item) == key,
      orElse: () => null,
    );
  }

  void _openCachedComicFromProfile(String key) {
    final CachedComicLibraryEntry? item = _cachedComicByCardKey(key);
    if (item == null) {
      return;
    }
    final DetailPageData localPage = _services.downloadService
        .buildCachedDetailPage(item);
    final Uri targetUri = Uri.parse(localPage.uri);
    final int targetTabIndex = resolveNavigationTabIndex(
      targetUri,
      sourceTabIndex: _nav.selectedIndex,
    );
    final NavigationRequestContext requestContext = _prepareRouteEntry(
      targetUri,
      targetTabIndex: targetTabIndex,
      intent: NavigationIntent.push,
      preserveVisiblePage: false,
      sourceKind: NavigationRequestSourceKind.navigation,
    );
    _applyLoadedPage(
      localPage,
      requestContext: requestContext,
      switchToTab: _shouldActivateAsyncResultTab(requestContext.targetTabIndex),
    );
    if (item.comicHref.trim().isNotEmpty) {
      unawaited(
        _refreshCachedComicDetail(
          item,
          targetTabIndex: targetTabIndex,
          routeKey: AppConfig.routeKeyForUri(targetUri),
        ),
      );
    }
  }

  void _deleteCachedComicFromProfile(String key) {
    final CachedComicLibraryEntry? item = _cachedComicByCardKey(key);
    if (item == null) {
      return;
    }
    unawaited(_confirmDeleteCachedComic(item));
  }

  void _deleteLocalHistoryFromProfile(String comicHref) {
    unawaited(_confirmDeleteLocalHistory(comicHref));
  }

  Future<void> _removeBlockedContent(BlockedContentItem item) async {
    await _services.blockedContentStore.unblock(item);
    if (mounted) {
      _showNotice('已解除屏蔽');
    }
  }

  Future<void> _confirmDeleteLocalHistory(String comicHref) async {
    final String normalizedHref = comicHref.trim();
    if (normalizedHref.isEmpty) {
      return;
    }
    final SitePage? currentPageData = _page;
    final ProfilePageData? profilePage = currentPageData is ProfilePageData
        ? currentPageData
        : null;
    if (profilePage == null ||
        profilePage.isLoggedIn ||
        _services.session.isAuthenticated) {
      _showNotice('登录账号的浏览历史暂不支持删除');
      return;
    }
    ProfileHistoryItem? targetItem;
    for (final ProfileHistoryItem item in profilePage.history) {
      if (item.comicHref.trim() == normalizedHref) {
        targetItem = item;
        break;
      }
    }
    final String title = targetItem?.title.trim() ?? '';
    if (!await _confirmDialog(
      title: '删除浏览记录',
      content: title.isEmpty ? '确认删除这条浏览记录吗？' : '确认删除《$title》的浏览记录吗？',
      confirmLabel: '删除',
    )) {
      return;
    }

    try {
      await _services.localLibraryStore.removeHistory(
        LocalLibraryStore.guestScope,
        normalizedHref,
      );
      if (!mounted) {
        return;
      }
      _showNotice('已删除浏览记录');
      final ProfileSubview activeSubview = AppConfig.profileSubviewForUri(
        _currentUri,
      );
      final int activePage = AppConfig.profilePageForUri(_currentUri);
      final bool shouldStepBack =
          activeSubview == ProfileSubview.history &&
          activePage > 1 &&
          profilePage.history.length <= 1;
      final Uri targetUri = shouldStepBack
          ? AppConfig.buildProfileUri(
              view: ProfileSubview.history,
              page: activePage - 1,
            )
          : _currentUri;
      await _loadProfilePage(
        targetUri: targetUri,
        forceRefresh: true,
        preserveVisiblePage: true,
        historyMode: NavigationIntent.preserve,
      );
    } catch (_) {
      if (mounted) {
        _showNotice('删除失败，请稍后重试');
      }
    }
  }

  Future<void> _refreshCachedComicDetail(
    CachedComicLibraryEntry item, {
    required int targetTabIndex,
    required String routeKey,
  }) async {
    final String href = item.comicHref.trim();
    if (href.isEmpty) {
      return;
    }
    try {
      final Uri targetUri = AppConfig.rewriteToCurrentHost(Uri.parse(href));
      final SitePage freshPage = await _pageRepository.loadFresh(
        targetUri,
        authScope: _pageQueryKeyForUri(targetUri).authScope,
      );
      if (!mounted || freshPage is! DetailPageData) {
        return;
      }
      final PrimaryTabRouteEntry entry = _tabSessionStore.currentEntry(
        targetTabIndex,
      );
      if (entry.routeKey != routeKey) {
        return;
      }
      _applyLoadedPage(
        freshPage,
        targetTabIndex: targetTabIndex,
        switchToTab: false,
      );
    } catch (_) {
      return;
    }
  }

  void _maybeLoadMoreCollectionsOnScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical ||
        AppConfig.profileSubviewForUri(_currentUri) !=
            ProfileSubview.collections) {
      return;
    }
    if (_isLoading ||
        _library.isLoadingMoreCollections ||
        _library.collectionsLoadMoreError != null) {
      return;
    }
    final SitePage? rawPage = _currentEntry.page;
    if (rawPage is! ProfilePageData || !rawPage.collectionsPager.hasNext) {
      return;
    }
    if (notification.metrics.extentAfter <= 640) {
      unawaited(_loadMoreCollections());
    }
  }

  Future<void> _loadMoreCollections() async {
    if (_isLoading || _library.isLoadingMoreCollections) {
      return;
    }
    if (AppConfig.profileSubviewForUri(_currentUri) !=
        ProfileSubview.collections) {
      return;
    }
    final int tabIndex = _nav.selectedIndex;
    final PrimaryTabRouteEntry initialEntry = _tabSessionStore.currentEntry(
      tabIndex,
    );
    final SitePage? rawPage = initialEntry.page;
    if (rawPage is! ProfilePageData || !rawPage.collectionsPager.hasNext) {
      return;
    }

    final int currentPage = rawPage.collectionsPager.currentPageNumber ?? 1;
    final int nextPage = currentPage + 1;
    final ProfileCollectionSort sort = _effectiveProfileCollectionSort(
      AppConfig.profileCollectionSortForUri(_currentUri),
    );
    final String expectedRouteKey = initialEntry.routeKey;
    final int generation = ++_library.collectionsLoadMoreGeneration;
    final bool isLoggedIn =
        _services.session.isAuthenticated &&
        (_services.session.token ?? '').isNotEmpty;

    _setStateIfMounted(() {
      _library.isLoadingMoreCollections = true;
      _library.collectionsLoadMoreError = null;
    });

    try {
      final List<ProfileLibraryItem> fetchedItems;
      final PagerData fetchedPager;
      final int fetchedTotal;
      if (isLoggedIn) {
        final result = await _services.siteApiClient.loadCollectionsPage(
          page: nextPage,
          collectionSort: sort,
        );
        fetchedItems = result.items;
        fetchedPager = result.pager;
        fetchedTotal = result.total;
      } else {
        final Uri pageUri = AppConfig.buildProfileUri(
          view: ProfileSubview.collections,
          page: nextPage,
          collectionSort: sort,
        );
        final ProfilePageData localPage = await _services.localProfilePageLoader
            .loadLocalProfile(pageUri, authScope: LocalLibraryStore.guestScope);
        fetchedItems = localPage.collections;
        fetchedPager = localPage.collectionsPager;
        fetchedTotal = localPage.collectionsTotal;
      }

      if (!mounted || generation != _library.collectionsLoadMoreGeneration) {
        return;
      }
      final PrimaryTabRouteEntry currentEntry = _tabSessionStore.currentEntry(
        tabIndex,
      );
      final SitePage? currentPageData = currentEntry.page;
      if (currentEntry.routeKey != expectedRouteKey ||
          currentPageData is! ProfilePageData) {
        _setStateIfMounted(() {
          _library.isLoadingMoreCollections = false;
        });
        return;
      }

      final Set<String> seenHrefs = currentPageData.collections
          .map((ProfileLibraryItem item) => item.href)
          .where((String href) => href.isNotEmpty)
          .toSet();
      final List<ProfileLibraryItem> merged = <ProfileLibraryItem>[
        ...currentPageData.collections,
        for (final ProfileLibraryItem item in fetchedItems)
          if (item.href.isEmpty || seenHrefs.add(item.href)) item,
      ];
      final PagerData effectivePager = fetchedItems.isEmpty
          ? PagerData(
              currentLabel: fetchedPager.currentLabel,
              totalLabel: fetchedPager.totalLabel,
              prevHref: fetchedPager.prevHref,
              nextHref: '',
            )
          : fetchedPager;
      final int effectiveTotal = fetchedTotal > 0
          ? fetchedTotal
          : currentPageData.collectionsTotal;

      _setStateIfMounted(() {
        _library.isLoadingMoreCollections = false;
        _library.collectionsLoadMoreError = null;
        _tabSessionStore.updateCurrent(
          tabIndex,
          (PrimaryTabRouteEntry entry) => entry.copyWith(
            page: currentPageData.copyWith(
              collections: merged,
              collectionsPager: effectivePager,
              collectionsTotal: effectiveTotal,
            ),
          ),
        );
      });
    } catch (error) {
      if (!mounted || generation != _library.collectionsLoadMoreGeneration) {
        return;
      }
      _setStateIfMounted(() {
        _library.isLoadingMoreCollections = false;
        _library.collectionsLoadMoreError = error is SiteApiException
            ? error.message
            : '加载失败，请点击重试';
      });
    }
  }

  bool _hasUnreadCollectionUpdate(ProfileLibraryItem item) {
    final String lastChapterId = item.lastChapterId.trim();
    if (lastChapterId.isEmpty) {
      return false;
    }
    final String comicPathKey = UriKeys.rawPathKey(
      item.href,
    ).replaceAll(RegExp(r'/+$'), '');
    final String lastChapterPathKey = comicPathKey.isEmpty
        ? ''
        : '$comicPathKey/chapter/$lastChapterId';
    final Set<String> visitedKeys = _services.readerProgressStore
        .visitedChapterPathKeysForCatalog(item.href);
    final String? localLatestKey = _services.readerProgressStore
        .latestChapterPathKeyForCatalog(item.href);
    final bool readLocally =
        visitedKeys.isNotEmpty ||
        (localLatestKey != null && localLatestKey.isNotEmpty);
    final String serverBrowseId = item.lastBrowseChapterId.trim();
    final bool readOnServer = serverBrowseId.isNotEmpty;
    if (!readLocally && !readOnServer) {
      return false;
    }
    final bool readLatestLocally =
        lastChapterPathKey.isNotEmpty &&
        (visitedKeys.contains(lastChapterPathKey) ||
            localLatestKey == lastChapterPathKey);
    final bool readLatestOnServer = serverBrowseId == lastChapterId;
    return !readLatestLocally && !readLatestOnServer;
  }

  bool _isUnreadCollection(ProfileLibraryItem item) {
    final bool hasLocalHistory =
        _services.readerProgressStore
            .visitedChapterPathKeysForCatalog(item.href)
            .isNotEmpty ||
        (_services.readerProgressStore
                .latestChapterPathKeyForCatalog(item.href)
                ?.isNotEmpty ??
            false);
    return (!hasLocalHistory && item.lastBrowseChapterId.trim().isEmpty) ||
        _hasUnreadCollectionUpdate(item);
  }

  Future<bool> _confirmRemoveCollectedComics(
    List<ProfileLibraryItem> selected,
  ) async {
    if (selected.isEmpty) {
      return false;
    }
    final bool isLoggedIn =
        _services.session.isAuthenticated &&
        (_services.session.token ?? '').isNotEmpty;
    if (isLoggedIn &&
        selected.any(
          (ProfileLibraryItem item) => item.comicId.trim().isEmpty,
        )) {
      _showNotice('正在同步收藏信息，请稍后再试');
      unawaited(
        _loadProfilePage(
          targetUri: _currentUri,
          forceRefresh: true,
          preserveVisiblePage: true,
          historyMode: NavigationIntent.preserve,
        ),
      );
      return false;
    }
    final String prompt = selected.length == 1
        ? '确认将《${selected.first.title}》取消收藏吗？'
        : '确认将选中的 ${selected.length} 部漫画取消收藏吗？';
    if (!await _confirmDialog(
      title: '取消收藏',
      content: prompt,
      confirmLabel: '取消收藏',
    )) {
      return false;
    }

    try {
      if (isLoggedIn) {
        for (final ProfileLibraryItem item in selected) {
          await _services.siteApiClient.setComicCollection(
            comicId: item.comicId,
            isCollected: false,
          );
        }
      } else {
        for (final ProfileLibraryItem item in selected) {
          await _services.localLibraryStore.removeCollection(
            LocalLibraryStore.guestScope,
            item.href,
          );
        }
      }
      if (!mounted) {
        return true;
      }
      _showNotice('已取消收藏 ${selected.length} 部漫画');
      final int tabIndex = _nav.selectedIndex;
      final PrimaryTabRouteEntry activeEntry = _tabSessionStore.currentEntry(
        tabIndex,
      );
      final SitePage? rawPage = activeEntry.page;
      if (rawPage is ProfilePageData) {
        final Set<String> removedHrefs = selected
            .map((ProfileLibraryItem item) => item.href)
            .toSet();
        final List<ProfileLibraryItem> remaining = rawPage.collections
            .where(
              (ProfileLibraryItem item) => !removedHrefs.contains(item.href),
            )
            .toList(growable: false);
        final int updatedTotal =
            (rawPage.collectionsTotal - selected.length) < remaining.length
            ? remaining.length
            : (rawPage.collectionsTotal - selected.length);
        if (remaining.isNotEmpty || !rawPage.collectionsPager.hasNext) {
          _setStateIfMounted(() {
            _tabSessionStore.updateCurrent(
              tabIndex,
              (PrimaryTabRouteEntry entry) => entry.copyWith(
                page: rawPage.copyWith(
                  collections: remaining,
                  collectionsTotal: updatedTotal,
                ),
              ),
            );
          });
          // Invalidate page-1 cache in the background when the user returns later.
          unawaited(
            _pageRepository
                .loadFresh(
                  AppConfig.buildProfileUri(
                    view: ProfileSubview.collections,
                    collectionSort: _effectiveProfileCollectionSort(
                      AppConfig.profileCollectionSortForUri(_currentUri),
                    ),
                  ),
                  authScope: _pageQueryKeyForUri(_currentUri).authScope,
                )
                .catchError((_) => rawPage),
          );
          return true;
        }
      }
      await _loadProfilePage(
        targetUri: _currentUri,
        forceRefresh: true,
        preserveVisiblePage: true,
        historyMode: NavigationIntent.preserve,
      );
      return true;
    } catch (error) {
      if (mounted) {
        final String message = error is SiteApiException
            ? error.message
            : '取消收藏失败，请稍后重试';
        _showNotice(message);
      }
      return false;
    }
  }
}
