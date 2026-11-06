import 'package:reader/models/page_models.dart';
import 'package:reader/services/uri_keys.dart';

/// Reading stays within the group containing the current chapter.
class ChapterNavigation {
  const ChapterNavigation._();

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
