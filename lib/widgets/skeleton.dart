import 'package:flutter/material.dart';

import '../theme.dart';

/// Placeholder layout shown while data loads. It mirrors the real layout's
/// geometry so nothing jumps when content arrives, and breathes gently
/// (static when the system asks for reduced motion).
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, required this.child});
  final Widget child;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
  late final _opacity = Tween(begin: 1.0, end: 0.55).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = Semantics(label: 'Загрузка', child: ExcludeSemantics(child: widget.child));
    if (MediaQuery.of(context).disableAnimations) return body;
    return FadeTransition(opacity: _opacity, child: body);
  }
}

/// One grey block of a skeleton.
class Bone extends StatelessWidget {
  const Bone({super.key, this.width, this.height = 12, this.radius = 6, this.circle = false});
  final double? width;
  final double height;
  final double radius;
  final bool circle;

  @override
  Widget build(BuildContext context) => Container(
        width: circle ? height : width,
        height: height,
        decoration: BoxDecoration(
          color: Palette.of(context).surfaceMuted,
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: circle ? null : BorderRadius.circular(radius),
        ),
      );
}

/// Skeleton of a ListTile with an optional leading block and trailing text.
class TileBone extends StatelessWidget {
  const TileBone({super.key, this.titleWidth = 140, this.subtitleWidth = 200, this.leading, this.trailing = false});
  final double titleWidth;
  final double subtitleWidth;
  final Widget? leading;
  final bool trailing;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 72,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 16)],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Bone(width: titleWidth, height: 15),
                    const SizedBox(height: 8),
                    Bone(width: subtitleWidth, height: 12),
                  ],
                ),
              ),
              if (trailing) const Bone(width: 44, height: 14),
            ],
          ),
        ),
      );
}

/// Varying widths so a column of skeleton rows doesn't look like a grid.
const kBoneWidths = [150.0, 110.0, 180.0, 130.0, 95.0, 165.0, 120.0, 140.0, 100.0, 175.0];
