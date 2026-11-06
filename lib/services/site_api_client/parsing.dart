part of '../site_api_client.dart';

extension _SiteApiParsing on SiteApiClient {
  ProfileUserData _parseUser(Map<String, Object?> payload) {
    final Map<String, Object?> results = asStringKeyMap(payload['results']);
    final String userId = pickString(results, <String>[
      'user_id',
      'id',
      'uuid',
    ]);
    final String username = pickString(results, <String>[
      'username',
      'mobile',
      'email',
    ]);
    final String nickname = pickString(results, <String>['nickname', 'name']);
    final String avatarUrl = pickString(results, <String>[
      'avatar',
      'avatar_url',
    ]);
    final String createdAt = pickString(results, <String>[
      'createDate',
      'datetime_created',
      'created_at',
    ]);
    final List<String> memberships = <String>[
      if (pickBool(results, 'vip')) 'VIP',
      if (pickBool(results, 'comic_vip')) '漫画会员',
      if (pickBool(results, 'cartoon_vip')) '动画会员',
    ];
    return ProfileUserData(
      userId: userId,
      username: username.isEmpty ? '未命名用户' : username,
      nickname: nickname,
      avatarUrl: avatarUrl,
      createdAt: createdAt,
      membershipLabel: memberships.isEmpty ? '普通会员' : memberships.join(' / '),
    );
  }

  List<ProfileLibraryItem> _parseCollections(
    Object? results, {
    ProfileCollectionSort sort = AppConfig.defaultProfileCollectionSort,
  }) {
    final List<ProfileLibraryItem> items = _extractList(results)
        .map((Map<String, Object?> item) {
          final Map<String, Object?> comic = _firstNonEmptyMap(item, <String>[
            'comic',
            'comic_info',
            'cartoon',
            'results',
          ]);
          final Map<String, Object?> browse = _firstNonEmptyMap(item, <String>[
            'last_browse',
            'browse',
          ]);
          final Map<String, Object?> source = comic.isEmpty ? item : comic;
          final String pathWord = pickString(source, <String>[
            'path_word',
            'pathWord',
            'slug',
          ]);
          final String updatedAt = pickFirstString(
            <Map<String, Object?>>[source, item],
            const <String>[
              'datetime_updated',
              'updated_at',
              'updatedAt',
              'last_update_time',
              'last_update_at',
              'update_time',
            ],
          );
          final String comicId = pickString(source, const <String>[
            'uuid',
            'comic_id',
            'comicId',
          ]);
          final String lastChapterId = pickFirstString(
            <Map<String, Object?>>[source, item],
            const <String>['last_chapter_id', 'lastChapterId'],
          );
          final String lastBrowseChapterId = pickFirstString(
            <Map<String, Object?>>[browse, item],
            const <String>[
              'last_browse_id',
              'lastBrowseId',
              'chapter_uuid',
              'chapter_id',
            ],
          );
          return ProfileLibraryItem(
            title: pickString(source, <String>['name', 'title']),
            coverUrl: pickString(source, <String>[
              'cover',
              'cover_url',
              'image',
            ]),
            href: _buildComicHref(pathWord, source, item),
            comicId: comicId,
            subtitle: pickString(source, <String>[
              'author_name',
              'author',
              'subtitle',
            ]),
            secondaryText: pickFirstString(
              <Map<String, Object?>>[source, item],
              const <String>[
                'last_chapter_name',
                'lastChapterName',
                'status',
              ],
            ),
            updatedAt: updatedAt,
            lastChapterId: lastChapterId,
            lastBrowseChapterId: lastBrowseChapterId,
          );
        })
        .where((ProfileLibraryItem item) => item.title.isNotEmpty)
        .toList(growable: false);
    switch (sort) {
      case ProfileCollectionSort.latestUpdate:
        items.sort(_compareByUpdatedDesc);
        break;
      case ProfileCollectionSort.readingTime:
      case ProfileCollectionSort.alphabetical:
        break;
    }
    return items;
  }

  List<ProfileHistoryItem> _parseHistory(Object? results) {
    return _extractList(results)
        .map((Map<String, Object?> item) {
          final Map<String, Object?> comic = _firstNonEmptyMap(item, <String>[
            'comic',
            'comic_info',
            'cartoon',
          ]);
          final Map<String, Object?> chapter = _firstNonEmptyMap(item, <String>[
            'chapter',
            'last_chapter',
            'browse',
          ]);
          final Map<String, Object?> browse = _firstNonEmptyMap(item, <String>[
            'browse',
            'last_browse',
          ]);
          final Map<String, Object?> source = comic.isEmpty ? item : comic;
          final String pathWord = pickString(source, <String>[
            'path_word',
            'pathWord',
            'slug',
          ]);
          final String chapterUuidFromChapter = pickString(
            chapter,
            const <String>['uuid', 'chapter_uuid', 'id'],
          );
          final String chapterUuid = chapterUuidFromChapter.isNotEmpty
              ? chapterUuidFromChapter
              : pickString(item, const <String>['last_chapter_id']);
          final String chapterLabelFromChapter = pickString(
            chapter,
            const <String>['name', 'title', 'chapter_name'],
          );
          final String chapterLabel = chapterLabelFromChapter.isNotEmpty
              ? chapterLabelFromChapter
              : pickString(item, const <String>['last_chapter_name']);
          return ProfileHistoryItem(
            title: pickString(source, <String>['name', 'title']),
            coverUrl: pickString(source, <String>[
              'cover',
              'cover_url',
              'image',
            ]),
            comicHref: _buildComicHref(pathWord, source, item),
            chapterLabel: chapterLabel,
            chapterHref: _buildChapterHref(pathWord, chapterUuid),
            visitedAt: pickFirstString(
              <Map<String, Object?>>[item, browse],
              const <String>[
                'datetime_created',
                'datetime_updated',
                'created_at',
                'updated_at',
                'browse_at',
                'browse_time',
                'read_at',
                'read_time',
              ],
            ),
          );
        })
        .where((ProfileHistoryItem item) => item.title.isNotEmpty)
        .toList(growable: false);
  }

  ComicCardData _parseSearchComic(Map<String, Object?> item) {
    final Map<String, Object?> nestedSource = _firstNonEmptyMap(
      item,
      const <String>['comic', 'comic_info', 'cartoon', 'results'],
    );
    final Map<String, Object?> source = nestedSource.isEmpty
        ? item
        : nestedSource;
    final String pathWord = pickString(source, <String>[
      'path_word',
      'pathWord',
      'slug',
    ]);
    final String authorText = _searchAuthorLabel(source);
    return ComicCardData(
      title: pickString(source, <String>['name', 'title']),
      subtitle: authorText.isEmpty ? '作者：--' : '作者：$authorText',
      secondaryText: pickString(source, <String>[
        'datetime_updated',
        'status',
        'brief',
      ]),
      coverUrl: pickString(source, <String>['cover', 'cover_url', 'image']),
      href: _buildComicHref(pathWord, source, item),
      authorLinks: _searchAuthorLinks(source),
    );
  }

  RankEntryData _parseRankEntry(
    Map<String, Object?> item, {
    required int fallbackRank,
  }) {
    final Map<String, Object?> comic = _firstNonEmptyMap(item, const <String>[
      'comic',
      'comic_info',
      'cartoon',
      'results',
    ]);
    final Map<String, Object?> source = comic.isEmpty ? item : comic;
    final String pathWord = pickString(source, const <String>[
      'path_word',
      'pathWord',
      'slug',
    ]);
    final int sort = pickInt(
      item,
      const <String>['sort', 'rank'],
      fallback: fallbackRank,
    );
    final String authorText = _searchAuthorLabel(source);
    final int popular = pickInt(
      item,
      const <String>['popular'],
      fallback: pickInt(source, const <String>['popular'], fallback: 0),
    );
    final int riseSort = pickInt(
      item,
      const <String>['rise_sort', 'riseSort'],
      fallback: 0,
    );
    final int sortLast = pickInt(
      item,
      const <String>['sort_last', 'sortLast'],
      fallback: 0,
    );
    final String trend = riseSort < 0
        ? 'down'
        : (sortLast > 0 && riseSort > 0 ? 'up' : 'stable');

    return RankEntryData(
      rankLabel: '${sort > 0 ? sort : fallbackRank}',
      title: pickString(source, const <String>['name', 'title']),
      authors: authorText.isEmpty ? '' : '作者：$authorText',
      heat: _formatRankPopular(popular),
      trend: trend,
      coverUrl: pickString(source, const <String>[
        'cover',
        'cover_url',
        'image',
      ]),
      href: _buildComicHref(pathWord, source, item),
    );
  }

  String _formatRankPopular(int popular) {
    if (popular <= 0) {
      return '';
    }
    if (popular >= 10000) {
      return '${(popular / 10000).toStringAsFixed(1)}W';
    }
    return '$popular';
  }

  String _rankPageTitle(String dateType) {
    return switch (dateType) {
      'week' => '漫畫排行周榜',
      'month' => '漫畫排行月榜',
      'total' => '漫畫排行總榜',
      _ => '漫畫排行日榜',
    };
  }

  List<LinkAction> _buildRankCategories({
    required String audienceType,
    required String dateType,
  }) {
    return <LinkAction>[
      LinkAction(
        label: '漫畫排行榜(男頻)',
        href: AppConfig.resolvePath(
          '/rank?type=male&table=$dateType',
        ).toString(),
        active: audienceType == 'male',
      ),
      LinkAction(
        label: '漫畫排行榜(女頻)',
        href: AppConfig.resolvePath(
          '/rank?type=female&table=$dateType',
        ).toString(),
        active: audienceType == 'female',
      ),
    ];
  }

  List<LinkAction> _buildRankPeriods({
    required String audienceType,
    required String dateType,
  }) {
    return <LinkAction>[
      LinkAction(
        label: '日榜(上升最快)',
        href: AppConfig.resolvePath(
          '/rank?type=$audienceType&table=day',
        ).toString(),
        active: dateType == 'day',
      ),
      LinkAction(
        label: '周榜(最近7天)',
        href: AppConfig.resolvePath(
          '/rank?type=$audienceType&table=week',
        ).toString(),
        active: dateType == 'week',
      ),
      LinkAction(
        label: '月榜(最近30天)',
        href: AppConfig.resolvePath(
          '/rank?type=$audienceType&table=month',
        ).toString(),
        active: dateType == 'month',
      ),
      LinkAction(
        label: '總榜單',
        href: AppConfig.resolvePath(
          '/rank?type=$audienceType&table=total',
        ).toString(),
        active: dateType == 'total',
      ),
    ];
  }

  ChapterComment _parseChapterComment(Map<String, Object?> item) {
    final Map<String, Object?> user = _firstNonEmptyMap(item, const <String>[
      'user',
      'member',
      'author',
    ]);
    final int commentId = pickInt(item, const <String>['id'], fallback: 0);
    final String itemAvatar = pickString(item, const <String>[
      'user_avatar',
      'avatar',
      'avatar_url',
    ]);
    final String avatarUrl = itemAvatar.isNotEmpty
        ? itemAvatar
        : pickString(user, const <String>[
            'avatar',
            'avatar_url',
            'user_avatar',
          ]);
    return ChapterComment(
      id: commentId > 0
          ? '$commentId'
          : pickString(item, const <String>['uuid', 'comment_id', 'roast_id']),
      message: pickString(item, const <String>[
        'comment',
        'roast',
        'content',
        'text',
      ]),
      avatarUrl: avatarUrl,
    );
  }

  List<Map<String, Object?>> _extractList(Object? source) {
    if (source is List) {
      return source
          .whereType<Map>()
          .map(asStringKeyMap)
          .toList(growable: false);
    }
    if (source is Map) {
      final Map<String, Object?> map = asStringKeyMap(source);
      for (final String key in <String>[
        'list',
        'items',
        'comics',
        'results',
        'records',
        'browse',
        'browses',
      ]) {
        final Object? nested = map[key];
        if (nested is List) {
          return nested
              .whereType<Map>()
              .map(asStringKeyMap)
              .toList(growable: false);
        }
      }
    }
    return const <Map<String, Object?>>[];
  }

  Map<String, Object?> _firstNonEmptyMap(
    Map<String, Object?> source,
    List<String> keys,
  ) {
    for (final String key in keys) {
      final Map<String, Object?> value = asStringKeyMap(source[key]);
      if (value.isNotEmpty) {
        return value;
      }
    }
    return const <String, Object?>{};
  }

  String _buildComicHref(
    String pathWord,
    Map<String, Object?> primary,
    Map<String, Object?> fallback,
  ) {
    if (pathWord.isNotEmpty) {
      return AppConfig.resolvePath('/comic/$pathWord').toString();
    }
    final String directHref = pickString(primary, <String>['href', 'url']);
    if (directHref.isNotEmpty) {
      return AppConfig.resolveNavigationUri(directHref).toString();
    }
    final String fallbackHref = pickString(fallback, <String>['href', 'url']);
    if (fallbackHref.isNotEmpty) {
      return AppConfig.resolveNavigationUri(fallbackHref).toString();
    }
    return '';
  }

  String _buildChapterHref(String pathWord, String chapterUuid) {
    if (pathWord.isEmpty || chapterUuid.isEmpty) {
      return '';
    }
    return AppConfig.resolvePath(
      '/comic/$pathWord/chapter/$chapterUuid',
    ).toString();
  }

  String _searchAuthorLabel(Map<String, Object?> source) {
    final Object? authorValue = source['author'];
    if (authorValue is List) {
      final List<String> labels = authorValue
          .whereType<Map>()
          .map(
            (Map value) => pickString(
              value.map(
                (Object? key, Object? nested) =>
                    MapEntry(key.toString(), nested),
              ),
              const <String>['name', 'author_name', 'title'],
            ),
          )
          .where((String value) => value.isNotEmpty)
          .toList(growable: false);
      if (labels.isNotEmpty) {
        return labels.join(' / ');
      }
    }
    return pickString(source, const <String>[
      'author_name',
      'author_alias',
      'author',
    ]);
  }

  List<LinkAction> _searchAuthorLinks(Map<String, Object?> source) {
    final Object? authorValue = source['author'];
    if (authorValue is! List) {
      return const <LinkAction>[];
    }
    return authorValue
        .whereType<Map>()
        .map((Map value) {
          final Map<String, Object?> author = value.map(
            (Object? key, Object? nested) => MapEntry(key.toString(), nested),
          );
          final String label = pickString(author, const <String>[
            'name',
            'author_name',
            'title',
          ]);
          final String directHref = pickString(author, const <String>[
            'href',
            'url',
          ]);
          final String pathWord = pickString(author, const <String>[
            'path_word',
            'pathWord',
            'slug',
          ]);
          final String href = directHref.isNotEmpty
              ? AppConfig.resolveNavigationUri(directHref).toString()
              : pathWord.isEmpty
              ? ''
              : AppConfig.resolvePath('/author/$pathWord').toString();
          return LinkAction(label: label, href: href);
        })
        .where((LinkAction author) {
          return author.label.isNotEmpty;
        })
        .toList(growable: false);
  }
}
