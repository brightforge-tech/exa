// Convert `flutter test --reporter json` into the JUnit XML the controller
// collects: `flutter test --reporter json | dart tools/json_to_junit.dart`.
//
// The wrapper exists because nothing else speaks both languages. `flutter
// test` has no built-in JUnit output; the controller's test collection and
// its before/after comparison read JUnit XML. Everything here is
// bookkeeping — the one thing it must never get wrong is the exit status:
// a conversion that swallows a failing suite turns red into green, which is
// worse than no report at all.
//
// Output path: $COUNCIL_JUNIT when set, otherwise build/reports/flutter-
// junit.xml resolved against the repository root (the parent of this tool's
// own directory, so the pipe works from anywhere).
import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  final stdinLines = stdin
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter());

  // testID -> the test's own record (name, suite id, pool).
  final tests = <int, Map<String, Object?>>{};
  // suiteID -> suite path, already cleaned to a repo-relative string.
  final suitePaths = <int, String>{};
  // testID -> printed lines, used as the failure detail when the event
  // itself carries no error text.
  final prints = <int, List<String>>{};
  // suite path -> aggregated counters and cases.
  final suites = <String, _Suite>{};

  var sawDone = false;
  var flutterSucceeded = false;
  var anyErrorResult = false;

  await for (final line in stdinLines) {
    if (line.isEmpty || !line.startsWith('{')) continue;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue; // flutter's own banner lines are not JSON; skip them.
    }
    if (decoded is! Map<String, Object?>) continue;
    final event = decoded;
    switch (event['type']) {
      case 'suite':
        final suite = event['suite'];
        if (suite is Map) {
          suitePaths[suite['id'] as int] = _suitePath(suite['path']);
        }
      case 'testStart':
        final test = event['test'];
        if (test is Map) {
          tests[(test['id'] as int?) ?? -1] = Map.castFrom(test);
        }
      case 'print':
        final id = (event['testID'] as int?) ?? -1;
        final message = event['message'] as String? ?? '';
        if (message.isNotEmpty) {
          (prints[id] ??= <String>[]).add(message);
        }
      case 'testDone':
        final id = (event['testID'] as int?) ?? -1;
        final test = tests[id];
        // Tests marked hidden are machinery (suite loading), not cases.
        if (event['hidden'] == true) continue;
        if (test == null) continue;
        final suitePath =
            suitePaths[(test['suiteID'] as int?) ?? -1] ?? 'unknown';
        final suite = suites.putIfAbsent(suitePath, () => _Suite(suitePath));
        final name = test['name'] as String? ?? '(unnamed)';
        // A test's full name is what distinguishes two same-named cases in
        // one file only by group; keep the group prefix flutter gives.
        final result = event['result'] as String? ?? 'error';
        final skipped = event['skipped'] == true || result == 'skip';
        suite.cases.add(
          _Case(
            name: name,
            skipped: skipped,
            failed: !skipped && result != 'success',
            isError: !skipped && result == 'error',
            seconds: ((event['time'] as num?)?.toInt() ?? 0) / 1000.0,
            detail: prints[id]?.join('\n') ?? event['error'] as String? ?? '',
          ),
        );
        if (result == 'error') anyErrorResult = true;
      case 'done':
        sawDone = true;
        flutterSucceeded = event['success'] == true;
    }
  }

  final sink = StringBuffer();
  final total = suites.values.fold(0, (n, s) => n + s.cases.length);
  final failures = suites.values.fold(
    0,
    (n, s) => n + s.cases.where((c) => c.failed).length,
  );
  final errors = suites.values.fold(
    0,
    (n, s) => n + s.cases.where((c) => c.isError).length,
  );
  final skipped = suites.values.fold(
    0,
    (n, s) => n + s.cases.where((c) => c.skipped).length,
  );
  sink.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  sink.writeln(
    '<testsuites tests="$total" failures="$failures" errors="$errors" '
    'skipped="$skipped">',
  );
  final names = suites.keys.toList()..sort();
  for (final name in names) {
    final suite = suites[name]!;
    final suiteFailed = suite.cases.where((c) => c.failed || c.isError).length;
    sink.writeln(
      '  <testsuite name="${_xml(name)}" tests="${suite.cases.length}" '
      'failures="$suiteFailed" errors="0">',
    );
    for (final testCase in suite.cases) {
      if (testCase.skipped) {
        sink.writeln(
          '    <testcase name="${_xml(testCase.name)}">'
          '<skipped/></testcase>',
        );
      } else if (testCase.failed) {
        sink.writeln(
          '    <testcase name="${_xml(testCase.name)}" time="${testCase.seconds}">',
        );
        sink.writeln(
          '      <failure message="${_xml(testCase.detail.split('\n').first)}">'
          '${_xml(testCase.detail)}</failure>',
        );
        sink.writeln('    </testcase>');
      } else {
        sink.writeln(
          '    <testcase name="${_xml(testCase.name)}" '
          'time="${testCase.seconds}"/>',
        );
      }
    }
    sink.writeln('  </testsuite>');
  }
  sink.writeln('</testsuites>');

  final outPath =
      Platform.environment['COUNCIL_JUNIT'] ??
      _repoRootPath('build/reports/flutter-junit.xml');
  final out = File(outPath);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(sink.toString());
  stderr.writeln(
    'json_to_junit: wrote ${out.absolute.path} '
    '($total tests, $failures failures, $errors errors, $skipped skipped)',
  );

  // The exit status is the contract: mirror flutter's verdict, and treat a
  // truncated stream (no done event) as a failure so a crash mid-suite can
  // never read as green.
  if (!sawDone || !flutterSucceeded || anyErrorResult) exitCode = 1;
}

/// flutter reports suite paths as `file:///...` URIs (or plain paths on
/// some SDK versions); keep them short and comparable.
String _suitePath(Object? raw) {
  var path = raw as String? ?? 'unknown';
  if (path.startsWith('file:///')) {
    path = Uri.parse(path).toFilePath();
  } else if (path.startsWith('file://')) {
    path = path.substring('file://'.length);
  }
  final normalized = path.replaceAll(r'\', '/');
  final testDir = normalized.lastIndexOf('/test/');
  return testDir >= 0 ? normalized.substring(testDir + 1) : normalized;
}

String _xml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    // Strip ANSI colour codes FIRST: the ESC they start with is itself a
    // control character, and removing controls first would strand the
    // '[31m' tail inside the report.
    .replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), '')
    // JUnit is XML 1.0: control characters other than tab/newline are not
    // allowed, and failure output can carry them.
    .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');

/// This tool lives in `.../tools/`, so the parent of its script directory is
/// the repository root the default report path is resolved against.
String _repoRootPath(String relative) {
  final scriptDir = File.fromUri(Platform.script).parent.parent.path;
  return '$scriptDir/${relative.replaceAll('/', Platform.pathSeparator)}'
      .replaceAll(Platform.pathSeparator * 2, Platform.pathSeparator);
}

class _Suite {
  _Suite(this.path);
  final String path;
  final cases = <_Case>[];
}

class _Case {
  _Case({
    required this.name,
    required this.skipped,
    required this.failed,
    required this.isError,
    required this.seconds,
    required this.detail,
  });
  final String name;
  final bool skipped;
  final bool failed;
  final bool isError;
  final double seconds;
  final String detail;
}
