import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:exa_mobile/data/models/task_item.dart';
import 'package:exa_mobile/features/tasks/tasks_screen.dart';
import 'package:exa_mobile/shared/theme/exa_theme.dart';

/// "Now" for every test in this file: a Wednesday mid-morning.
///
/// The screen buckets tasks by comparing due dates against the wall clock, so
/// a fixture pinned to real time makes the same assertions pass or fail
/// depending on the hour the suite runs - the meeting below was due "today at
/// 13:30", which is upcoming before lunch and overdue after it. Every test
/// runs inside [withClock] so the buckets are fixed.
final _now = DateTime(2026, 8, 5, 10, 0);

TaskItem _task({
  required String title,
  String? description,
  String status = 'Pending',
  String priority = 'Normal',
  DateTime? dueAt,
}) {
  return TaskItem(
    id: title,
    title: title,
    description: description,
    status: status,
    priority: priority,
    dueAt: dueAt,
    createdAt: _now,
    updatedAt: _now,
  );
}

/// Runs [body] with "now" pinned to [_now].
Future<void> _atFixedTime(Future<void> Function() body) =>
    withClock(Clock.fixed(_now), body);

void main() {
  final tasks = [
    _task(
      title: 'Azure migration: Migrate legacy subscriptions before cutoff',
      description: 'As per email, migrate legacy Azure subscriptions.',
      priority: 'High',
      dueAt: _now.subtract(const Duration(days: 7)),
    ),
    _task(
      title: 'Investigate duplicate grouping on the portal',
      description: "Portal shows 'Not Found' for some records.",
      priority: 'Urgent',
      dueAt: _now.subtract(const Duration(days: 3)),
    ),
    _task(
      title: 'Prepare for Web Portal Weekly Meeting',
      description: 'Join the Web Portal Weekly Meeting at 13:30.',
      dueAt: DateTime(_now.year, _now.month, _now.day, 13, 30),
    ),
    _task(
      title: 'Request reports for outstanding debits',
      description: 'Curlene Browne reported that debits for...',
      dueAt: _now.add(const Duration(days: 3)),
    ),
    _task(title: 'Send the signed contract', status: 'Completed'),
  ];

  Widget harness(List<TaskItem> data, {double textScale = 1.0}) =>
      ProviderScope(
        overrides: [
          tasksProvider.overrideWith((ref) async => data),
        ],
        child: MaterialApp(
          theme: buildExaDarkTheme(),
          builder: (context, child) => MediaQuery.withClampedTextScaling(
            minScaleFactor: textScale,
            maxScaleFactor: textScale,
            child: child!,
          ),
          home: const TasksScreen(),
        ),
      );

  testWidgets('renders the digest, filters and cards without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await _atFixedTime(() async {
      await tester.pumpWidget(harness(tasks));
      await tester.pumpAndSettle();

      expect(find.textContaining('Good'), findsOneWidget);
      expect(find.text('OPEN'), findsOneWidget);
      expect(find.text('OVERDUE'), findsOneWidget);
      expect(find.text('TODAY'), findsOneWidget);
      // 4 open, 2 overdue, 1 today (the 13:30 meeting, still ahead of us).
      expect(find.text('4'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('All Tasks'), findsOneWidget);
      // The list is viewport-lazy: the upcoming card, the Done label and the
      // completed card sit below the fold, and Flutter never builds what it
      // will not show. Scroll them into view rather than pinning the
      // assertions to whatever viewport + cacheExtent cover on one given
      // screen height.
      await tester.dragUntilVisible(find.text('UPCOMING'),
          find.byType(ListView).first, const Offset(0, -120));
      expect(find.text('UPCOMING'), findsOneWidget);
      await tester.dragUntilVisible(find.text('DONE'),
          find.byType(ListView).first, const Offset(0, -120));
      expect(find.text('DONE'), findsOneWidget);
      expect(find.textContaining('Overdue • '), findsNWidgets(2));
    });
  });

  testWidgets('survives large text scaling', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await _atFixedTime(() async {
      await tester.pumpWidget(harness(tasks, textScale: 1.5));
      await tester.pumpAndSettle();

      expect(find.text('OPEN'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('filters narrow the list', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await _atFixedTime(() async {
      await tester.pumpWidget(harness(tasks));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Overdue'));
      await tester.pumpAndSettle();
      // Due later today is not overdue.
      expect(find.text('Prepare for Web Portal Weekly Meeting'), findsNothing);
      expect(find.textContaining('Azure migration'), findsOneWidget);

      await tester.tap(find.text('Important'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Azure migration'), findsOneWidget);
      expect(find.text('Send the signed contract'), findsNothing);

      // The pill row scrolls - the last filter may sit off-screen.
      await tester.drag(find.text('Important'), const Offset(-320, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Completed'));
      await tester.pumpAndSettle();
      expect(find.text('Send the signed contract'), findsOneWidget);
      expect(find.textContaining('Azure migration'), findsNothing);
    });
  });

  testWidgets('empty filter shows an inline empty state', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await _atFixedTime(() async {
      await tester.pumpWidget(harness([_task(title: 'Just one thing')]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Overdue'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing overdue'), findsOneWidget);
      // Header and filters stay put.
      expect(find.text('All Tasks'), findsOneWidget);
    });
  });
}
