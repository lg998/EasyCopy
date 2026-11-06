import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:reader/models/app_preferences.dart';
import 'package:reader/models/chapter_comment.dart';
import 'package:reader/models/page_models.dart';
import 'package:reader/services/reader_comment_utils.dart';
import 'package:reader/services/site_api_client.dart';
import 'package:reader/services/site_session.dart';

class _ChapterCommentEntry {
  _ChapterCommentEntry({required VoidCallback onScroll}) {
    scrollController.addListener(onScroll);
  }

  final TextEditingController textController = TextEditingController();
  final ScrollController scrollController = ScrollController();

  List<ChapterComment> items = const <ChapterComment>[];
  String error = '';
  int total = 0;
  int loadedStartOffset = 0;
  bool hasLoadedOnce = false;
  bool isLoading = false;
  bool isLoadingMore = false;
  bool isSubmitting = false;

  void resetData({required bool clearText}) {
    items = const <ChapterComment>[];
    error = '';
    total = 0;
    loadedStartOffset = 0;
    hasLoadedOnce = false;
    isLoading = false;
    isLoadingMore = false;
    if (clearText) {
      textController.clear();
    }
    if (scrollController.hasClients) {
      scrollController.jumpTo(0);
    }
  }

  void dispose() {
    textController.dispose();
    scrollController.dispose();
  }
}

class ReaderCommentsController {
  ReaderCommentsController({
    required this.apiClient,
    required this.session,
    required this.preferences,
    required this.currentPage,
    required this.isChapterActive,
    required this.chapterIdForPage,
    required this.isDisposed,
    required this.notify,
    required this.onRequestAuth,
    required this.onLogoutForExpiredSession,
    required this.onShowMessage,
  });

  final SiteApiClient apiClient;
  final SiteSession session;
  final ReaderPreferences Function() preferences;
  final ReaderPageData? Function() currentPage;
  final bool Function(String chapterId) isChapterActive;
  final String Function(ReaderPageData page) chapterIdForPage;
  final bool Function() isDisposed;
  final VoidCallback notify;
  final Future<void> Function() onRequestAuth;
  final Future<void> Function() onLogoutForExpiredSession;
  final void Function(String message) onShowMessage;

  final Map<String, _ChapterCommentEntry> _entries =
      <String, _ChapterCommentEntry>{};
  final TextEditingController _fallbackTextController = TextEditingController();
  final ScrollController _fallbackScrollController = ScrollController();

  String get _currentChapterId {
    final ReaderPageData? page = currentPage();
    return page == null ? '' : chapterIdForPage(page);
  }

  _ChapterCommentEntry _entryForChapterId(
    String chapterId, {
    ReaderPageData? pageForScroll,
  }) {
    return _entries.putIfAbsent(
      chapterId,
      () => _ChapterCommentEntry(
        onScroll: () => _handleEntryScroll(chapterId, pageForScroll),
      ),
    );
  }

  List<ChapterComment> get items =>
      _entries[_currentChapterId]?.items ?? const <ChapterComment>[];
  String get chapterId => _currentChapterId;
  String get error => _entries[_currentChapterId]?.error ?? '';
  bool get isLoading => _entries[_currentChapterId]?.isLoading ?? false;
  bool get isSubmitting => _entries[_currentChapterId]?.isSubmitting ?? false;

  TextEditingController get textController {
    final String id = _currentChapterId;
    if (id.isEmpty) return _fallbackTextController;
    return _entryForChapterId(id, pageForScroll: currentPage()).textController;
  }

  ScrollController get scrollController {
    final String id = _currentChapterId;
    if (id.isEmpty) return _fallbackScrollController;
    return _entryForChapterId(id, pageForScroll: currentPage()).scrollController;
  }

  List<ChapterComment> itemsFor(ReaderPageData page) {
    final String id = chapterIdForPage(page);
    if (id.isEmpty) return const <ChapterComment>[];
    return _entries[id]?.items ?? const <ChapterComment>[];
  }

  String errorFor(ReaderPageData page) {
    final String id = chapterIdForPage(page);
    if (id.isEmpty) return '';
    return _entries[id]?.error ?? '';
  }

  bool isLoadingFor(ReaderPageData page) {
    final String id = chapterIdForPage(page);
    if (id.isEmpty) return false;
    return _entries[id]?.isLoading ?? false;
  }

  bool isSubmittingFor(ReaderPageData page) {
    final String id = chapterIdForPage(page);
    if (id.isEmpty) return false;
    return _entries[id]?.isSubmitting ?? false;
  }

  TextEditingController textControllerFor(ReaderPageData page) {
    final String id = chapterIdForPage(page);
    if (id.isEmpty) return _fallbackTextController;
    return _entryForChapterId(id, pageForScroll: page).textController;
  }

  ScrollController scrollControllerFor(ReaderPageData page) {
    final String id = chapterIdForPage(page);
    if (id.isEmpty) return _fallbackScrollController;
    return _entryForChapterId(id, pageForScroll: page).scrollController;
  }

  bool shouldShowComments(ReaderPageData page) {
    return preferences().showChapterComments &&
        chapterIdForPage(page).isNotEmpty;
  }

  void retainChapters(Set<String> retainedChapterIds) {
    final List<String> toRemove = _entries.keys
        .where((String key) => !retainedChapterIds.contains(key))
        .toList(growable: false);
    if (toRemove.isEmpty) return;
    for (final String key in toRemove) {
      _entries.remove(key)?.dispose();
    }
  }

  void clear() {
    if (_entries.isEmpty) return;
    final List<_ChapterCommentEntry> removed = _entries.values.toList(
      growable: false,
    );
    _entries.clear();
    for (final _ChapterCommentEntry entry in removed) {
      entry.dispose();
    }
  }

  void prepare(ReaderPageData page, {required bool resetForNewChapter}) {
    final String nextChapterId = chapterIdForPage(page);
    if (!preferences().showChapterComments || nextChapterId.isEmpty) {
      clear();
      _notify();
      return;
    }

    final _ChapterCommentEntry entry = _entryForChapterId(
      nextChapterId,
      pageForScroll: page,
    );
    if (resetForNewChapter) {
      entry.resetData(clearText: true);
    } else if (entry.hasLoadedOnce || entry.isLoading) {
      return;
    }
    unawaited(load(page));
  }

  Future<void> load(ReaderPageData page, {bool append = false}) async {
    final String nextChapterId = chapterIdForPage(page);
    if (nextChapterId.isEmpty || !preferences().showChapterComments) {
      return;
    }
    if (!isDisposed() && !isChapterActive(nextChapterId)) {
      return;
    }

    final _ChapterCommentEntry entry = _entryForChapterId(
      nextChapterId,
      pageForScroll: page,
    );
    final List<ChapterComment> existingComments = append
        ? entry.items
        : const <ChapterComment>[];
    ReaderCommentPageWindow? appendWindow;
    if (append) {
      if (entry.isLoading || entry.isLoadingMore) return;
      appendWindow = nextCommentWindow(
        loadedStartOffset: entry.loadedStartOffset,
      );
      if (appendWindow.isEmpty) return;
    }

    if (!append) {
      entry.error = '';
      entry.items = const <ChapterComment>[];
      entry.total = 0;
      entry.loadedStartOffset = 0;
      entry.isLoading = true;
      entry.isLoadingMore = false;
      _notify();
    } else {
      entry.isLoadingMore = true;
      _notify();
    }

    try {
      final (
        ChapterCommentFeed feed,
        int loadedStartOffset,
        int resolvedTotal,
      ) = append
          ? await _loadAscendingPage(
              chapterId: nextChapterId,
              window: appendWindow!,
              fallbackTotal: entry.total,
            )
          : await _loadInitialPage(nextChapterId);
      if (isDisposed()) return;
      final _ChapterCommentEntry? activeEntry = _entries[nextChapterId];
      if (activeEntry == null || !isChapterActive(nextChapterId)) {
        if (activeEntry != null) {
          activeEntry.isLoading = false;
          activeEntry.isLoadingMore = false;
        }
        return;
      }
      activeEntry.items = append
          ? mergeReaderCommentsByIdentity(existingComments, feed.comments)
          : mergeReaderCommentsByIdentity(
              const <ChapterComment>[],
              feed.comments,
            );
      activeEntry.total = resolvedTotal > 0
          ? resolvedTotal
          : activeEntry.items.length;
      activeEntry.loadedStartOffset = loadedStartOffset;
      activeEntry.hasLoadedOnce = true;
      activeEntry.error = '';
      activeEntry.isLoading = false;
      activeEntry.isLoadingMore = false;
      _notify();
    } catch (error) {
      if (isDisposed()) return;
      final _ChapterCommentEntry? activeEntry = _entries[nextChapterId];
      if (activeEntry == null || !isChapterActive(nextChapterId)) {
        if (activeEntry != null) {
          activeEntry.isLoading = false;
          activeEntry.isLoadingMore = false;
        }
        return;
      }
      final String message = error is SiteApiException
          ? error.message
          : '评论加载失败，请稍后重试。';
      if (append && existingComments.isNotEmpty) {
        activeEntry.isLoading = false;
        activeEntry.isLoadingMore = false;
        _notify();
        return;
      }
      activeEntry.error = message;
      activeEntry.items = const <ChapterComment>[];
      activeEntry.total = 0;
      activeEntry.loadedStartOffset = 0;
      activeEntry.isLoading = false;
      activeEntry.isLoadingMore = false;
      _notify();
    }
  }

  void handleScroll() {
    final ReaderPageData? current = currentPage();
    if (current == null) return;
    _handleEntryScroll(chapterIdForPage(current), current);
  }

  void _handleEntryScroll(String targetChapterId, ReaderPageData? fallbackPage) {
    if (targetChapterId.isEmpty || !preferences().showChapterComments) return;
    final _ChapterCommentEntry? entry = _entries[targetChapterId];
    if (entry == null ||
        !entry.scrollController.hasClients ||
        entry.isLoading ||
        entry.isLoadingMore ||
        !isChapterActive(targetChapterId)) {
      return;
    }
    final ScrollPosition position = entry.scrollController.position;
    if (position.maxScrollExtent <= 0) return;
    if (position.maxScrollExtent - position.pixels > 180) return;
    final ReaderPageData? page = fallbackPage ?? currentPage();
    if (page == null) return;
    unawaited(load(page, append: true));
  }

  Future<void> submit(ReaderPageData page) async {
    final String nextChapterId = chapterIdForPage(page);
    if (nextChapterId.isEmpty) {
      onShowMessage('章节评论信息缺失，请刷新后重试。');
      return;
    }
    final _ChapterCommentEntry entry = _entryForChapterId(
      nextChapterId,
      pageForScroll: page,
    );
    if (entry.isSubmitting) return;
    final String content = entry.textController.text.trim();
    if (content.isEmpty) {
      onShowMessage('请输入评论内容。');
      return;
    }

    if (!session.isAuthenticated || (session.token ?? '').isEmpty) {
      await onRequestAuth();
      if (!session.isAuthenticated || (session.token ?? '').isEmpty) {
        return;
      }
    }

    if (isDisposed()) return;
    entry.isSubmitting = true;
    _notify();

    try {
      await apiClient.postChapterComment(
        chapterId: nextChapterId,
        content: content,
      );
      entry.textController.clear();
      onShowMessage('已发送评论');
      await load(page);
    } catch (error) {
      final String message = error is SiteApiException
          ? error.message
          : '评论发送失败，请稍后重试。';
      if (message.contains('登录已失效')) {
        await onLogoutForExpiredSession();
      }
      if (!isDisposed()) {
        onShowMessage(message);
      }
    } finally {
      entry.isSubmitting = false;
      _notify();
    }
  }

  void dispose() {
    clear();
    _fallbackTextController.dispose();
    _fallbackScrollController.dispose();
  }

  Future<(ChapterCommentFeed, int, int)> _loadInitialPage(
    String chapterId,
  ) async {
    final ChapterCommentFeed probe = await apiClient.loadChapterComments(
      chapterId: chapterId,
      limit: 1,
      offset: 0,
    );
    final int probeTotal = probe.total > 0
        ? probe.total
        : probe.comments.length;
    if (probeTotal <= 0) {
      return (probe, 0, 0);
    }

    final ReaderCommentPageWindow window = probeTotal <= 1
        ? const ReaderCommentPageWindow(offset: 0, limit: readerCommentPageSize)
        : initialCommentWindow(total: probeTotal);
    final ChapterCommentFeed rawFeed = await apiClient.loadChapterComments(
      chapterId: chapterId,
      limit: window.limit,
      offset: window.offset,
    );
    final int resolvedTotal = rawFeed.total > 0
        ? rawFeed.total
        : math.max(probeTotal, rawFeed.comments.length);
    return (
      ChapterCommentFeed(
        total: resolvedTotal,
        comments: normalizeCommentPage(rawFeed.comments),
      ),
      window.offset,
      resolvedTotal,
    );
  }

  Future<(ChapterCommentFeed, int, int)> _loadAscendingPage({
    required String chapterId,
    required ReaderCommentPageWindow window,
    required int fallbackTotal,
  }) async {
    final ChapterCommentFeed rawFeed = await apiClient.loadChapterComments(
      chapterId: chapterId,
      limit: window.limit,
      offset: window.offset,
    );
    final int resolvedTotal = rawFeed.total > 0 ? rawFeed.total : fallbackTotal;
    return (
      ChapterCommentFeed(
        total: resolvedTotal,
        comments: normalizeCommentPage(rawFeed.comments),
      ),
      window.offset,
      resolvedTotal,
    );
  }

  void _notify() {
    if (!isDisposed()) {
      notify();
    }
  }
}
