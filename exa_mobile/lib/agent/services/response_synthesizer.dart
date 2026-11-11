import 'dart:convert';

import '../../services/ai_client/ai_client.dart';
import '../../services/ai_client/openai_compatible_client.dart';
import '../models/agent_execution_report.dart';
import '../models/synthesized_response.dart';
import '../models/turn_contract.dart';
import '../prompts/response_voice.dart';
import 'source_grounding.dart';
import 'tool_labels.dart';

/// The mandatory no-tool finalization call: turns the completion contract
/// and execution report into the final user-facing answer.
///
/// The client/model are passed per call (the active provider is selected
/// per turn); no tool definitions are ever sent, so this call can only
/// write the response - never act again.
class ResponseSynthesizer {
  const ResponseSynthesizer();

  static const systemPrompt = '''
You are completing an already-executed assistant request.
All tool actions have already been performed.
Do not call tools.
Do not repeat actions.
Do not invent completed actions.
Do not claim success for failed actions.
Do not hide warnings or uncertainty.
When stating when something is scheduled, copy the matching "..._label" value
from the execution report word for word. Never work out a weekday from a date
yourself - announcing "Tuesday" for something stored on Thursday makes your
reply contradict what the user sees on their Reminders screen.
The stored dates are correct and current even when the year looks wrong to
you. Your own sense of today's date is unreliable and the app's is not, so a
date further in the future than you expect is not an error: never restate it
as a different date, never "correct" it, and never report it as a failure.
Do not describe anything as a failure that the execution report does not
list as failed.
Use the original request, the required outputs, and the execution report to
produce a concise, useful user-facing response. This is a phone screen: keep
it short and concrete.
Write PLAIN TEXT. The app shows your message exactly as you write it, with no
markdown rendering, so "## Heading" and "**bold**" appear to the user as those
characters. Use short lines and "- " bullets for structure; no headings, bold,
italics, tables, backticks or code fences.
${ResponseVoice.rules}
Cover every required output in natural prose and name each one in
"included_outputs".
Declare every factual success claim your message makes in "claims", using
types like task_created, event_created, email_sent, emails_digested,
messages_digested, reminder_created, file_stored, rule_changed - one claim
per created or changed item. Something that was not done or not needed is
not a claim. Never declare a claim the execution report does not support.
Set "includes_failure_report" true only when your message tells the user
about failed or skipped actions.
Reply with ONLY this JSON structure (no prose outside it):
{"message": "<the final user-facing response>",
 "included_outputs": ["<each required output name your message covers>"],
 "claims": [{"type": "<claim type>", "description": "<short description>"}],
 "includes_failure_report": false}''';

  /// [systemPrompt] with the caller's behavior rules appended. They go last
  /// so the JSON output contract stays the model's most recent instruction.
  static String systemPromptWith(String behaviorBlock) =>
      behaviorBlock.trim().isEmpty
          ? systemPrompt
          : '$systemPrompt\n\n${behaviorBlock.trim()}';

  /// [behaviorBlock] carries the user's style/summary rules (see
  /// [BehaviorContext]). This call writes the message the user actually
  /// reads, so without it a rule like "keep replies to two bullets" would
  /// shape the action phase and then be flattened here. Empty string leaves
  /// the prompt byte-identical to the no-rules case.
  Future<SynthesizedResponse> synthesize({
    required AiClient client,
    String? apiKey,
    required String model,
    required CompletionContract contract,
    required AgentExecutionReport report,
    String? draftResponse,
    String behaviorBlock = '',
    String evidencePack = '',
    int? responseTokenBudget,
  }) async {
    final response = await client.createMessage(
      apiKey: apiKey,
      model: model,
      system: systemPromptWith(behaviorBlock),
      messages: [
        {
          'role': 'user',
          'content': buildPrompt(
            contract: contract,
            report: report,
            draftResponse: draftResponse,
            evidencePack: evidencePack,
            responseTokenBudget: responseTokenBudget,
          ),
        },
      ],
      tools: const [],
      // A confirmation does not need the headroom a weekly rundown does,
      // and an unbounded ceiling is how a two-line answer becomes six
      // paragraphs. The frame sized this from what the request asked for;
      // the multiplier leaves room for the JSON envelope around the
      // message itself. A model that thinks first gets room for that on
      // top, or it is cut off with the message unwritten.
      maxTokens: responseTokenBudget == null
          ? 8192
          : ((responseTokenBudget * 2).clamp(512, 8192) +
                  OpenAiCompatibleClient.headroomOf(client))
              .clamp(512, 8192),
    );
    return SynthesizedResponse.parse(response.text);
  }

  static String buildPrompt({
    required CompletionContract contract,
    required AgentExecutionReport report,
    String? draftResponse,
    String evidencePack = '',
    int? responseTokenBudget,
  }) {
    final buffer = StringBuffer()
      ..writeln('Original request:')
      ..writeln(contract.originalRequest)
      ..writeln()
      // Wire name plus meaning. The name is what goes in "included_outputs";
      // the meaning is what stops the name being written as a heading.
      ..writeln('What the reader needs from this reply (a checklist for '
          'you, not headings - cover each in natural prose and name it in '
          '"included_outputs"; when one has nothing to report, one short '
          'sentence covers it):')
      ..writeln(contract.requiredOutputs.isEmpty
          ? '(nothing specific - a plain, useful statement of what was done)'
          : contract.requiredOutputs
              .map((o) => '- ${o.wireName}: ${o.readerNeed}')
              .join('\n'))
      ..writeln();
    // Output names are otherwise self-describing; this one is not. A small
    // model reads "follow_up_question" as a heading to write rather than a
    // question to ask, and the turn that needs it most is the one that was
    // blocked from acting - where the whole point is that it ends by asking.
    if (contract.requiredOutputs
        .contains(ResponseOutputType.followUpQuestion)) {
      buffer
        ..writeln('"follow_up_question" means your message must END with one '
            'specific question, in your own words, that the user can answer '
            'in a few words. Not a heading, not a list of options to consider, '
            'and not an offer to proceed anyway.')
        ..writeln('If any action above is marked skipped or refused, say so '
            'plainly first and set "includes_failure_report" true: a bare '
            '"which one did you mean?" reads as though the work is still '
            'pending, when in fact nothing was done.')
        ..writeln();
    }
    // The router labels actions with tool names. Translated here so the
    // model never sees "mark_message_digested" as something to quote; the
    // status words are plain English for the same reason.
    buffer
      ..writeln('What was attempted (internal labels translated for you - '
          'describe these in your own words, never repeat a label or a '
          'status word verbatim):')
      ..writeln(contract.actions.isEmpty
          ? '(not itemized)'
          : contract.actions.map(actionLine).join('\n'));
    if (contract.constraints.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Constraints:')
        ..writeln(contract.constraints.map((c) => '- $c').join('\n'));
    }
    buffer
      ..writeln()
      ..writeln('Execution report (internal JSON, for your reference only - '
          'never quote its field names, tool names or ids to the reader):')
      ..writeln(jsonEncode(report.toJson()));
    if (nothingNeededDoing(contract: contract, report: report)) {
      // A housekeeping run that found nothing is the turn most likely to be
      // padded into sections ("Task list: none. Meeting list: none."). Said
      // in code, because a small model reads "cover every output" as
      // "write every output".
      buffer
        ..writeln()
        ..writeln('Nothing was created or changed and nothing failed: the '
            'checks ran and nothing new needed a task, reminder or event. '
            'Keep the reply to a few plain sentences - what you checked, '
            'anything worth knowing from it, and that nothing needs doing. '
            'No empty sections.');
    }
    if (evidencePack.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Evidence available to you. Every name, date, count and '
            'completed action in your message must come from here or from '
            'the execution report above - if something is not in either, '
            'you do not know it:')
        ..writeln(evidencePack.trim());
    }
    if (responseTokenBudget != null) {
      buffer
        ..writeln()
        ..writeln('Length: about $responseTokenBudget tokens. This is a '
            'phone screen - stop when the request is answered.');
    }
    if (draftResponse != null && draftResponse.trim().isNotEmpty) {
      // The action phase's own closing text often carries analysis (page
      // comparisons, answers computed from tool data) the normalized report
      // can't; give the synthesizer both.
      buffer
        ..writeln()
        ..writeln('Draft response from the action phase (internal - may be '
            'incomplete; reuse what is accurate):')
        ..writeln(draftResponse.trim());
    }
    buffer
      ..writeln()
      ..writeln('Produce the final response now.');
    return buffer.toString();
  }

  /// One planned action as the writer is shown it.
  ///
  /// A create that had nothing to create is "not needed", never "skipped":
  /// the second reads as something the reader is owed an apology for.
  static String actionLine(ContractAction action) {
    final label = ToolLabels.humanizeAction(action.description);
    if (action.failureReason == SourceGrounding.nothingCalledForIt) {
      return '- $label - not needed (nothing that was read called for it; '
          'this is not a failure)';
    }
    return '- $label - ${statusWords(action.status)}'
        '${action.failureReason != null ? ' (${action.failureReason})' : ''}';
  }

  /// Plain-English status for the prompt's action list. The wire names
  /// ("pending", "awaitingConfirmation") are for code; a model that sees
  /// "pending" writes "pending".
  static String statusWords(ContractItemStatus status) => switch (status) {
        ContractItemStatus.completed => 'done',
        ContractItemStatus.failed => 'failed',
        ContractItemStatus.skipped => 'skipped',
        ContractItemStatus.cancelled => 'cancelled',
        ContractItemStatus.pending => 'not done',
        ContractItemStatus.awaitingConfirmation =>
          "waiting for the user's approval",
      };

  /// Tools that check, read or tidy up rather than make anything: a turn
  /// that used only these and created nothing is a quiet turn.
  static const housekeepingTools = {
    'sync_emails',
    'sync_messages',
    'sync_device_calendar',
    'read_email_context',
    'read_message_context',
    'mark_email_digested',
    'mark_message_digested',
  };

  /// True when the turn only checked things, created and changed nothing,
  /// and nothing failed or was left undone - so the right reply is a few
  /// sentences, not a section per required output.
  ///
  /// Deliberately narrow: a turn that listed tasks to answer a question also
  /// created nothing, but the list *is* the answer, so list_* tools are not
  /// housekeeping here.
  static bool nothingNeededDoing({
    required CompletionContract contract,
    required AgentExecutionReport report,
  }) {
    if (report.toolsCalled.isEmpty) return false;
    if (!report.toolsCalled.every(housekeepingTools.contains)) return false;
    if (report.hasFailures || report.hasWarnings) return false;
    if (report.tasksCreated.isNotEmpty ||
        report.eventsCreated.isNotEmpty ||
        report.eventsModified.isNotEmpty ||
        report.filesAffected.isNotEmpty ||
        report.screensCreated.isNotEmpty ||
        report.rulesChanged.isNotEmpty) {
      return false;
    }
    // A required action left undone or failed is something the reader must
    // be told about; that is not a quiet turn.
    return contract.actions.every((action) =>
        !action.required || action.status == ContractItemStatus.completed);
  }
}
