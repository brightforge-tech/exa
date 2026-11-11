import 'package:exa_mobile/agent/models/agent_execution_report.dart';
import 'package:exa_mobile/agent/models/synthesized_response.dart';
import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:exa_mobile/agent/prompts/response_voice.dart';
import 'package:exa_mobile/agent/services/response_repairer.dart';
import 'package:exa_mobile/services/ai_client/ai_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_contracts.dart';

class FakeAiClient implements AiClient {
  FakeAiClient(this.replyText);

  final String replyText;
  final List<
      ({
        String system,
        List<Map<String, Object?>> messages,
        List<Map<String, Object?>>? tools,
      })> calls = [];

  @override
  Future<AiResponse> createMessage({
    String? apiKey,
    required String model,
    required String system,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
    int maxTokens = 8192,
  }) async {
    calls.add((system: system, messages: messages, tools: tools));
    return AiResponse(stopReason: 'end_turn', content: [
      {'type': 'text', 'text': replyText},
    ]);
  }

  @override
  Future<AiResponse> streamMessage({
    String? apiKey,
    required String model,
    required String system,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
    int maxTokens = 8192,
    void Function(String delta)? onText,
  }) =>
      createMessage(
        apiKey: apiKey,
        model: model,
        system: system,
        messages: messages,
        tools: tools,
        maxTokens: maxTokens,
      );

  @override
  bool get supportsVision => false;

  @override
  bool get supportsPdfDocument => false;

  @override
  int? get contextWindow => null;

  @override
  void dispose() {}
}

final contract = testContract(
  originalRequest: 'Digest my emails and give me a rundown.',
  domains: {'email'},
  actionLabels: ['review_emails'],
  requiredOutputs: {
    ResponseOutputType.rundown,
    ResponseOutputType.meetingList,
  },
  requiresSynthesis: true,
);

final report = AgentExecutionReport(
  originalRequest: contract.originalRequest,
  toolsCalled: const ['read_email_context'],
  actionsCompleted: const ['Read 2 email(s)'],
  actionsFailed: const [],
  tasksCreated: const [],
  eventsCreated: const [],
  eventsModified: const [],
  emailDigestItems: const [
    {'sender': 'Tanner', 'subject': 'Transfers', 'summary': 'A question.'},
  ],
  filesAffected: const [],
  screensCreated: const [],
  rulesChanged: const [],
  warnings: const [],
  uncertainItems: const [],
  partialFailures: const [],
);

const incomplete = SynthesizedResponse(
  message: 'All done!',
  includedOutputs: {},
);

void main() {
  const repairer = ResponseRepairer();

  test('tools are disabled on the repair call', () async {
    final client = FakeAiClient('{"message": "fixed", '
        '"included_outputs": ["rundown", "meeting_list"]}');
    await repairer.repair(
      client: client,
      model: 'test-model',
      originalResponse: incomplete,
      missingOutputs: contract.requiredOutputs,
      contract: contract,
      report: report,
    );
    expect(client.calls, hasLength(1), reason: 'repair runs exactly once');
    expect(client.calls.single.tools, isEmpty);
  });

  test('the prompt names the missing outputs and carries the report',
      () async {
    final client = FakeAiClient('{"message": "fixed", '
        '"included_outputs": ["rundown", "meeting_list"]}');
    await repairer.repair(
      client: client,
      model: 'test-model',
      originalResponse: incomplete,
      missingOutputs: contract.requiredOutputs,
      contract: contract,
      report: report,
    );
    final prompt = client.calls.single.messages.single['content'] as String;
    expect(prompt, contains('- rundown'));
    expect(prompt, contains('- meeting_list'));
    expect(prompt, contains('All done!'));
    expect(prompt, contains('"email_digest_items"'));
  });

  test('the system prompt forbids repeating or duplicating actions', () {
    expect(ResponseRepairer.systemPrompt, contains('Do not call tools'));
    expect(ResponseRepairer.systemPrompt, contains('Do not repeat actions'));
    expect(ResponseRepairer.systemPrompt,
        contains('Do not create duplicate tasks, events, emails, files, or '
            'rules'));
  });

  test('a repaired message is written in the same voice as the original',
      () async {
    // The repair rewrites the message the user reads, so the same rules
    // apply: plain words, no tool names, no output names as headings.
    expect(ResponseRepairer.systemPrompt, contains(ResponseVoice.rules));
    final client = FakeAiClient('{"message": "fixed", '
        '"included_outputs": ["rundown", "meeting_list"]}');
    await repairer.repair(
      client: client,
      model: 'test-model',
      originalResponse: incomplete,
      missingOutputs: contract.requiredOutputs,
      contract: contract,
      report: report,
    );
    final prompt = client.calls.single.messages.single['content'] as String;
    // Missing outputs come with their meaning, and an instruction not to
    // write them as labeled sections.
    expect(prompt,
        contains('- rundown: ${ResponseOutputType.rundown.readerNeed}'));
    expect(prompt, contains('not as a labeled section'));
  });

  test('missing outputs are supplied by the corrected response', () async {
    final client = FakeAiClient('{"message": "Here is the rundown and the '
        'meetings.", "included_outputs": ["rundown", "meeting_list"]}');
    final repaired = await repairer.repair(
      client: client,
      model: 'test-model',
      originalResponse: incomplete,
      missingOutputs: contract.requiredOutputs,
      contract: contract,
      report: report,
    );
    expect(repaired.includedOutputs,
        {ResponseOutputType.rundown, ResponseOutputType.meetingList});
    expect(repaired.message, contains('rundown'));
  });
}
