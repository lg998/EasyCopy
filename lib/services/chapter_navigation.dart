import 'package:reader/config/app_config.dart';
import 'package:reader/models/page_models.dart';
import 'package:reader/services/uri_keys.dart';

/// Reading stays within the group containing the current chapter.
class ChapterNavigation {
  const ChapterNavigation._();

  static String startReadingHref(
    DetailPageData page, {
    String lastReadChapterPathKey = '',
  }) {
    final Iterable<ChapterData> allChapters = <ChapterData>[
      ...page.chapterGroups.expand((ChapterGroupData group) => group.chapters),
      ...page.chapters,
    ];
    final String lastReadKey = UriKeys.pathKey(lastReadChapterPathKey);
    if (lastReadKey.isNotEmpty) {
      for (final ChapterData chapter in allChapters) {
        final String href = chapter.href.trim();
        if (href.isNotEmpty && UriKeys.pathKey(href) == lastReadKey) {
          return href;
        }
      }
      final Uri? detailUri = Uri.tryParse(page.uri.trim());
      if (detailUri != null && detailUri.hasScheme) {
        return AppConfig.resolveNavigationUri(
          lastReadKey,
          currentUri: detailUri,
        ).toString();
      }
      return lastReadKey;
    }

    final String explicitStartHref = page.startReadingHref.trim();
    if (explicitStartHref.isNotEmpty) {
      return explicitStartHref;
    }
    for (final ChapterData chapter in allChapters) {
      final String href = chapter.href.trim();
      if (href.isNotEmpty) {
        return href;
      }
    }
    return '';
  }

  static List<ChapterData> sequenceFor(DetailPageData page, String href) {
    final String key = UriKeys.pathKey(href);
    if (page.chapterGroups.isNotEmpty) {
      for (final ChapterGroupData group in page.chapterGroups) {
        if (group.chapters.any(
          (ChapterData chapter) => UriKeys.pathKey(chapter.href) == key,
        )) {
          return group.chapters;
        }
      }
      return const <ChapterData>[];
    }
    return page.chapters;
  }

  static ReaderPageData constrain(ReaderPageData page, DetailPageData detail) {
    final List<ChapterData> chapters = sequenceFor(detail, page.uri);
    final String key = UriKeys.pathKey(page.uri);
    final int index = chapters.indexWhere(
      (ChapterData chapter) => UriKeys.pathKey(chapter.href) == key,
    );
    if (index < 0) return page;
    return page.copyWith(
      prevHref: index > 0 ? chapters[index - 1].href : '',
      nextHref: index + 1 < chapters.length ? chapters[index + 1].href : '',
      catalogHref: detail.uri,
    );
  }
}
