import 'dart:convert';

import '../../services/ai_client/ai_client.dart';
import '../../services/ai_client/openai_compatible_client.dart';
import '../models/agent_execution_report.dart';
import '../models/synthesized_response.dart';
import '../models/turn_contract.dart';
import '../models/verification_result.dart';
import '../prompts/response_voice.dart';
import 'tool_labels.dart';

/// One no-tool repair attempt when verification failed the synthesized
/// response (missing outputs, unsupported claims, undisclosed failures).
/// Corrects only the user-facing text - the caller must never loop this,
/// and no tool definitions are sent, so it cannot repeat or duplicate
/// actions.
class ResponseRepairer {
  const ResponseRepairer();

  static const systemPrompt = '''
The requested actions have already been executed.
Do not call tools.
Do not repeat actions.
Do not create duplicate tasks, events, emails, files, or rules.
Correct only the user-facing response. Using only the execution report,
produce a corrected final response that contains every missing output,
removes every unsupported claim, and clearly discloses every failure.
Change what you are told is wrong and keep the rest of the previous response
as it is: a correction, not a rewrite.
Declare the claims your corrected message makes in "claims" and set
"includes_failure_report" true when it discloses failures.
${ResponseVoice.rules}
Reply with ONLY this JSON structure (no prose outside it):
{"message": "<the corrected final user-facing response>",
 "included_outputs": ["<each required output name your message covers>"],
 "claims": [{"type": "<claim type>", "description": "<short description>"}],
 "includes_failure_report": false}''';

  /// [systemPrompt] with the caller's behavior rules appended, so a repaired
  /// message still reads the way the user asked Exa to write.
  static String systemPromptWith(String behaviorBlock) =>
      behaviorBlock.trim().isEmpty
          ? systemPrompt
          : '$systemPrompt\n\n${behaviorBlock.trim()}';

  Future<SynthesizedResponse> repair({
    required AiClient client,
    String? apiKey,
    required String model,
    required SynthesizedResponse originalResponse,
    required Set<ResponseOutputType> missingOutputs,
    required CompletionContract contract,
    required AgentExecutionReport report,
    List<String> unsupportedClaims = const [],
    bool mustDiscloseFailures = false,
    String behaviorBlock = '',
    List<String> brokenConstraints = const [],
    List<String> fabricatedDates = const [],
    List<String> authoritativeDates = const [],
    int? responseTokenBudget,
    bool deliberate = deliberates,
  }) async {
    final messages = [
      {
        'role': 'user',
        'content': buildPrompt(
          originalResponse: originalResponse,
          missingOutputs: missingOutputs,
          contract: contract,
          report: report,
          unsupportedClaims: unsupportedClaims,
          mustDiscloseFailures: mustDiscloseFailures,
          brokenConstraints: brokenConstraints,
          fabricatedDates: fabricatedDates,
          authoritativeDates: authoritativeDates,
        ),
      },
    ];
    // Sized like the message it corrects, with room for a model that
    // thinks first. It used to be unbounded, and a repair with nothing
    // stated to repair wrote 2,121 tokens to return the message it was
    // given.
    final maxTokens = responseTokenBudget == null
        ? maxRepairTokens
        : ((responseTokenBudget * 2).clamp(512, maxRepairTokens) +
                OpenAiCompatibleClient.headroomOf(client))
            .clamp(512, maxRepairTokens);
    final system = systemPromptWith(behaviorBlock);
    final response = client is OpenAiCompatibleClient
        ? await client.createMessage(
            apiKey: apiKey,
            model: model,
            system: system,
            messages: messages,
            tools: const [],
            maxTokens: maxTokens,
            deliberate: deliberate,
          )
        : await client.createMessage(
            apiKey: apiKey,
            model: model,
            system: system,
            messages: messages,
            tools: const [],
            maxTokens: maxTokens,
          );
    return SynthesizedResponse.parse(response.text);
  }

  /// Whether a repair is asked for with the model's deliberation on.
  ///
  /// Off. A repair is told exactly what is wrong and what to put in its
  /// place, which is editing, not reasoning. Measured on the device's model
  /// over five kinds of fault, twice each: the corrected message was right
  /// and passed its check ten times out of ten either way, in 70 to 120
  /// tokens without deliberation against 200 to 580 with it.
  static const deliberates = false;

  /// A correction is never longer than this, whatever it corrects.
  static const maxRepairTokens = 4096;

  /// Convenience wrapper taking a full verification result.
  Future<SynthesizedResponse> repairFromVerification({
    required AiClient client,
    String? apiKey,
    required String model,
    required SynthesizedResponse originalResponse,
    required CompletionContract contract,
    required AgentExecutionReport report,
    required VerificationResult verification,
    String behaviorBlock = '',
    List<String> brokenConstraints = const [],
    int? responseTokenBudget,
  }) =>
      repair(
        client: client,
        apiKey: apiKey,
        model: model,
        originalResponse: originalResponse,
        missingOutputs: verification.missingOutputs,
        contract: contract,
        report: report,
        behaviorBlock: behaviorBlock,
        brokenConstraints: brokenConstraints,
        fabricatedDates: verification.fabricatedDates,
        authoritativeDates: verification.authoritativeDates,
        unsupportedClaims: verification.unsupportedClaims,
        mustDiscloseFailures: verification.issues.any((issue) =>
            issue.code == 'undisclosed_failure' ||
            issue.code == 'undisclosed_action_failure'),
        responseTokenBudget: responseTokenBudget,
      );

  static String buildPrompt({
    required SynthesizedResponse originalResponse,
    required Set<ResponseOutputType> missingOutputs,
    required CompletionContract contract,
    required AgentExecutionReport report,
    List<String> unsupportedClaims = const [],
    bool mustDiscloseFailures = false,
    List<String> brokenConstraints = const [],
    List<String> fabricatedDates = const [],
    List<String> authoritativeDates = const [],
  }) {
    final buffer = StringBuffer()
      ..writeln('Original request:')
      ..writeln(contract.originalRequest)
      ..writeln();
    if (fabricatedDates.isNotEmpty) {
      buffer
        ..writeln('The previous response stated these dates, which nothing '
            'that happened this turn contains - you changed them:')
        ..writeln(fabricatedDates.map((d) => '- $d').join('\n'))
        ..writeln()
        ..writeln('The stored dates are correct and current, even if they '
            'look far in the future. Do not "fix" them and do not describe '
            'them as an error.');
      if (authoritativeDates.isNotEmpty) {
        buffer
          ..writeln('Use exactly these, word for word:')
          ..writeln(authoritativeDates.map((d) => '- $d').join('\n'));
      }
      buffer.writeln();
    }
    if (brokenConstraints.isNotEmpty) {
      buffer
        ..writeln("The previous response broke the user's saved rules "
            'about how you write. The corrected response must satisfy '
            'each of these exactly:')
        ..writeln(brokenConstraints.map((c) => '- $c').join('\n'))
        ..writeln();
    }
    if (missingOutputs.isNotEmpty) {
      buffer
        ..writeln('The previous response omitted these required outputs '
            '(cover each in natural prose - not as a labeled section - and '
            'name it in "included_outputs"):')
        ..writeln(missingOutputs
            .map((o) => '- ${o.wireName}: ${o.readerNeed}')
            .join('\n'))
        ..writeln();
    }
    if (unsupportedClaims.isNotEmpty) {
      buffer
        ..writeln('The previous response made these claims that the '
            'execution report does NOT support - remove or correct them:')
        ..writeln(unsupportedClaims.map((claim) => '- $claim').join('\n'))
        ..writeln();
    }
    if (mustDiscloseFailures) {
      buffer
        ..writeln('The previous response failed to disclose failed actions. '
            'The corrected response must clearly state what failed.')
        ..writeln();
    }
    // Until this was here a turn with planned work left undone sent the
    // repair nothing but the message and the report, with an instruction
    // to correct it and no word on what was wrong. It returned the message
    // it was given, a minute and a half later.
    final undone = [
      for (final action in contract.actions)
        if (action.required && !action.isResolved)
          ToolLabels.humanizeAction(action.description),
    ];
    if (undone.isNotEmpty) {
      buffer
        ..writeln('These planned steps were NOT carried out. The previous '
            'response must not read as though they were. The corrected '
            'response says plainly, in the reader\'s words, that each was '
            'not done, and sets "includes_failure_report" true:')
        ..writeln(undone.map((step) => '- $step').join('\n'))
        ..writeln();
    }
    buffer
      ..writeln('Previous response:')
      ..writeln(originalResponse.message)
      ..writeln()
      ..writeln('Execution report:')
      ..writeln(jsonEncode(report.toJson()))
      ..writeln()
      ..writeln('Produce the corrected final response now.');
    return buffer.toString();
  }
}
