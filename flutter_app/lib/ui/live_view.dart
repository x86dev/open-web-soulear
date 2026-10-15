import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../src/app_controller.dart';

/// Livebild. Mit Stabilisierung rund zugeschnitten und gegen die Drehung der
/// Kamera gedreht (weich animiert, 120 ms).
///
/// [fullscreen] füllt den verfügbaren Platz vollständig aus (randlos, ohne
/// Außenabstand). Ist [onTap] gesetzt, öffnet ein Tippen auf das Bild das
/// Vollbild.
class LiveView extends StatelessWidget {
  const LiveView({super.key, required this.controller, this.fullscreen = false, this.onTap});
  final AppController controller;

  /// Großansicht: Bild ohne Rand, Zuschnitt füllt den ganzen Bereich.
  final bool fullscreen;

  /// Wird beim Tippen auf das Bild aufgerufen (öffnet das Vollbild).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = ColoredBox(
      color: Colors.black,
      child: ValueListenableBuilder(
        valueListenable: controller.frame,
        builder: (context, frame, _) {
          if (frame == null) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.videocam_off, size: 40, color: Colors.grey.shade500),
                const SizedBox(height: 8),
                Text(controller.connecting ? 'Verbinde …' : 'Kein Livebild', style: TextStyle(color: Colors.grey.shade500)),
              ]),
            );
          }
          final image = Image.memory(frame.jpeg, gaplessPlayback: true, fit: BoxFit.contain);
          return ValueListenableBuilder(
            valueListenable: controller.rotation,
            builder: (context, rotation, _) {
              if (rotation == null) return Center(child: image);
              return LayoutBuilder(builder: (context, c) {
                // Im Vollbild den ganzen Bereich nutzen, sonst etwas Rand lassen.
                final size = math.min(c.maxWidth, c.maxHeight) - (fullscreen ? 0 : 16);
                return Center(
                  child: ClipOval(
                    child: SizedBox.square(
                      dimension: size,
                      child: AnimatedRotation(
                        turns: rotation / 360,
                        duration: const Duration(milliseconds: 120),
                        child: Image.memory(frame.jpeg, gaplessPlayback: true, fit: BoxFit.cover),
                      ),
                    ),
                  ),
                );
              });
            },
          );
        },
      ),
    );

    if (onTap == null) return content;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: content,
    );
  }
}
