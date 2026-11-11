import 'package:flutter/material.dart';

/// Asks before the chat is emptied. True only when the user chose to clear.
///
/// Clearing deletes every row of the conversation, there is no copy to bring
/// back, and the button sits in the corner of the app bar where other
/// screens keep something harmless - the Jobs screen has "Job history" in
/// the same place. One stray tap there cost a whole conversation, including
/// every card the scheduled jobs had posted into it.
Future<bool> confirmClearConversation(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Clear this conversation?'),
      content: const Text(
          'Every message here is deleted from this phone and cannot be '
          'brought back.\n\n'
          'Your tasks, reminders, schedule and job history are kept.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear')),
      ],
    ),
  );
  return confirmed ?? false;
}
