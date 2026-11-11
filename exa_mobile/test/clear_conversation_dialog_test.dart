import 'package:exa_mobile/features/assistant/clear_conversation_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Clearing the chat cannot be undone, so one tap must not be enough.
void main() {
  Future<List<bool>> pumpWithButton(WidgetTester tester) async {
    final answers = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                answers.add(await confirmClearConversation(context)),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return answers;
  }

  testWidgets('it says what is lost and what is kept', (tester) async {
    await pumpWithButton(tester);
    expect(find.text('Clear this conversation?'), findsOneWidget);
    expect(find.textContaining('cannot be brought back'), findsOneWidget);
    expect(find.textContaining('job history are kept'), findsOneWidget);
  });

  testWidgets('Cancel keeps the conversation', (tester) async {
    final answers = await pumpWithButton(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(answers, [false]);
  });

  testWidgets('tapping outside the dialog keeps the conversation',
      (tester) async {
    final answers = await pumpWithButton(tester);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(answers, [false]);
  });

  testWidgets('only Clear clears', (tester) async {
    final answers = await pumpWithButton(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(answers, [true]);
  });
}
