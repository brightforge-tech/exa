/// Exa's device-control plugin.
///
/// The Dart side of this plugin lives in the app (`lib/device/`), next to the
/// `DeviceControl` interface it implements and the tests that use a fake.
/// This package exists so the native half is registered as a *plugin*: the
/// generated plugin registrant runs for every FlutterEngine in the process -
/// the app, the overlay engine, and the WorkManager/alarm background isolates
/// that run scheduled jobs - whereas a channel registered in MainActivity is
/// only reachable from the main engine. "Lock the phone at 23:00" runs in the
/// background isolate, so it has to be a plugin.
library;

/// The method channel name shared with `ExaDevicePlugin.kt`.
const String exaDeviceChannelName = 'com.brightforge.exa/device';
