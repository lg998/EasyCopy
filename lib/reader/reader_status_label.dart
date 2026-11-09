import 'package:flutter/material.dart';

class ReaderStatusLabel extends StatelessWidget {
  const ReaderStatusLabel({
    required this.label,
    this.icon,
    this.fontSize = 13,
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
          Icon(icon, size: fontSize + 1, color: Colors.white),
          const SizedBox(width: 2),
        ],
        Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w500,
            height: 1.15,
          ),
        ),
      ],
    );
  }
}
