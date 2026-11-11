import 'package:exa_mobile/agent/services/tool_labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolLabels', () {
    test('known tools get a human description and a short pill', () {
      expect(ToolLabels.describe('sync_messages'),
          'check for new chat messages');
      expect(ToolLabels.pill('sync_messages'), 'Checked chats');
      expect(ToolLabels.describe('mark_message_digested'),
          'mark chat messages as handled');
      expect(ToolLabels.pill('read_email_context'), 'Read mail');
    });

    test('unknown tools are still readable, never raw identifiers', () {
      expect(ToolLabels.describe('frobnicate_widget'), 'frobnicate widget');
      // A known verb is conjugated; the rest of the name is read as words.
      expect(ToolLabels.pill('create_widget_group'), 'Created widget group');
      // An unknown verb is at least capitalized words.
      expect(ToolLabels.pill('frobnicate_widget'), 'Frobnicate widget');
      expect(ToolLabels.pill('frobnicate_widget'), isNot(contains('_')));
    });

    test('action labels: identifiers are translated, phrases pass through',
        () {
      expect(ToolLabels.humanizeAction('mark_message_digested'),
          'mark chat messages as handled');
      expect(ToolLabels.humanizeAction('Read undigested email context'),
          'Read undigested email context');
      expect(ToolLabels.humanizeAction('review_emails'), 'review emails');
      expect(ToolLabels.humanizeAction(''), '');
    });

    test('isIdentifier recognizes snake_case tool names only', () {
      expect(ToolLabels.isIdentifier('sync_messages'), isTrue);
      expect(ToolLabels.isIdentifier('search'), isTrue);
      expect(ToolLabels.isIdentifier('Read 2 emails'), isFalse);
      expect(ToolLabels.isIdentifier('Sync messages'), isFalse);
    });

    test('no label contains an underscore', () {
      for (final tool in const [
        'sync_messages',
        'read_message_context',
        'mark_message_digested',
        'sync_emails',
        'read_email_context',
        'mark_email_digested',
        'create_task',
        'create_schedule_event',
        'propose_behavior_change',
        'rollback_behavior_version',
        'some_new_tool',
      ]) {
        expect(ToolLabels.describe(tool), isNot(contains('_')),
            reason: tool);
        expect(ToolLabels.pill(tool), isNot(contains('_')), reason: tool);
      }
    });
  });
}
