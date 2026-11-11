import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/assistant/assistant_screen.dart';
import '../features/assistant/chat_controller.dart';
import '../features/browser/browser_screen.dart';
import '../features/dynamic_ui/dynamic_screen_page.dart';
import '../features/files/files_screen.dart';
import '../features/planning/daily_plan_board_screen.dart';
import '../features/reminders/reminders_screen.dart';
import '../features/schedule/schedule_screen.dart';
import '../features/settings/accounts_screen.dart';
import '../features/settings/ai_provider_screen.dart';
import '../features/settings/audit_screen.dart';
import '../features/settings/behaviors_screen.dart';
import '../features/settings/browser_context_screen.dart';
import '../features/settings/chat_apps_screen.dart';
import '../features/settings/device_admin_screen.dart';
import '../features/settings/emails_screen.dart';
import '../features/settings/messages_screen.dart';
import '../features/settings/job_history_screen.dart';
import '../features/settings/jobs_screen.dart';
import '../features/settings/mail_accounts_screen.dart';
import '../features/settings/memory_screen.dart';
import '../features/settings/overlay_settings_screen.dart';
import '../features/settings/pending_approvals_screen.dart';
import '../features/settings/permissions_screen.dart';
import '../features/settings/phone_access_screen.dart';
import '../features/settings/privacy_screen.dart';
import '../features/settings/reliability_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/tool_activity_screen.dart';
import '../features/transcribe/transcribe_editor_screen.dart';
import '../features/transcribe/transcripts_list_screen.dart';
import '../data/models/dynamic_screen.dart';
import '../features/tasks/tasks_screen.dart';
import '../shared/providers.dart';
import '../shared/theme/exa_theme.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: ref.read(launchRouteProvider) ?? '/',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            _ScaffoldWithNav(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const AssistantScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/tasks',
              builder: (context, state) => const TasksScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/schedule',
              builder: (context, state) => const ScheduleScreen(),
            ),
          ]),
          // The planning board stands on its own rather than hiding behind
          // Tasks or Schedule: deciding when to do the work is its own
          // activity, and it is the screen you return to through the day.
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/plan',
              builder: (context, state) => const DailyPlanBoardScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/reminders',
              builder: (context, state) => const RemindersScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/browser',
              builder: (context, state) => const BrowserScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/settings',
              builder: (context, state) => const SettingsScreen(),
              routes: [
                GoRoute(
                  path: 'ai-provider',
                  builder: (context, state) => const AiProviderScreen(),
                ),
                GoRoute(
                  path: 'behaviors',
                  builder: (context, state) => const BehaviorsScreen(),
                ),
                GoRoute(
                  path: 'activity',
                  builder: (context, state) => const ToolActivityScreen(),
                ),
                GoRoute(
                  path: 'jobs',
                  builder: (context, state) => const JobsScreen(),
                ),
                GoRoute(
                  path: 'job-history',
                  builder: (context, state) => const JobHistoryScreen(),
                ),
                GoRoute(
                  path: 'reliability',
                  builder: (context, state) => const ReliabilityScreen(),
                ),
                GoRoute(
                  path: 'pending',
                  builder: (context, state) =>
                      const PendingApprovalsScreen(),
                ),
                GoRoute(
                  path: 'emails',
                  builder: (context, state) => const EmailsScreen(),
                ),
                GoRoute(
                  path: 'mail-accounts',
                  builder: (context, state) =>
                      const MailAccountsScreen(),
                ),
                GoRoute(
                  path: 'chat-apps',
                  builder: (context, state) => const ChatAppsScreen(),
                ),
                GoRoute(
                  path: 'messages',
                  builder: (context, state) => const MessagesScreen(),
                ),
                GoRoute(
                  path: 'browser-context',
                  builder: (context, state) =>
                      const BrowserContextScreen(),
                ),
                GoRoute(
                  path: 'accounts',
                  builder: (context, state) => const AccountsScreen(),
                ),
                GoRoute(
                  path: 'permissions',
                  builder: (context, state) => const PermissionsScreen(),
                ),
                GoRoute(
                  path: 'privacy',
                  builder: (context, state) => const PrivacyScreen(),
                ),
                GoRoute(
                  path: 'memory',
                  builder: (context, state) => const MemoryScreen(),
                ),
                GoRoute(
                  path: 'overlay',
                  builder: (context, state) =>
                      const OverlaySettingsScreen(),
                ),
                GoRoute(
                  path: 'phone-access',
                  builder: (context, state) => const PhoneAccessScreen(),
                ),
                GoRoute(
                  path: 'device',
                  builder: (context, state) => const DeviceAdminScreen(),
                ),
                GoRoute(
                  path: 'audit',
                  builder: (context, state) => const AuditScreen(),
                ),
              ],
            ),
          ]),
        ],
      ),
      // Agent-generated screens render outside the shell so the user can
      // clearly tell them apart and return with the back button.
      GoRoute(
        path: '/screen/:key',
        builder: (context, state) =>
            DynamicScreenPage(screenKey: state.pathParameters['key']!),
      ),
      GoRoute(
        path: '/files',
        builder: (context, state) => const FilesScreen(),
      ),
      // Voice transcription lives outside the shell so the editor gets a back
      // button. List -> new / :id editor. `new` is declared before `:id` so
      // it isn't captured as an id.
      GoRoute(
        path: '/transcribe',
        builder: (context, state) => const TranscriptsListScreen(),
        routes: [
          GoRoute(
            path: 'new',
            builder: (context, state) => const TranscribeEditorScreen(),
          ),
          GoRoute(
            path: ':id',
            builder: (context, state) => TranscribeEditorScreen(
                transcriptId: state.pathParameters['id']),
          ),
        ],
      ),
    ],
  );
});

/// No menu bar: navigation lives behind a single draggable floating button
/// that expands into the destination icons. Its position is saved (as
/// screen fractions, so rotation and different screens restore sanely).
class _ScaffoldWithNav extends ConsumerStatefulWidget {
  const _ScaffoldWithNav({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<_ScaffoldWithNav> createState() =>
      _ScaffoldWithNavState();
}

class _NavDestination {
  const _NavDestination(this.icon, this.selectedIcon, this.label);
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _ScaffoldWithNavState extends ConsumerState<_ScaffoldWithNav> {
  static const _positionSettingKey = 'nav_button_position';
  static const _fabSize = 56.0;
  static const _margin = 8.0;

  bool _expanded = false;
  bool _dragging = false;

  /// Button position as fractions of the usable area: (0,0) top-left,
  /// (1,1) bottom-right. Default: bottom-left.
  double _fx = 0.0;
  double _fy = 1.0;

  static const _destinations = [
    _NavDestination(
        Icons.chat_bubble_outline, Icons.chat_bubble, 'Exa'),
    _NavDestination(
        Icons.check_circle_outline, Icons.check_circle, 'Tasks'),
    _NavDestination(
        Icons.calendar_today_outlined, Icons.calendar_today, 'Schedule'),
    // Index 3 - must stay in step with the branch order above; the screens
    // listen on their own index for the revisit refresh.
    _NavDestination(
        Icons.view_day_outlined, Icons.view_day, 'Plan'),
    _NavDestination(Icons.alarm_outlined, Icons.alarm, 'Reminders'),
    _NavDestination(Icons.public_outlined, Icons.public, 'Browser'),
    _NavDestination(
        Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    _loadSavedPosition();
  }

  Future<void> _loadSavedPosition() async {
    try {
      final raw = await ref
          .read(settingsRepositoryProvider)
          .getValue(_positionSettingKey);
      if (raw == null) return;
      final parts = raw.split(',');
      if (parts.length != 2) return;
      final fx = double.tryParse(parts[0]);
      final fy = double.tryParse(parts[1]);
      if (fx == null || fy == null || !mounted) return;
      setState(() {
        _fx = fx.clamp(0.0, 1.0);
        _fy = fy.clamp(0.0, 1.0);
      });
    } catch (_) {
      // Defaults are fine if settings are unavailable.
    }
  }

  Future<void> _savePosition() async {
    try {
      await ref.read(settingsRepositoryProvider).setValue(
            _positionSettingKey,
            '${_fx.toStringAsFixed(4)},${_fy.toStringAsFixed(4)}',
          );
    } catch (_) {
      // Best effort - position just won't persist this time.
    }
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      // Refresh the saved-screens list each time the menu opens so screens
      // Exa just saved (or the user removed) show up without a restart.
      ref.invalidate(savedScreensProvider);
    }
  }

  Future<void> _openSavedScreen(DynamicScreen screen) async {
    _toggle();
    await context.push('/screen/${screen.screenKey}');
  }

  /// Long-press on a saved screen: hide it, or delete it outright.
  ///
  /// Two different intents that used to be one button. Hiding keeps the
  /// screen for Exa to reopen; deleting is how a screen the user is done
  /// with actually leaves, instead of living on invisibly.
  Future<void> _confirmRemoveScreen(DynamicScreen screen) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(screen.title),
        content: const Text(
            'Hide it from this menu and keep it, or delete it for good? '
            'Either way your tasks, events and files are untouched - this is '
            'only a view of them.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'hide'),
              child: const Text('Hide from menu')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, 'delete'),
              child: const Text('Delete')),
        ],
      ),
    );
    if (choice == null) return;
    final screens = ref.read(dynamicScreenRepositoryProvider);
    if (choice == 'delete') {
      await screens.delete(screen.screenKey);
    } else {
      await screens.markSaved(screen.screenKey, saved: false);
    }
    ref.invalidate(savedScreensProvider);
  }

  void _select(int index) {
    _toggle();
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
    // Tell the destination tab it's being shown so it can refresh data that
    // changed while it was offstage (its State is kept alive in the
    // IndexedStack and won't rebuild on revisit).
    ref.read(tabVisitTickProvider(index).notifier).state++;
    // The Exa tab also reloads from other entry points (e.g. a brief
    // notification), so it keeps its own dedicated tick + scroll-to-bottom.
    if (index == 0) {
      ref.read(assistantVisitTickProvider.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final usableW = constraints.maxWidth - _fabSize;
          final usableH = constraints.maxHeight - _fabSize;
          final x =
              (_fx * usableW).clamp(_margin, usableW - _margin).toDouble();
          final y =
              (_fy * usableH).clamp(_margin, usableH - _margin).toDouble();

          return Stack(
            children: [
              widget.navigationShell,
              // Expanded: the menu takes over the whole screen as a grid
              // launcher with its own header and close button.
              if (_expanded)
                Positioned.fill(
                  child: _FullScreenNavMenu(
                    currentIndex: widget.navigationShell.currentIndex,
                    destinations: _destinations,
                    onSelect: _select,
                    onClose: _toggle,
                    onOpenSaved: _openSavedScreen,
                    onRemoveSaved: _confirmRemoveScreen,
                    onOpenTranscribe: () {
                      _toggle();
                      context.push('/transcribe');
                    },
                  ),
                ),
              // Collapsed: the draggable floating button (hidden while the
              // full-screen menu is open).
              if (!_expanded)
                Positioned(
                  left: x,
                  top: y,
                  child: _buildCollapsedFab(
                      usableW: usableW, usableH: usableH),
                ),
            ],
          );
        },
      ),
    );
  }

  /// The collapsed, draggable floating button. Tapping it opens the
  /// full-screen menu; dragging repositions it (saved as screen fractions).
  Widget _buildCollapsedFab({
    required double usableW,
    required double usableH,
  }) {
    // Surface that Exa is still working even when the user is on another tab,
    // so an in-flight turn never looks like it stopped.
    final thinking =
        ref.watch(chatControllerProvider.select((s) => s.sending));

    return GestureDetector(
      onPanStart: (_) => setState(() => _dragging = true),
      onPanUpdate: (details) => setState(() {
        _fx = (_fx + details.delta.dx / usableW).clamp(0.0, 1.0);
        _fy = (_fy + details.delta.dy / usableH).clamp(0.0, 1.0);
      }),
      onPanEnd: (_) {
        setState(() => _dragging = false);
        _savePosition();
      },
      child: Container(
        width: 58,
        height: 58,
        decoration: BoxDecoration(
          gradient: ExaColors.accentGradient,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: ExaColors.accent.withValues(alpha: 0.5),
              blurRadius: 18,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _dragging ? null : _toggle,
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // A ring while a chat turn is in flight - visible from any
                  // tab so processing never appears to have stopped.
                  if (thinking)
                    const SizedBox(
                      width: 50,
                      height: 50,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor:
                            AlwaysStoppedAnimation(Colors.white70),
                      ),
                    ),
                  Icon(
                    _destinations[widget.navigationShell.currentIndex]
                        .selectedIcon,
                    color: Colors.white,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The expanded menu: a full-screen grid launcher with a header and a close
/// button. Replaces the old floating column. Built-in destinations come
/// first, then a Transcribe tile, then any Exa-built saved screens.
class _FullScreenNavMenu extends ConsumerWidget {
  const _FullScreenNavMenu({
    required this.currentIndex,
    required this.destinations,
    required this.onSelect,
    required this.onClose,
    required this.onOpenSaved,
    required this.onRemoveSaved,
    required this.onOpenTranscribe,
  });

  final int currentIndex;
  final List<_NavDestination> destinations;
  final void Function(int) onSelect;
  final VoidCallback onClose;
  final void Function(DynamicScreen) onOpenSaved;
  final void Function(DynamicScreen) onRemoveSaved;
  final VoidCallback onOpenTranscribe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final savedScreens =
        ref.watch(savedScreensProvider).value ?? const <DynamicScreen>[];

    final tiles = <Widget>[
      for (var i = 0; i < destinations.length; i++)
        _NavGridTile(
          icon: i == currentIndex
              ? destinations[i].selectedIcon
              : destinations[i].icon,
          label: destinations[i].label,
          selected: i == currentIndex,
          onTap: () => onSelect(i),
        ),
      _NavGridTile(
        icon: Icons.graphic_eq,
        label: 'Transcribe',
        selected: false,
        onTap: onOpenTranscribe,
      ),
      // Saved Exa-built screens push the /screen/:key route; long-press
      // removes them from the menu.
      for (final screen in savedScreens)
        _NavGridTile(
          icon: Icons.dashboard_customize_outlined,
          label: screen.title,
          selected: false,
          onTap: () => onOpenSaved(screen),
          onLongPress: () => onRemoveSaved(screen),
        ),
    ];

    // Fade the overlay in. (The shared scale animation overshoots past 1.0,
    // which is fine for scale but wrong for opacity, so animate separately.)
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: Material(
        color: theme.colorScheme.surface.withValues(alpha: 0.98),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
                child: Row(
                  children: [
                    Text('Navigate', style: theme.textTheme.headlineSmall),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: onClose,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 3,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  children: tiles,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single tile in the full-screen menu grid: a large icon over a label.
class _NavGridTile extends StatelessWidget {
  const _NavGridTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 30,
                color: selected
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurface,
              ),
              const SizedBox(height: 10),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight:
                      selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
