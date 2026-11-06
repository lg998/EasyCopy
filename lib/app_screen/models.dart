import 'package:reader/models/page_models.dart';

class ChapterPickerSection {
  const ChapterPickerSection({required this.label, required this.chapters});

  final String label;
  final List<ChapterData> chapters;
}

class DetailChapterTabData {
  const DetailChapterTabData({
    required this.key,
    required this.label,
    required this.chapters,
  });

  final String key;
  final String label;
  final List<ChapterData> chapters;

  bool get enabled => chapters.isNotEmpty;
}

class AdjacentChapterLinks {
  const AdjacentChapterLinks({this.prevHref = '', this.nextHref = ''});

  final String prevHref;
  final String nextHref;
}

class CachedChapterNavigationContext {
  const CachedChapterNavigationContext({
    this.prevHref = '',
    this.nextHref = '',
    this.catalogHref = '',
    this.isResolved = false,
  });

  final String prevHref;
  final String nextHref;
  final String catalogHref;
  final bool isResolved;

  bool get hasAnyValue =>
      prevHref.trim().isNotEmpty ||
      nextHref.trim().isNotEmpty ||
      catalogHref.trim().isNotEmpty;

  CachedChapterNavigationContext mergeMissing(
    CachedChapterNavigationContext fallback,
  ) {
    if (isResolved) return this;
    if (fallback.isResolved) return fallback;
    return CachedChapterNavigationContext(
      prevHref: prevHref.trim().isNotEmpty ? prevHref : fallback.prevHref,
      nextHref: nextHref.trim().isNotEmpty ? nextHref : fallback.nextHref,
      catalogHref: catalogHref.trim().isNotEmpty
          ? catalogHref
          : fallback.catalogHref,
    );
  }
}
