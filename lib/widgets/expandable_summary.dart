import 'package:flutter/material.dart';
import 'package:reader/services/chinese_converter.dart';

class ExpandableSummary extends StatefulWidget {
  const ExpandableSummary({required this.text, super.key});

  final String text;

  @override
  State<ExpandableSummary> createState() => _ExpandableSummaryState();
}

class _ExpandableSummaryState extends State<ExpandableSummary> {
  bool _expanded = false;
  static const int _collapsedLines = 4;

  @override
  void didUpdateWidget(covariant ExpandableSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final ChineseConverter converter = ChineseConverter.instance;
    final String text = converter.convert(widget.text);
    final TextStyle style = DefaultTextStyle.of(
      context,
    ).style.merge(const TextStyle(height: 1.7));
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
          maxLines: _collapsedLines,
        )..layout(maxWidth: constraints.maxWidth);
        final bool canCollapse = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              text,
              style: style,
              maxLines: canCollapse && !_expanded ? _collapsedLines : null,
              overflow: canCollapse && !_expanded
                  ? TextOverflow.ellipsis
                  : TextOverflow.clip,
            ),
            if (canCollapse)
              TextButton.icon(
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                ),
                label: Text(converter.convert(_expanded ? '收起' : '展开简介')),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        );
      },
    );
  }
}
