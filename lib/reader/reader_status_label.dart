import 'package:flutter/material.dart';

class ReaderStatusLabel extends StatelessWidget {
  const ReaderStatusLabel({
    required this.label,
    this.icon,
    this.fontSize = 12,
    super.key,
  });

  final String label;
  final IconData? icon;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(
            icon,
            size: fontSize + 1,
            color: Colors.white.withValues(alpha: 0.95),
          ),
          const SizedBox(width: 2),
        ],
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.95),
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            height: 1.15,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class ReaderOutlinedText extends StatelessWidget {
  const ReaderOutlinedText({
    required this.label,
    required this.fontSize,
    super.key,
  });

  final String label;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final Paint strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.black;
    return Stack(
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            height: 1,
            foreground: strokePaint,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            height: 1,
          ),
        ),
      ],
    );
  }
}
