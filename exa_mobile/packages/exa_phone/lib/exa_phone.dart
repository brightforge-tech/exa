/// Exa's phone access plugin.
///
/// The Dart side of this plugin lives in the app (`lib/services/phone/
/// phone_bridge.dart`), next to the other native bridges and their tests.
/// This package exists so the native half is registered as a *plugin*: the
/// generated plugin registrant runs for every FlutterEngine in the process -
/// the app, the overlay engine, and the WorkManager/alarm background isolates
/// that run scheduled jobs - whereas a channel registered in MainActivity is
/// only reachable from the main engine. Sending a scheduled text has to work
/// from the background isolate, so it has to be a plugin.
library;

/// The method channel name shared with `ExaPhonePlugin.kt`.
const String exaPhoneChannelName = 'com.brightforge.exa/phone';
