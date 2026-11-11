# flutter_gemma bundles MediaPipe, whose Java bindings reference optional
# protobuf classes that R8 can't see. Suppress the warnings and keep the
# native-facing classes so JNI lookups don't break after shrinking.
-dontwarn com.google.mediapipe.proto.**
-dontwarn com.google.mediapipe.**
-keep class com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.protobuf.**

# android_alarm_manager_plus resolves its manifest-declared receiver and
# service through Class references at runtime; R8 renaming breaks that
# lookup ("Component class h6.d does not exist in com.brightforge.exa"),
# which silently killed the whole exact-alarm layer in release builds
# (reminders/jobs then only ran on the 15-minute WorkManager tick).
-keep class dev.fluttercommunity.plus.androidalarmmanager.** { *; }
-keep class io.flutter.plugins.androidalarmmanager.** { *; }

# device_calendar returns calendars and events to Dart as Gson-serialized
# JSON, and the Dart side reads them back by field name. Gson names those
# keys by reflection, so R8 renaming the fields - and deleting the ones
# Kotlin itself never reads - silently rewrites the payload: the release
# build had Calendar down to {"a":ownerAccount,"b":isReadOnly}, with id,
# name and isDefault gone entirely. Every phone-calendar write then failed
# ("The writable calendar has no id", later "No writable calendar found on
# this device") and every import found nothing, because Event lost eventId
# and title the same way. Enums are in here too: they serialize by .name.
-keep class com.builttoroam.devicecalendar.models.** { *; }

# ExaJobService is started by name from the device plugin (the plugin cannot
# depend on the app), so the name has to survive shrinking.
-keep class com.brightforge.exa.jobs.** { *; }
