import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'services/background_jobs/background_worker.dart';
import 'services/background_jobs/job_runner.dart';

/// Channel shared with `ExaJobService.kt`.
const jobServiceChannelName = 'com.brightforge.exa/job_service';

/// Entry point for the FlutterEngine hosted by `ExaJobService`: runs whatever
/// scheduled jobs are due, under the service's time allowance instead of a
/// background worker's, and tells the service when it is finished.
///
/// Always reports back, whatever happened. The service has a watchdog for a
/// run that never does, but waiting twenty-five minutes on it with a
/// notification showing is a poor way to learn that a database would not
/// open.
@pragma('vm:entry-point')
Future<void> jobServiceMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  const channel = MethodChannel(jobServiceChannelName);

  var woken = false;
  channel.setMethodCallHandler((call) async {
    // Another alarm fired while this run was going.
    if (call.method == 'wake') woken = true;
    return null;
  });

  try {
    await runBackgroundPass(
      triggerSource: 'alarm',
      budget: JobRunner.serviceBudget,
      // Anything that came due while the first pass was running is run
      // before the service stops, rather than waiting on the next alarm.
      passes: 4,
      shouldRunAgain: () {
        final again = woken;
        woken = false;
        return again;
      },
      onStatus: (text) async {
        try {
          await channel.invokeMethod<void>('status', {'text': text});
        } catch (_) {
          // The notification text is a courtesy.
        }
      },
    );
  } catch (_) {
    // Recorded by the pass itself where it can be; nothing more to do here.
  } finally {
    try {
      await channel.invokeMethod<void>('done');
    } catch (_) {
      // The service's watchdog ends it.
    }
  }
}
