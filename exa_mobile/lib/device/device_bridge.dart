import 'package:flutter/services.dart';

/// Bridge to the `exa_device` plugin (`ExaDevicePlugin.kt`).
///
/// Like `PhoneBridge`, this channel is registered by a *plugin*, so it is
/// live in every engine - the app, the overlay, and the background isolates
/// that run scheduled jobs. Every method degrades to a safe answer
/// off-Android rather than throwing: tests and desktop runs have no plugin,
/// and callers read the outcome instead of catching exceptions. Methods are
/// non-final so tests can subclass this with a fake.
class DeviceBridge {
  const DeviceBridge();

  static const _channel = MethodChannel('com.brightforge.exa/device');

  Future<T?> call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<Map<Object?, Object?>?> callMap(String method,
          [Map<String, Object?>? args]) =>
      call<Map<Object?, Object?>>(method, args);
}
