import 'package:flutter/material.dart';

import '../src/app_controller.dart';
import 'live_view.dart';

/// Full screen live view. Opened by tapping the small live frame; the round X
/// in the top right corner closes it again.
///
/// The stream is shown edge to edge on black. Stabilization (the round crop and
/// the rotation) is the same as in [LiveView], so the image looks identical to
/// the small frame - just larger.
class FullscreenView extends StatelessWidget {
  const FullscreenView({super.key, required this.controller});
  final AppController controller;

  /// Opens the full screen view on top of the current page.
  static Future<void> open(BuildContext context, AppController controller) {
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        barrierColor: Colors.black,
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 160),
        pageBuilder: (_, __, ___) => FullscreenView(controller: controller),
        transitionsBuilder: (_, animation, __, child) => FadeTransition(
          opacity: animation,
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          LiveView(controller: controller, fullscreen: true),
          // The close button floats over the video; the safe area keeps it
          // clear of the status bar and of display cutouts.
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: _CloseButton(onPressed: () => Navigator.of(context).maybePop()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Round, transparent close button with a light halo, so the X stays visible
/// on bright and on dark parts of the video.
class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Vollbild schließen',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.25),
            ),
            child: const Icon(Icons.close, color: Colors.white, size: 26),
          ),
        ),
      ),
    );
  }
}
