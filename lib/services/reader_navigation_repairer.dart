import 'package:reader/config/app_config.dart';
import 'package:reader/models/page_models.dart';
import 'package:reader/services/chapter_navigation.dart';

typedef ReaderNavigationPageLoader =
    Future<ReaderPageData?> Function(Uri uri, {required String authScope});
typedef ReaderNavigationDetailLoader =
    Future<DetailPageData?> Function(Uri uri, {required String authScope});

class ReaderNavigationRepairer {
  const ReaderNavigationRepairer._();

  static Future<ReaderPageData> repair(
    ReaderPageData page, {
    required String authScope,
    required ReaderNavigationPageLoader loadReaderPage,
    required ReaderNavigationDetailLoader loadDetailPage,
    String preferredCatalogHref = '',
  }) async {
    // A blank link can be an intentional group boundary. Resolve the catalog
    // before filling blanks, and replace stale links that cross groups.
    final Uri? detailUri = _detailUriForPage(
      page,
      preferredCatalogHref: preferredCatalogHref,
    );
    if (detailUri != null) {
      try {
        final DetailPageData? detail = await loadDetailPage(
          detailUri,
          authScope: authScope,
        );
        if (detail != null) {
          final ReaderPageData constrained = ChapterNavigation.constrain(
            page,
            detail,
          );
          if (!identical(constrained, page)) return constrained;
        }
      } catch (_) {
        // Catalog unavailable: retain readable content and try reader metadata.
      }
    }
    if (!page.hasMissingChapterNavigation) return page;
    try {
      final ReaderPageData? fresh = await loadReaderPage(
        Uri.parse(page.uri),
        authScope: authScope,
      );
      if (fresh != null) {
        return page.mergeMissingNavigation(
          prevHref: fresh.prevHref,
          nextHref: fresh.nextHref,
          catalogHref: fresh.catalogHref,
        );
      }
    } catch (_) {
      // Repair failure must not prevent reading cached chapters.
    }
    return page;
  }

  static Uri? _detailUriForPage(
    ReaderPageData page, {
    required String preferredCatalogHref,
  }) {
    for (final String candidate in <String>[
      preferredCatalogHref,
      page.catalogHref,
    ]) {
      final String trimmed = candidate.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final Uri resolved = AppConfig.resolveNavigationUri(
        trimmed,
        currentUri: Uri.parse(page.uri),
      );
      if (_isDetailUri(resolved)) {
        return resolved;
      }
    }

    final Uri readerUri = AppConfig.rewriteToCurrentHost(Uri.parse(page.uri));
    final List<String> segments = readerUri.pathSegments;
    final int chapterIndex = segments.indexOf('chapter');
    if (chapterIndex <= 0) {
      return null;
    }
    return readerUri.replace(
      pathSegments: segments.take(chapterIndex).toList(growable: false),
      queryParameters: null,
      fragment: null,
    );
  }

  static bool _isDetailUri(Uri uri) {
    final String path = uri.path.toLowerCase();
    return path.startsWith('/comic/') && !path.contains('/chapter/');
  }
}
