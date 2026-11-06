part of '../profile_page_view.dart';

/// 「我的收藏」书架 Sliver 视图：参考拷贝漫画官方 App 的三列直角书封样式，
/// 直接挂载到 CustomScrollView 中实现按视口懒加载与触底自动续页。
class BookshelfSliverSection extends StatefulWidget {
  const BookshelfSliverSection({
    required this.items,
    required this.totalCount,
    required this.isLoading,
    required this.onOpenComic,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.loadMoreError,
    this.onLoadMore,
    this.hasUnreadUpdate,
    this.isUnread,
    this.onlyUnread = false,
    this.onOnlyUnreadChanged,
    this.progressListenable,
    this.onRemoveCollections,
    super.key,
  });

  final List<ProfileLibraryItem> items;
  final int totalCount;
  final bool isLoading;
  final bool hasMore;
  final bool isLoadingMore;
  final String? loadMoreError;
  final VoidCallback? onLoadMore;
  final ValueChanged<String> onOpenComic;
  final bool Function(ProfileLibraryItem item)? hasUnreadUpdate;
  final bool Function(ProfileLibraryItem item)? isUnread;
  final bool onlyUnread;
  final ValueChanged<bool>? onOnlyUnreadChanged;
  final Listenable? progressListenable;
  final Future<bool> Function(List<ProfileLibraryItem> items)?
  onRemoveCollections;

  @override
  State<BookshelfSliverSection> createState() => _BookshelfSliverSectionState();
}

class _BookshelfSliverSectionState extends State<BookshelfSliverSection> {
  final Set<String> _selectedHrefs = <String>{};
  bool _isEditing = false;
  bool _isRemoving = false;

  List<ProfileLibraryItem> get _visibleItems => widget.onlyUnread
      ? widget.items
            .where(
              (ProfileLibraryItem item) =>
                  (widget.isUnread ?? widget.hasUnreadUpdate)?.call(item) ??
                  false,
            )
            .toList(growable: false)
      : widget.items;

  @override
  void initState() {
    super.initState();
    widget.progressListenable?.addListener(_handleProgressChanged);
  }

  @override
  void didUpdateWidget(covariant BookshelfSliverSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onlyUnread != widget.onlyUnread) _selectedHrefs.clear();
    if (oldWidget.progressListenable != widget.progressListenable) {
      oldWidget.progressListenable?.removeListener(_handleProgressChanged);
      widget.progressListenable?.addListener(_handleProgressChanged);
    }
    if (_selectedHrefs.isNotEmpty) {
      final Set<String> validHrefs = _visibleItems
          .map((ProfileLibraryItem item) => item.href)
          .toSet();
      _selectedHrefs.removeWhere((String href) => !validHrefs.contains(href));
    }
    if (widget.items.isEmpty && _isEditing) {
      _isEditing = false;
      _selectedHrefs.clear();
    }
  }

  @override
  void dispose() {
    widget.progressListenable?.removeListener(_handleProgressChanged);
    super.dispose();
  }

  void _handleProgressChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _enterEditMode([String? initialHref]) {
    if (widget.onRemoveCollections == null || widget.items.isEmpty) {
      return;
    }
    setState(() {
      _isEditing = true;
      if (initialHref != null && initialHref.isNotEmpty) {
        _selectedHrefs.add(initialHref);
      }
    });
  }

  void _exitEditMode() {
    if (!_isEditing) return;
    setState(() {
      _isEditing = false;
      _selectedHrefs.clear();
    });
  }

  void _toggleSelection(String href) {
    if (_isRemoving || href.isEmpty) return;
    setState(() {
      if (!_selectedHrefs.remove(href)) {
        _selectedHrefs.add(href);
      }
    });
  }

  void _toggleSelectAll() {
    if (_isRemoving) return;
    setState(() {
      if (_selectedHrefs.length >= _visibleItems.length) {
        _selectedHrefs.clear();
      } else {
        _selectedHrefs
          ..clear()
          ..addAll(_visibleItems.map((ProfileLibraryItem item) => item.href));
      }
    });
  }

  Future<void> _removeSelected() async {
    final Future<bool> Function(List<ProfileLibraryItem> items)? remover =
        widget.onRemoveCollections;
    if (remover == null || _isRemoving || _selectedHrefs.isEmpty) {
      return;
    }
    final List<ProfileLibraryItem> selected = widget.items
        .where((ProfileLibraryItem item) => _selectedHrefs.contains(item.href))
        .toList(growable: false);
    if (selected.isEmpty) {
      return;
    }
    setState(() => _isRemoving = true);
    try {
      final bool removed = await remover(selected);
      if (!mounted) return;
      if (removed) {
        setState(() {
          _isEditing = false;
          _selectedHrefs.clear();
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isRemoving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final int effectiveTotal = widget.totalCount > widget.items.length
        ? widget.totalCount
        : widget.items.length;
    final List<ProfileLibraryItem> visibleItems = _visibleItems;

    final List<Widget> slivers = <Widget>[
      SliverToBoxAdapter(
        child: _BookshelfHeader(
          totalCount: effectiveTotal,
          itemCountOnPage: visibleItems.length,
          onlyUnread: widget.onlyUnread,
          onOnlyUnreadChanged: widget.onOnlyUnreadChanged,
          selectedCount: _selectedHrefs.length,
          isEditing: _isEditing,
          isRemoving: _isRemoving,
          canEdit:
              widget.onRemoveCollections != null && visibleItems.isNotEmpty,
          onStartEdit: _enterEditMode,
          onFinishEdit: _exitEditMode,
          onToggleSelectAll: _toggleSelectAll,
          onRemoveSelected: _removeSelected,
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
      if (widget.isLoading && widget.items.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: const LinearProgressIndicator(minHeight: 4),
            ),
          ),
        ),
    ];

    if (widget.isLoading && widget.items.isEmpty) {
      slivers.add(const SliverToBoxAdapter(child: _ProfileListLoader()));
    } else if (visibleItems.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Center(
              child: Text(
                ChineseConverter.instance.convert(
                  widget.onlyUnread ? '暂无未读漫画' : '还没有收藏的漫画。',
                ),
                style: TextStyle(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          ),
        ),
      );
    } else {
      slivers.add(
        _BookshelfSliverGrid(
          items: visibleItems,
          isEditing: _isEditing,
          selectedHrefs: _selectedHrefs,
          hasUnreadUpdate: widget.hasUnreadUpdate,
          onTapItem: (ProfileLibraryItem item) {
            if (_isEditing) {
              _toggleSelection(item.href);
            } else {
              widget.onOpenComic(item.href);
            }
          },
          onLongPressItem: widget.onRemoveCollections == null
              ? null
              : (ProfileLibraryItem item) {
                  if (_isEditing) {
                    _toggleSelection(item.href);
                  } else {
                    _enterEditMode(item.href);
                  }
                },
        ),
      );
    }
    // Keep pagination available even when a whole page has no unread matches.
    if (widget.hasMore || widget.items.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _BookshelfInfiniteFooter(
            totalCount: widget.onlyUnread
                ? visibleItems.length
                : effectiveTotal,
            loadedCount: visibleItems.length,
            hasMore: widget.hasMore,
            isLoading: widget.isLoading,
            isLoadingMore: widget.isLoadingMore,
            errorMessage: widget.loadMoreError,
            onLoadMore: widget.onLoadMore,
          ),
        ),
      );
    }

    return SliverMainAxisGroup(slivers: slivers);
  }
}

class _BookshelfHeader extends StatelessWidget {
  const _BookshelfHeader({
    required this.totalCount,
    required this.itemCountOnPage,
    required this.selectedCount,
    required this.isEditing,
    required this.isRemoving,
    required this.canEdit,
    required this.onStartEdit,
    required this.onFinishEdit,
    required this.onToggleSelectAll,
    required this.onRemoveSelected,
    required this.onlyUnread,
    this.onOnlyUnreadChanged,
  });

  final int totalCount;
  final int itemCountOnPage;
  final int selectedCount;
  final bool isEditing;
  final bool isRemoving;
  final bool canEdit;
  final VoidCallback onStartEdit;
  final VoidCallback onFinishEdit;
  final VoidCallback onToggleSelectAll;
  final VoidCallback onRemoveSelected;
  final bool onlyUnread;
  final ValueChanged<bool>? onOnlyUnreadChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final ChineseConverter converter = ChineseConverter.instance;

    if (isEditing) {
      final bool allSelected =
          itemCountOnPage > 0 && selectedCount >= itemCountOnPage;
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                converter.convert('已選 $selectedCount 部'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            TextButton(
              onPressed: isRemoving ? null : onToggleSelectAll,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: Text(converter.convert(allSelected ? '取消全選' : '全選')),
            ),
            const SizedBox(width: 4),
            FilledButton.tonal(
              onPressed: isRemoving || selectedCount == 0
                  ? null
                  : onRemoveSelected,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                foregroundColor: colorScheme.error,
              ),
              child: isRemoving
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(converter.convert('取消收藏')),
            ),
            const SizedBox(width: 4),
            TextButton(
              onPressed: isRemoving ? null : onFinishEdit,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: Text(converter.convert('完成')),
            ),
          ],
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              converter.convert('書架($totalCount)'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 19,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          if (onOnlyUnreadChanged != null) ...<Widget>[
            FilterChip(
              label: Text(converter.convert('只展示未读')),
              selected: onlyUnread,
              onSelected: onOnlyUnreadChanged,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 4),
          ],
          if (canEdit)
            InkWell(
              onTap: onStartEdit,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.edit_rounded,
                      size: 17,
                      color: colorScheme.onSurface.withValues(alpha: 0.75),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      converter.convert('編輯'),
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w500,
                        color: colorScheme.onSurface.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BookshelfSliverGrid extends StatelessWidget {
  const _BookshelfSliverGrid({
    required this.items,
    required this.isEditing,
    required this.selectedHrefs,
    required this.onTapItem,
    this.onLongPressItem,
    this.hasUnreadUpdate,
  });

  final List<ProfileLibraryItem> items;
  final bool isEditing;
  final Set<String> selectedHrefs;
  final ValueChanged<ProfileLibraryItem> onTapItem;
  final ValueChanged<ProfileLibraryItem>? onLongPressItem;
  final bool Function(ProfileLibraryItem item)? hasUnreadUpdate;

  static const int _mobileColumns = 3;
  static const double _crossAxisSpacing = 11;
  static const double _mainAxisSpacing = 20;
  static const double _coverAspectRatio = 0.74;

  @override
  Widget build(BuildContext context) {
    final bool isWide = usesWideLayout(context);
    final TextScaler textScaler = MediaQuery.textScalerOf(context);
    final double titleFontSize = isWide ? 14.0 : 12.5;
    final double metaFontSize = isWide ? 12.0 : 11.5;
    final double unreadFontSize = isWide ? 11.5 : 10.6;
    final double titleHeight = textScaler.scale(titleFontSize * 1.32 * 2 + 1);
    final double metaLineHeight = textScaler.scale(metaFontSize * 1.25 + 1);

    return SliverLayoutBuilder(
      builder: (BuildContext context, constraints) {
        final double maxWidth = constraints.crossAxisExtent;
        final int crossAxisCount = responsiveComicCrossAxisCount(
          context,
          maxWidth,
          spacing: _crossAxisSpacing,
          mobileCount: _mobileColumns,
        );
        final double spacingWidth = _crossAxisSpacing * (crossAxisCount - 1);
        final double itemWidth = ((maxWidth - spacingWidth) / crossAxisCount)
            .clamp(0.0, maxWidth)
            .toDouble();
        if (itemWidth <= 0) {
          return const SliverToBoxAdapter(child: SizedBox.shrink());
        }
        final double coverHeight = itemWidth / _coverAspectRatio;
        final double itemHeight =
            coverHeight +
            6 +
            titleHeight +
            5 +
            metaLineHeight +
            2 +
            metaLineHeight +
            2;
        final double childAspectRatio = itemHeight <= 0
            ? 0.50
            : itemWidth / itemHeight;

        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: _crossAxisSpacing,
            mainAxisSpacing: _mainAxisSpacing,
            childAspectRatio: childAspectRatio,
          ),
          delegate: SliverChildBuilderDelegate(
            (BuildContext context, int index) {
              final ProfileLibraryItem item = items[index];
              return RepaintBoundary(
                child: _BookshelfCard(
                  key: ValueKey<String>(item.href),
                  item: item,
                  itemWidth: itemWidth,
                  isEditing: isEditing,
                  isSelected: selectedHrefs.contains(item.href),
                  hasUnreadUpdate: hasUnreadUpdate?.call(item) ?? false,
                  coverAspectRatio: _coverAspectRatio,
                  titleFontSize: titleFontSize,
                  metaFontSize: metaFontSize,
                  unreadFontSize: unreadFontSize,
                  titleHeight: titleHeight,
                  metaLineHeight: metaLineHeight,
                  onTap: () => onTapItem(item),
                  onLongPress: onLongPressItem == null
                      ? null
                      : () => onLongPressItem!(item),
                ),
              );
            },
            childCount: items.length,
            addAutomaticKeepAlives: false,
          ),
        );
      },
    );
  }
}

class _BookshelfInfiniteFooter extends StatelessWidget {
  const _BookshelfInfiniteFooter({
    required this.totalCount,
    required this.loadedCount,
    required this.hasMore,
    required this.isLoading,
    required this.isLoadingMore,
    this.errorMessage,
    this.onLoadMore,
  });

  final int totalCount;
  final int loadedCount;
  final bool hasMore;
  final bool isLoading;
  final bool isLoadingMore;
  final String? errorMessage;
  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final ChineseConverter converter = ChineseConverter.instance;

    if (hasMore &&
        !isLoading &&
        !isLoadingMore &&
        errorMessage == null &&
        onLoadMore != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onLoadMore?.call();
      });
    }

    if (errorMessage != null && errorMessage!.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Center(
          child: TextButton.icon(
            onPressed: onLoadMore,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: Text(converter.convert('加載失敗，點擊重試')),
          ),
        ),
      );
    }

    if (hasMore || isLoadingMore) {
      return Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colorScheme.onSurface.withValues(alpha: 0.45),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              converter.convert('正在加載更多…'),
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurface.withValues(alpha: 0.48),
              ),
            ),
          ],
        ),
      );
    }

    if (loadedCount <= 0) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Center(
        child: Text(
          converter.convert('已顯示全部 $totalCount 部'),
          style: TextStyle(
            fontSize: 12,
            color: colorScheme.onSurface.withValues(alpha: 0.38),
          ),
        ),
      ),
    );
  }
}

class _BookshelfCard extends StatelessWidget {
  const _BookshelfCard({
    required this.item,
    required this.itemWidth,
    required this.isEditing,
    required this.isSelected,
    required this.hasUnreadUpdate,
    required this.coverAspectRatio,
    required this.titleFontSize,
    required this.metaFontSize,
    required this.unreadFontSize,
    required this.titleHeight,
    required this.metaLineHeight,
    required this.onTap,
    this.onLongPress,
    super.key,
  });

  final ProfileLibraryItem item;
  final double itemWidth;
  final bool isEditing;
  final bool isSelected;
  final bool hasUnreadUpdate;
  final double coverAspectRatio;
  final double titleFontSize;
  final double metaFontSize;
  final double unreadFontSize;
  final double titleHeight;
  final double metaLineHeight;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  static const Color _unreadHighlightColor = Color(0xFFE07A2A);
  static const double _coverRadius = 2.5;

  static String _formatDate(String raw) {
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return '--';
    }
    final RegExpMatch? match = RegExp(
      r'^(\d{4}-\d{2}-\d{2})',
    ).firstMatch(trimmed);
    return match != null ? match.group(1)! : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final ChineseConverter converter = ChineseConverter.instance;
    final Color metaColor = colorScheme.onSurface.withValues(alpha: 0.45);
    final String dateText = _formatDate(item.updatedAt);
    final String chapterText = item.secondaryText.trim();

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AspectRatio(
            aspectRatio: coverAspectRatio,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_coverRadius),
                border: Border.all(
                  color: isEditing && isSelected
                      ? colorScheme.primary
                      : colorScheme.onSurface.withValues(alpha: 0.08),
                  width: isEditing && isSelected ? 1.8 : 0.5,
                ),
              ),
              position: DecorationPosition.foreground,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_coverRadius),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    CoverImage(
                      imageUrl: item.coverUrl,
                      aspectRatio: coverAspectRatio,
                      borderRadius: _coverRadius,
                      logicalWidth: itemWidth,
                    ),
                    if (isEditing) ...<Widget>[
                      if (isSelected)
                        ColoredBox(color: Colors.black.withValues(alpha: 0.16)),
                      Positioned(
                        top: 6,
                        right: 6,
                        child: _BookshelfSelectionBadge(selected: isSelected),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: titleHeight,
            child: Text(
              converter.convert(item.title),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: titleFontSize,
                height: 1.32,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 5),
          SizedBox(
            height: metaLineHeight,
            child: Text(
              dateText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: metaColor,
                fontSize: metaFontSize,
                height: 1.25,
              ),
            ),
          ),
          const SizedBox(height: 2),
          SizedBox(
            height: metaLineHeight,
            child: hasUnreadUpdate
                ? Text(
                    converter.convert('有更新'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _unreadHighlightColor,
                      fontSize: unreadFontSize,
                      letterSpacing: -0.2,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : Text(
                    chapterText.isEmpty ? '--' : converter.convert(chapterText),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: metaColor,
                      fontSize: metaFontSize,
                      height: 1.25,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _BookshelfSelectionBadge extends StatelessWidget {
  const _BookshelfSelectionBadge({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: selected
            ? colorScheme.primary
            : Colors.black.withValues(alpha: 0.38),
        shape: BoxShape.circle,
        border: Border.all(
          color: selected
              ? colorScheme.primary
              : Colors.white.withValues(alpha: 0.88),
          width: 1.5,
        ),
      ),
      child: selected
          ? Icon(Icons.check_rounded, size: 14, color: colorScheme.onPrimary)
          : null,
    );
  }
}
