import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router.dart';
import 'services/notifications/notification_service.dart';
import 'services/overlay/overlay_controller.dart';
import 'shared/providers.dart';
import 'shared/theme/exa_theme.dart';

class ExaApp extends ConsumerStatefulWidget {
  const ExaApp({super.key});

  @override
  ConsumerState<ExaApp> createState() => _ExaAppState();
}

class _ExaAppState extends ConsumerState<ExaApp>
    with WidgetsBindingObserver {
  StreamSubscription<String>? _tapRoutesSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Notification taps deep-link into the app while it is alive.
    _tapRoutesSubscription = notificationTapRoutes.stream.listen((route) {
      ref.read(routerProvider).go(route);
      // Tapping a brief notification lands on the Exa tab - pin it to the
      // newest message.
      if (route == '/') {
        ref.read(assistantVisitTickProvider.notifier).state++;
      }
    });
    // Pushed by native when a notification action lands on an already-running
    // app; the resume poll below covers cold and background starts.
    ref
        .read(overlayControllerProvider)
        .onLaunchActionPushed(_consumeOverlayRoute);
    _consumeOverlayRoute();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The overlay panel's "open in app" hand-off arrives via the launch
    // intent; pick it up whenever we come to the foreground.
    if (state == AppLifecycleState.resumed) _consumeOverlayRoute();
  }

  Future<void> _consumeOverlayRoute() async {
    final controller = ref.read(overlayControllerProvider);
    final route = await controller.consumeLaunchRoute();
    if (mounted && route != null && route.isNotEmpty) {
      ref.read(routerProvider).go(route);
      if (route == '/') {
        ref.read(assistantVisitTickProvider.notifier).state++;
      }
    }
    // A feature to open on top of the route: Voice starts listening in the
    // assistant, Snippet drives the bubble's screen capture, Chat is just the
    // assistant (already handled by the route).
    final action = await controller.consumeLaunchAction();
    if (!mounted || action == null || action.isEmpty) return;
    switch (action) {
      case 'voice':
        ref.read(routerProvider).go('/');
        ref.read(assistantVisitTickProvider.notifier).state++;
        ref.read(assistantVoiceRequestProvider.notifier).state++;
      case 'snippet':
        // Best effort: needs the bubble enabled (it is, if this came from its
        // notification). Falls back to the assistant, already open.
        unawaited(controller.openOverlayPanel('snippet'));
      case 'chat':
        ref.read(routerProvider).go('/');
        ref.read(assistantVisitTickProvider.notifier).state++;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tapRoutesSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Exa',
      debugShowCheckedModeBanner: false,
      // "Midnight" - dark-first. A light counterpart drops in later.
      theme: buildExaDarkTheme(),
      darkTheme: buildExaDarkTheme(),
      themeMode: ThemeMode.dark,
      routerConfig: router,
    );
  }
}
