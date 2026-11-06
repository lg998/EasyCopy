part of '../reader_screen.dart';

const Color _readerHudSurfaceColor = Color(0xE816181D);
const Color _readerHudTopSurfaceColor = Color(0xDE16181D);

extension _ReaderHudOverlay on ReaderScreenState {
  Widget _buildReaderTopHudOverlay(BuildContext context, ReaderPageData page) {
    final bool visible = _controller.isChapterControlsVisible;
    final String rawTitle = page.chapterTitle.trim().isNotEmpty
        ? page.chapterTitle.trim()
        : page.title.trim();
    final String displayTitle = rawTitle.isEmpty
        ? '阅读'
        : ChineseConverter.instance.convert(rawTitle);
    final String progressLabel = _readerPageCountLabel(page);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          offset: visible ? Offset.zero : const Offset(0, -1.05),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            opacity: visible ? 1 : 0,
            child: Material(
              color: _readerHudTopSurfaceColor,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.white.withValues(alpha: 0.08),
                      width: 0.5,
                    ),
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: SizedBox(
                    height: 48,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        children: <Widget>[
                          IconButton(
                            onPressed: () {
                              _controller.hideChapterControls();
                              final Future<void> Function()? onExit =
                                  widget.onExitReader;
                              if (onExit != null) {
                                unawaited(onExit());
                              }
                            },
                            icon: const Icon(
                              Icons.arrow_back_rounded,
                              color: Colors.white,
                              size: 22,
                            ),
                            tooltip: '返回',
                          ),
                          Expanded(
                            child: Text(
                              displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15.5,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                          ConstrainedBox(
                            constraints: const BoxConstraints(minWidth: 48),
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: 4,
                                right: 12,
                              ),
                              child: Text(
                                progressLabel,
                                textAlign: TextAlign.end,
                                maxLines: 1,
                                softWrap: false,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.82),
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: const <FontFeature>[
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReaderBottomHudOverlay(
    BuildContext context,
    ReaderPageData page,
  ) {
    final bool visible = _controller.isChapterControlsVisible;
    final bool wide = usesWideLayout(context);
    final ReaderPreferences preferences = _controller.preferences;
    final int imageCount = page.imageUrls.length;
    final int currentImageIndex = imageCount == 0
        ? 0
        : (_controller.isPaged
                  ? _controller.currentPageIndex
                  : _controller.visibleImageIndex)
              .clamp(0, imageCount - 1);
    final bool isDarkTheme = Theme.of(context).brightness == Brightness.dark;
    final bool hasPrev = page.prevHref.trim().isNotEmpty;
    final bool hasNext = page.nextHref.trim().isNotEmpty;

    final Widget panel = Material(
      color: _readerHudSurfaceColor,
      borderRadius: wide
          ? const BorderRadius.vertical(top: Radius.circular(18))
          : BorderRadius.zero,
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: Colors.white.withValues(alpha: 0.09),
              width: 0.5,
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
                child: Row(
                  children: <Widget>[
                    _buildHudChapterStepButton(
                      label: '上一话',
                      enabled: hasPrev,
                      onTap: () {
                        _controller.noteUserInteraction();
                        unawaited(_navigateToHref(page.prevHref, page));
                      },
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: imageCount > 1
                          ? ReaderProgressSeekBar(
                              currentIndex: currentImageIndex,
                              totalCount: imageCount,
                              labelColor: Colors.white.withValues(alpha: 0.78),
                              activeTrackColor: Colors.white,
                              thumbColor: Colors.white,
                              inactiveTrackColor: Colors.white.withValues(
                                alpha: 0.24,
                              ),
                              onInteraction: () {
                                _controller.noteUserInteraction();
                                _controller.cancelAutoTurn();
                              },
                              onSeek: (int index) =>
                                  _seekReaderToImageIndex(context, page, index),
                            )
                          : Center(
                              child: Text(
                                _readerPageCountLabel(page),
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.76),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(width: 4),
                    _buildHudChapterStepButton(
                      label: '下一话',
                      enabled: hasNext,
                      onTap: () {
                        _controller.noteUserInteraction();
                        unawaited(_navigateToHref(page.nextHref, page));
                      },
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                thickness: 0.5,
                color: Colors.white.withValues(alpha: 0.09),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: _buildHudActionItem(
                        icon: Icons.format_list_bulleted_rounded,
                        label: '目录',
                        onTap: () {
                          _controller.hideChapterControls();
                          unawaited(_showReaderCatalogSheet(context, page));
                        },
                      ),
                    ),
                    Expanded(
                      child: _buildHudActionItem(
                        icon: Icons.home_rounded,
                        label: '首页',
                        onTap: () {
                          _controller.hideChapterControls();
                          final Future<void> Function()? onHome =
                              widget.onExitToHome ?? widget.onExitReader;
                          if (onHome != null) {
                            unawaited(onHome());
                          }
                        },
                      ),
                    ),
                    Expanded(
                      child: _buildHudActionItem(
                        icon: Icons.settings_rounded,
                        label: '设置',
                        onTap: () {
                          _controller.hideChapterControls();
                          unawaited(_showReaderSettingsSheet());
                        },
                      ),
                    ),
                    Expanded(
                      child: _buildHudActionItem(
                        icon: Icons.refresh_rounded,
                        label: '刷新',
                        onTap: () {
                          _controller.hideChapterControls();
                          unawaited(_reloadCurrentChapter(page));
                        },
                      ),
                    ),
                    Expanded(
                      child: _buildHudActionItem(
                        icon: isDarkTheme
                            ? Icons.light_mode_rounded
                            : Icons.dark_mode_rounded,
                        label: isDarkTheme ? '日间模式' : '夜间模式',
                        onTap: () => _toggleReaderDarkMode(isDarkTheme),
                      ),
                    ),
                    Expanded(
                      child: _buildHudActionItem(
                        icon: preferences.fullscreen
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                        label: preferences.fullscreen ? '关闭全屏' : '开启全屏',
                        onTap: () {
                          unawaited(
                            widget.services.preferencesController
                                .updateReaderPreferences(
                                  (ReaderPreferences current) => current
                                      .copyWith(fullscreen: !current.fullscreen),
                                ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          offset: visible ? Offset.zero : const Offset(0, 1.05),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            opacity: visible ? 1 : 0,
            child: wide
                ? Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: kWideReaderControlsMaxWidth,
                      ),
                      child: panel,
                    ),
                  )
                : panel,
          ),
        ),
      ),
    );
  }

  Widget _buildHudChapterStepButton({
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            color: Colors.white.withValues(alpha: enabled ? 0.94 : 0.34),
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildHudActionItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              color: Colors.white.withValues(alpha: 0.92),
              size: 22,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.86),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleReaderDarkMode(bool currentlyDark) {
    final AppThemePreference nextTheme = currentlyDark
        ? AppThemePreference.pureWhite
        : AppThemePreference.pureBlack;
    unawaited(
      widget.services.preferencesController.setThemePreference(nextTheme),
    );
  }

  Future<void> _reloadCurrentChapter(ReaderPageData page) async {
    _evictSegmentImages(<ReaderPageData>[page]);
    final Future<void> Function(ReaderPageData page)? onReload =
        widget.onReloadChapter;
    if (onReload != null) {
      _showNotice('正在刷新当前章节...');
      await onReload(page);
      return;
    }
    _controller.setPage(page, previousUri: page.uri, forceRestore: true);
    _showNotice('已重新加载当前章节');
  }

  Future<void> _showReaderCatalogSheet(
    BuildContext context,
    ReaderPageData page,
  ) async {
    final Future<DetailPageData?> Function(ReaderPageData page)? loadCatalog =
        widget.onLoadCatalog;
    if (loadCatalog == null) {
      if (widget.onExitReader != null) {
        await widget.onExitReader!();
      }
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext sheetContext) {
        return _ReaderCatalogSheet(
          currentPage: page,
          loadCatalog: () => loadCatalog(page),
          onSelectChapter:
              ({
                required String href,
                required String prevHref,
                required String nextHref,
                required String catalogHref,
              }) {
                Navigator.of(sheetContext).pop();
                if (_chapterPathKey(href) == _chapterPathKey(page.uri)) {
                  return;
                }
                unawaited(
                  widget.onRequestChapterNavigation(
                    href,
                    prevHref: prevHref,
                    nextHref: nextHref,
                    catalogHref: catalogHref,
                  ),
                );
              },
          onOpenDetail: widget.onExitReader == null
              ? null
              : () {
                  Navigator.of(sheetContext).pop();
                  unawaited(widget.onExitReader!());
                },
        );
      },
    );
  }
}

String _chapterPathKey(String rawHref) {
  final String trimmed = rawHref.trim();
  if (trimmed.isEmpty) return '';
  final Uri? uri = Uri.tryParse(trimmed);
  final String path = (uri?.path ?? trimmed).trim().toLowerCase();
  if (path.length > 1 && path.endsWith('/')) {
    return path.substring(0, path.length - 1);
  }
  return path;
}

class _ReaderCatalogSheet extends StatefulWidget {
  const _ReaderCatalogSheet({
    required this.currentPage,
    required this.loadCatalog,
    required this.onSelectChapter,
    this.onOpenDetail,
  });

  final ReaderPageData currentPage;
  final Future<DetailPageData?> Function() loadCatalog;
  final void Function({
    required String href,
    required String prevHref,
    required String nextHref,
    required String catalogHref,
  })
  onSelectChapter;
  final VoidCallback? onOpenDetail;

  @override
  State<_ReaderCatalogSheet> createState() => _ReaderCatalogSheetState();
}

class _ReaderCatalogSheetState extends State<_ReaderCatalogSheet> {
  static const double _gridMainAxisExtent = 42;
  static const double _gridSpacing = 8;
  static const int _gridColumns = 3;

  DetailPageData? _detail;
  bool _loading = true;
  String _error = '';
  int _selectedGroupIndex = 0;
  bool _descending = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  List<ChapterGroupData> _groupsFor(DetailPageData detail) {
    if (detail.chapterGroups.isNotEmpty) {
      return detail.chapterGroups
          .where((ChapterGroupData group) => group.chapters.isNotEmpty)
          .toList(growable: false);
    }
    if (detail.chapters.isNotEmpty) {
      return <ChapterGroupData>[
        ChapterGroupData(label: '全部章节', chapters: detail.chapters),
      ];
    }
    return const <ChapterGroupData>[];
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final DetailPageData? loaded = await widget.loadCatalog();
      if (!mounted) return;
      if (loaded == null) {
        setState(() {
          _loading = false;
          _error = '未能获取章节目录';
        });
        return;
      }
      final List<ChapterGroupData> groups = _groupsFor(loaded);
      final String activeKey = _chapterPathKey(widget.currentPage.uri);
      int matchedGroup = 0;
      for (int i = 0; i < groups.length; i += 1) {
        if (groups[i].chapters.any(
          (ChapterData item) => _chapterPathKey(item.href) == activeKey,
        )) {
          matchedGroup = i;
          break;
        }
      }
      setState(() {
        _detail = loaded;
        _selectedGroupIndex = matchedGroup;
        _loading = false;
      });
      _scrollToActiveChapter();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '目录加载失败，请稍后重试';
      });
    }
  }

  void _scrollToActiveChapter() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients || _detail == null) return;
      final List<ChapterGroupData> groups = _groupsFor(_detail!);
      if (_selectedGroupIndex >= groups.length) return;
      final List<ChapterData> ordered = _displayChapters(
        groups[_selectedGroupIndex].chapters,
      );
      final String activeKey = _chapterPathKey(widget.currentPage.uri);
      final int activeIndex = ordered.indexWhere(
        (ChapterData item) => _chapterPathKey(item.href) == activeKey,
      );
      if (activeIndex < 0) return;
      final int row = activeIndex ~/ _gridColumns;
      final double target = math.max(
        0,
        (row - 2) * (_gridMainAxisExtent + _gridSpacing),
      );
      _scrollController.jumpTo(
        target.clamp(0.0, _scrollController.position.maxScrollExtent),
      );
    });
  }

  List<ChapterData> _displayChapters(List<ChapterData> raw) {
    return _descending ? raw.reversed.toList(growable: false) : raw;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.72;
    final DetailPageData? detail = _detail;
    final List<ChapterGroupData> groups = detail == null
        ? const <ChapterGroupData>[]
        : _groupsFor(detail);
    final List<ChapterData> rawChapters =
        groups.isNotEmpty && _selectedGroupIndex < groups.length
        ? groups[_selectedGroupIndex].chapters
        : const <ChapterData>[];
    final List<ChapterData> chapters = _displayChapters(rawChapters);
    final String activeKey = _chapterPathKey(widget.currentPage.uri);
    final String headerTitle = detail != null && detail.title.trim().isNotEmpty
        ? ChineseConverter.instance.convert(detail.title.trim())
        : '章节目录';

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Material(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      chapters.isEmpty
                          ? headerTitle
                          : '$headerTitle (${rawChapters.length})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (rawChapters.length > 1)
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _descending = !_descending;
                        });
                        _scrollToActiveChapter();
                      },
                      icon: Icon(
                        _descending
                            ? Icons.arrow_downward_rounded
                            : Icons.arrow_upward_rounded,
                        size: 16,
                      ),
                      label: Text(_descending ? '倒序' : '正序'),
                    ),
                  if (widget.onOpenDetail != null)
                    TextButton(
                      onPressed: widget.onOpenDetail,
                      child: const Text('漫画详情'),
                    ),
                ],
              ),
            ),
            if (groups.length > 1)
              SizedBox(
                height: 36,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  scrollDirection: Axis.horizontal,
                  itemCount: groups.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (BuildContext context, int index) {
                    final bool selected = index == _selectedGroupIndex;
                    return ChoiceChip(
                      label: Text(
                        ChineseConverter.instance.convert(groups[index].label),
                      ),
                      selected: selected,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) {
                        if (_selectedGroupIndex == index) return;
                        setState(() {
                          _selectedGroupIndex = index;
                        });
                        _scrollToActiveChapter();
                      },
                    );
                  },
                ),
              ),
            if (groups.length > 1) const SizedBox(height: 8),
            const Divider(height: 1),
            Flexible(
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 48),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _error.isNotEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 36),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(_error),
                          const SizedBox(height: 8),
                          FilledButton.tonal(
                            onPressed: () => unawaited(_fetch()),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    )
                  : chapters.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(child: Text('暂无章节')),
                    )
                  : GridView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: _gridColumns,
                            mainAxisSpacing: _gridSpacing,
                            crossAxisSpacing: _gridSpacing,
                            mainAxisExtent: _gridMainAxisExtent,
                          ),
                      itemCount: chapters.length,
                      itemBuilder: (BuildContext context, int index) {
                        final ChapterData chapter = chapters[index];
                        final bool isCurrent =
                            _chapterPathKey(chapter.href) == activeKey;
                        final int rawIndex = _descending
                            ? (rawChapters.length - 1 - index)
                            : index;
                        final String prevHref = rawIndex > 0
                            ? rawChapters[rawIndex - 1].href
                            : '';
                        final String nextHref =
                            rawIndex + 1 < rawChapters.length
                            ? rawChapters[rawIndex + 1].href
                            : '';
                        return Material(
                          color: isCurrent
                              ? colorScheme.primaryContainer
                              : colorScheme.surfaceContainerHighest.withValues(
                                  alpha: 0.55,
                                ),
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => widget.onSelectChapter(
                              href: chapter.href,
                              prevHref: prevHref,
                              nextHref: nextHref,
                              catalogHref:
                                  detail?.uri ?? widget.currentPage.catalogHref,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: Center(
                                child: Text(
                                  ChineseConverter.instance.convert(
                                    chapter.label,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isCurrent
                                        ? colorScheme.onPrimaryContainer
                                        : colorScheme.onSurface,
                                    fontSize: 12.5,
                                    fontWeight: isCurrent
                                        ? FontWeight.w800
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
