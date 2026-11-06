import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:reader/services/image_cache.dart';

class CoverImage extends StatelessWidget {
  const CoverImage({
    required this.imageUrl,
    this.aspectRatio,
    this.borderRadius = 20,
    this.fit = BoxFit.cover,
    this.logicalWidth,
    super.key,
  });

  final String imageUrl;
  final double? aspectRatio;
  final double borderRadius;
  final BoxFit fit;
  final double? logicalWidth;

  @override
  Widget build(BuildContext context) {
    final double? knownWidth = logicalWidth;
    if (knownWidth != null && knownWidth.isFinite && knownWidth > 0) {
      return _buildClippedImage(
        context,
        memCacheWidth: _cacheWidthForLogical(context, knownWidth),
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return _buildClippedImage(
          context,
          memCacheWidth: _coverCacheWidth(context, constraints),
        );
      },
    );
  }

  Widget _buildClippedImage(
    BuildContext context, {
    required int? memCacheWidth,
  }) {
    Widget child = imageUrl.isEmpty
        ? const PlaceholderImage()
        : CachedNetworkImage(
            imageUrl: imageUrl,
            fit: fit,
            memCacheWidth: memCacheWidth,
            cacheManager: AppImageCaches.coverCache,
            fadeInDuration: const Duration(milliseconds: 120),
            fadeOutDuration: Duration.zero,
            placeholder: (_, __) => const CoverSkeleton(),
            errorWidget: (_, __, ___) => const PlaceholderImage(),
          );

    if (aspectRatio != null) {
      child = AspectRatio(aspectRatio: aspectRatio!, child: child);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: child,
    );
  }

  int _cacheWidthForLogical(BuildContext context, double width) {
    final double devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    return (width * devicePixelRatio).ceil().clamp(160, 720).toInt();
  }

  int? _coverCacheWidth(BuildContext context, BoxConstraints constraints) {
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : MediaQuery.sizeOf(context).width;
    if (!width.isFinite || width <= 0) {
      return null;
    }
    return _cacheWidthForLogical(context, width);
  }
}

class PlaceholderImage extends StatelessWidget {
  const PlaceholderImage({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            colorScheme.surfaceContainerHigh,
            colorScheme.surfaceContainerHighest,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.image_outlined,
          size: 28,
          color: colorScheme.onSurface.withValues(alpha: 0.42),
        ),
      ),
    );
  }
}

class CoverSkeleton extends StatelessWidget {
  const CoverSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: colorScheme.surfaceContainerHigh),
    );
  }
}
