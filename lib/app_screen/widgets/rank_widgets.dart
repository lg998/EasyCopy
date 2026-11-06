// ignore_for_file: use_key_in_widget_constructors

part of '../widgets.dart';

/// 排行榜顶部的类型切换行（男频 / 女频、上升最快 / 周榜 …），参考官方 App 的文字标签样式。
class RankTabRow extends StatelessWidget {
  const RankTabRow({required this.items, required this.onTap});

  final List<LinkAction> items;
  final ValueChanged<String> onTap;

  /// 把站点的长标签缩短成官方 App 的写法：
  /// 「漫畫排行榜(男頻)」→「男頻」，「日榜(上升最快)」→「上升最快」，「周榜(最近7天)」→「周榜」。
  static String shortLabel(String label) {
    final RegExpMatch? match = RegExp(
      r'^(.*?)[(（](.*?)[)）]\s*$',
    ).firstMatch(label.trim());
    if (match == null) return label.trim();
    final String outer = (match.group(1) ?? '').trim();
    final String inner = (match.group(2) ?? '').trim();
    if (inner.isEmpty || inner.startsWith('最近')) {
      return outer.isEmpty ? label.trim() : outer;
    }
    return inner;
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> tabs = items
        .map(
          (LinkAction item) => _RankTab(
            label: shortLabel(ChineseConverter.instance.convert(item.label)),
            active: item.active,
            onTap: () => onTap(item.href),
          ),
        )
        .toList(growable: false);
    if (tabs.length > 5) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: tabs),
      );
    }
    return Row(
      children: tabs
          .map((Widget tab) => Expanded(child: tab))
          .toList(growable: false),
    );
  }
}

class _RankTab extends StatelessWidget {
  const _RankTab({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: active ? null : onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: active
                    ? colorScheme.primary
                    : colorScheme.onSurface.withValues(alpha: 0.62),
                fontSize: 14.5,
                height: 1.2,
                fontWeight: active ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
            const SizedBox(height: 5),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: active ? 18 : 0,
              height: 3,
              decoration: BoxDecoration(
                color: colorScheme.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 排行榜条目：参考拷贝漫画官方 App 的排行样式。
///
/// 左侧封面，右侧标题 / 作者 / 热度，右上角前三名显示奖牌，其余显示名次圆点。
class RankCard extends StatelessWidget {
  const RankCard({required this.item, required this.onTap});

  final RankEntryData item;
  final VoidCallback onTap;

  static const double _coverWidth = 78;
  static const double _coverHeight = 104;
  static const double _verticalPadding = 8;
  static const Color _heatColor = Color(0xFFF26B1D);

  static double cardHeightFor(TextScaler textScaler) {
    final double titleRowHeight = math.max(30.0, textScaler.scale(15.5 * 1.25 * 2));
    final double authorHeight = textScaler.scale(12.5 * 1.2);
    final double heatHeight = math.max(17.0, textScaler.scale(13.5 * 1.2));
    final double rightColumnHeight =
        6 + titleRowHeight + 8 + authorHeight + 8 + heatHeight + 4;
    return math.max(_coverHeight, rightColumnHeight) + _verticalPadding * 2;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final ChineseConverter converter = ChineseConverter.instance;
    final String heat = converter.convert(item.heat).trim();
    final String authors = converter
        .convert(item.authors)
        .replaceFirst(RegExp(r'^\s*作者\s*[:：]\s*'), '')
        .trim();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: _verticalPadding),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: _coverWidth,
              height: _coverHeight,
              child: CoverImage(
                imageUrl: item.coverUrl,
                borderRadius: 6,
                logicalWidth: _coverWidth,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            converter.convert(item.title),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colorScheme.onSurface,
                              fontSize: 15.5,
                              height: 1.25,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _RankBadge(rankLabel: item.rankLabel),
                      ],
                    ),
                    if (authors.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        authors,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colorScheme.onSurface.withValues(alpha: 0.48),
                          fontSize: 12.5,
                          height: 1.2,
                        ),
                      ),
                    ],
                    if (heat.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          const Icon(
                            Icons.local_fire_department_rounded,
                            size: 17,
                            color: _heatColor,
                          ),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              heat,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _heatColor,
                                fontSize: 13.5,
                                height: 1.2,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          _RankTrendIcon(trend: item.trend),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 前三名显示金 / 银 / 铜奖牌，其余显示灰色名次圆点。
class _RankBadge extends StatelessWidget {
  const _RankBadge({required this.rankLabel});

  final String rankLabel;

  static const List<Color> _medalColors = <Color>[
    Color(0xFFF5A623),
    Color(0xFF9AAFC9),
    Color(0xFFD9894A),
  ];

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final String label = ChineseConverter.instance.convert(rankLabel).trim();
    final int? rank = int.tryParse(label);
    if (rank != null && rank >= 1 && rank <= _medalColors.length) {
      return Icon(
        Icons.workspace_premium_rounded,
        size: 30,
        color: _medalColors[rank - 1],
      );
    }
    if (label.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colorScheme.onSurface.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        rank?.toString() ?? label,
        style: TextStyle(
          color: colorScheme.onSurface.withValues(alpha: 0.4),
          fontSize: 11,
          height: 1,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 热度后的小趋势箭头，持平时不显示。
class _RankTrendIcon extends StatelessWidget {
  const _RankTrendIcon({required this.trend});

  final String trend;

  @override
  Widget build(BuildContext context) {
    final (IconData, Color)? style = switch (trend) {
      'up' => (Icons.arrow_upward_rounded, const Color(0xFF18A558)),
      'down' => (Icons.arrow_downward_rounded, const Color(0xFFD64545)),
      _ => null,
    };
    if (style == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Icon(style.$1, size: 14, color: style.$2),
    );
  }
}
