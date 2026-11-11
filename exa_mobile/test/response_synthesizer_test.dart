import 'dart:convert';

import 'package:exa_mobile/agent/models/agent_execution_report.dart';
import 'package:exa_mobile/agent/models/synthesized_response.dart';
import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:exa_mobile/agent/prompts/response_voice.dart';
import 'package:exa_mobile/agent/services/response_synthesizer.dart';
import 'package:exa_mobile/services/ai_client/ai_client.dart';
import 'package:exa_mobile/services/ai_client/local_endpoint_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
  originalRequest: 'Digest my emails, create any tasks, and give me a '
      'short rundown.',
  domains: {'email', 'tasks'},
  actionLabels: ['review_emails', 'create_tasks'],
  requiredOutputs: {
    ResponseOutputType.rundown,
    ResponseOutputType.taskList,
  },
  requiresSynthesis: true,
);

final report = AgentExecutionReport(
  originalRequest: contract.originalRequest,
  toolsCalled: const ['read_email_context', 'create_task'],
  actionsCompleted: const ['Read 2 email(s)', 'Created task: Reply to Amy'],
  actionsFailed: const [],
  tasksCreated: const [
    {'id': 'task_1', 'title': 'Reply to Amy'},
  ],
  eventsCreated: const [],
  eventsModified: const [],
  emailDigestItems: const [
    {'sender': 'Amy', 'subject': 'Reports', 'summary': 'Wants an update.'},
  ],
  filesAffected: const [],
  screensCreated: const [],
  rulesChanged: const [],
  warnings: const [],
  uncertainItems: const [],
  partialFailures: const [],
);

void main() {
  const synthesizer = ResponseSynthesizer();

  group('room to write the reply', () {
    Future<int> limitSent(int? budget, {bool thinking = true}) async {
      late int sent;
      final http.Client mock = MockClient((request) async {
        sent = (jsonDecode(request.body) as Map)['max_tokens'] as int;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {
                  'role': 'assistant',
                  'content': '{"message": "ok", "included_outputs": []}',
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final AiClient client = thinking
          ? LocalEndpointClient(
              baseUrl: 'http://localhost:1234', httpClient: mock)
          : _NoHeadroomClient(mock);
      await synthesizer.synthesize(
        client: client,
        model: 'local',
        contract: contract,
        report: report,
        responseTokenBudget: budget,
      );
      return sent;
    }

    test('a short reply still leaves a thinking model room to think',
        () async {
      // 180 tokens of reply used to be sent as a 512-token ceiling. The
      // model spent all 512 deliberating and the message was never written.
      expect(await limitSent(180),
          512 + LocalEndpointClient.defaultReasoningHeadroom);
      expect(await limitSent(1040),
          2080 + LocalEndpointClient.defaultReasoningHeadroom);
    });

    test('the ceiling is still the ceiling', () async {
      expect(await limitSent(4000), 8192);
      expect(await limitSent(null), 8192);
    });

    test('a provider with no thinking to allow for is sized as before',
        () async {
      expect(await limitSent(180, thinking: false), 512);
      expect(await limitSent(1040, thinking: false), 2080);
    });
  });

  test('no tools are passed to the synthesis call', () async {
    final client = FakeAiClient('{"message": "Here is your rundown.", '
        '"included_outputs": ["rundown", "task_list"]}');
    await synthesizer.synthesize(
      client: client,
      model: 'test-model',
      contract: contract,
      report: report,
    );
    expect(client.calls.single.tools, isEmpty);
  });

  test('the prompt carries request, outputs, and the execution report',
      () async {
    final client = FakeAiClient('{"message": "ok", "included_outputs": []}');
    await synthesizer.synthesize(
      client: client,
      model: 'test-model',
      contract: contract,
      report: report,
      draftResponse: 'internal draft text',
    );
    final prompt =
        client.calls.single.messages.single['content'] as String;
    expect(prompt, contains(contract.originalRequest));
    expect(prompt, contains('rundown'));
    expect(prompt, contains('task_list'));
    // Contract actions are tool-style labels; the prompt carries them in
    // words the model can safely repeat, never as identifiers to echo.
    expect(prompt, contains('review emails'));
    expect(prompt, isNot(contains('review_emails')));
    // The normalized report rides along as JSON.
    expect(prompt, contains('"tasks_created"'));
    expect(prompt, contains('Reply to Amy'));
    expect(prompt, contains('internal draft text'));
  });

  group('written for the reader, not the developer', () {
    test('the system prompt carries the voice rules', () {
      expect(ResponseSynthesizer.systemPrompt, contains(ResponseVoice.rules));
      expect(ResponseSynthesizer.systemPrompt,
          contains('Never mention tool names'));
      expect(ResponseSynthesizer.systemPrompt,
          contains('not headings'));
      // The old instruction that produced "Rundown: … Task list: …" is gone.
      expect(ResponseSynthesizer.systemPrompt,
          isNot(contains('Ensure every required response output is included')));
    });

    test('required outputs are listed with what the reader needs', () {
      final prompt = ResponseSynthesizer.buildPrompt(
        contract: contract,
        report: report,
      );
      expect(prompt, contains('- rundown: ${ResponseOutputType.rundown.readerNeed}'));
      expect(prompt,
          contains('- task_list: ${ResponseOutputType.taskList.readerNeed}'));
      expect(prompt, contains('a checklist for you, not headings'));
      expect(prompt, contains('one short sentence covers it'));
    });

    test('actions are translated and statuses are plain words', () {
      final prompt = ResponseSynthesizer.buildPrompt(
        contract: testContract(
          originalRequest: 'digest my WhatsApp messages',
          actions: const [
            ContractAction(
              id: 'a1',
              description: 'sync_messages',
              status: ContractItemStatus.completed,
            ),
            ContractAction(
              id: 'a2',
              description: 'mark_message_digested',
              status: ContractItemStatus.pending,
            ),
          ],
          requiredOutputs: {ResponseOutputType.confirmation},
        ),
        report: report,
      );
      expect(prompt, contains('- check for new chat messages - done'));
      expect(prompt, contains('- mark chat messages as handled - not done'));
      expect(prompt, isNot(contains('sync_messages')));
      expect(prompt, isNot(contains('mark_message_digested')));
      expect(prompt, isNot(contains('[pending]')));
      expect(prompt, isNot(contains('[completed]')));
    });

    test('the execution report is marked internal', () {
      final prompt = ResponseSynthesizer.buildPrompt(
        contract: contract,
        report: report,
      );
      expect(prompt, contains('Execution report (internal JSON'));
      expect(prompt, contains('never quote its field names'));
    });

    AgentExecutionReport quietReport(List<String> tools) =>
        AgentExecutionReport(
          originalRequest: 'digest my WhatsApp messages',
          toolsCalled: tools,
          actionsCompleted: const ['Checked chats: nothing new'],
          actionsFailed: const [],
          tasksCreated: const [],
          eventsCreated: const [],
          eventsModified: const [],
          emailDigestItems: const [],
          filesAffected: const [],
          screensCreated: const [],
          rulesChanged: const [],
          warnings: const [],
          uncertainItems: const [],
          partialFailures: const [],
        );

    final quietContract = testContract(
      originalRequest: 'digest my WhatsApp messages',
      actions: const [
        ContractAction(
          id: 'a1',
          description: 'sync_messages',
          status: ContractItemStatus.completed,
        ),
      ],
      requiredOutputs: {ResponseOutputType.rundown},
    );

    test('a housekeeping run that found nothing gets the keep-it-short hint',
        () {
      final prompt = ResponseSynthesizer.buildPrompt(
        contract: quietContract,
        report: quietReport(const ['sync_messages', 'read_message_context']),
      );
      expect(prompt, contains('Nothing was created or changed'));
      expect(prompt, contains('No empty sections'));
    });

    test('the hint is withheld when anything was made, failed or left undone',
        () {
      // Something created: the turn is not quiet.
      final made = AgentExecutionReport(
        originalRequest: 'x',
        toolsCalled: const ['sync_messages'],
        actionsCompleted: const ['Checked chats'],
        actionsFailed: const [],
        tasksCreated: const [
          {'id': 't1', 'title': 'Reply to Dana'},
        ],
        eventsCreated: const [],
        eventsModified: const [],
        emailDigestItems: const [],
        filesAffected: const [],
        screensCreated: const [],
        rulesChanged: const [],
        warnings: const [],
        uncertainItems: const [],
        partialFailures: const [],
      );
      expect(
        ResponseSynthesizer.buildPrompt(contract: quietContract, report: made),
        isNot(contains('Nothing was created or changed')),
      );
      // A non-housekeeping tool (the list is the answer): not quiet.
      expect(
        ResponseSynthesizer.buildPrompt(
          contract: quietContract,
          report: quietReport(const ['sync_messages', 'list_tasks']),
        ),
        isNot(contains('Nothing was created or changed')),
      );
      // A required action left undone must be disclosed: not quiet.
      expect(
        ResponseSynthesizer.buildPrompt(
          contract: testContract(
            actions: const [
              ContractAction(
                id: 'a1',
                description: 'mark_message_digested',
                status: ContractItemStatus.pending,
              ),
            ],
          ),
          report: quietReport(const ['sync_messages']),
        ),
        isNot(contains('Nothing was created or changed')),
      );
      // No tools at all: nothing to be quiet about.
      expect(
        ResponseSynthesizer.buildPrompt(
          contract: quietContract,
          report: quietReport(const []),
        ),
        isNot(contains('Nothing was created or changed')),
      );
    });
  });

  test('the system prompt forbids repeating or inventing actions', () {
    expect(ResponseSynthesizer.systemPrompt, contains('Do not call tools'));
    expect(ResponseSynthesizer.systemPrompt,
        contains('Do not repeat actions'));
    expect(ResponseSynthesizer.systemPrompt,
        contains('Do not invent completed actions'));
    expect(ResponseSynthesizer.systemPrompt,
        contains('Do not claim success for failed actions'));
  });

  test('structured replies parse into message + declared outputs', () async {
    final client = FakeAiClient('{"message": "I reviewed 2 emails...", '
        '"included_outputs": ["rundown", "task_list"]}');
    final response = await synthesizer.synthesize(
      client: client,
      model: 'test-model',
      contract: contract,
      report: report,
    );
    expect(response.message, 'I reviewed 2 emails...');
    expect(response.includedOutputs,
        {ResponseOutputType.rundown, ResponseOutputType.taskList});
  });

  test('plain-text replies degrade to a message with no declared outputs',
      () {
    final response = SynthesizedResponse.parse('Just prose, no JSON.');
    expect(response.message, 'Just prose, no JSON.');
    expect(response.includedOutputs, isEmpty);
  });

  group('malformed envelopes from smaller models', () {
    // Reduced from a real Ministral reply that rendered as raw JSON in chat:
    // the message value carries literal newlines, which RFC 8259 forbids
    // inside a string, so the whole envelope failed to decode.
    const rawNewlinesInMessage = '''
```json
{
 "message": "
 - **Summary**: The snippet was stored and a reminder was created.

 - **Stored File**: snippet_1785031294223.png (30.1 KB).
 ",
 "included_outputs": ["summary", "follow_up_question"],
 "claims": [
  {"type": "file_stored", "description": "Stored snippet_1785031294223.png"}
 ],
 "includes_failure_report": true
}
```''';

    test('repairs literal newlines inside the message string', () {
      final response = SynthesizedResponse.parse(rawNewlinesInMessage);

      expect(response.message, startsWith('- **Summary**:'));
      expect(response.message, contains('30.1 KB'));
      // The envelope must not leak into what the user reads.
      expect(response.message, isNot(contains('included_outputs')));
      expect(response.message, isNot(contains('```')));
      // Structure survives the repair, so no needless repair round-trip.
      expect(response.includedOutputs, {
        ResponseOutputType.summary,
        ResponseOutputType.followUpQuestion,
      });
      expect(response.claims.single.type, 'file_stored');
      expect(response.includesFailureReport, isTrue);
    });

    test('salvages the message when the envelope cannot be decoded at all',
        () {
      // Truncated mid-claims, so no repair strategy can produce valid JSON.
      const truncated = '''
{
 "message": "Stored the snippet and set a reminder for Monday.",
 "claims": [{"type": "file_stored", "descrip''';

      final response = SynthesizedResponse.parse(truncated);

      expect(
        response.message,
        'Stored the snippet and set a reminder for Monday.',
      );
      expect(response.message, isNot(contains('claims')));
    });

    test('a message containing quotes and braces survives salvage', () {
      const awkward = '''
{
 "message": "I stored "snippet.png" and set {2} reminders.",
 "included_outputs": ["summary"]''';

      final response = SynthesizedResponse.parse(awkward);

      expect(response.message, 'I stored "snippet.png" and set {2} reminders.');
    });
  });
}

/// An OpenAI-compatible backend that declares no reasoning headroom.
class _NoHeadroomClient extends LocalEndpointClient {
  _NoHeadroomClient(http.Client mock)
      : super(baseUrl: 'http://localhost:1234', httpClient: mock);

  @override
  int get reasoningHeadroom => 0;
}
