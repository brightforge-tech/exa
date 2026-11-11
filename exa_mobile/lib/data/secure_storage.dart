import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The app's single secure-storage configuration.
///
/// `resetOnError` exists because of a failure mode that is otherwise
/// permanent: the Android Keystore master key is destroyed when the app is
/// uninstalled, but a cloud backup can restore the *encrypted*
/// EncryptedSharedPreferences file afterwards. The app then holds ciphertext
/// whose key no longer exists, and every read throws `BAD_DECRYPT` forever -
/// mail sync fails on every run with a platform error nobody can act on.
///
/// With this set, the platform clears the unreadable store and starts fresh
/// instead. The secrets are gone either way; the difference is between a
/// clean "no password stored, add one" path and an error loop.
const appSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(resetOnError: true),
);

/// Whether [error] is the platform failing to decrypt its own store rather
/// than an ordinary read failure - the signal that stored secrets are
/// unrecoverable and must be re-entered.
bool isDecryptionFailure(Object error) {
  final text = error.toString().toUpperCase();
  return text.contains('BAD_DECRYPT') ||
      text.contains('BADPADDING') ||
      text.contains('AEADBADTAG') ||
      text.contains('DECRYPTION FAILED');
}

/// What to tell the user when their stored secret cannot be decrypted. The
/// platform error text on its own ("Platform decryption error") gives them
/// nothing to do.
const credentialsUnreadableMessage =
    'Stored credentials could not be decrypted, which happens when the app '
    'is reinstalled or restored from a backup - the encryption key does not '
    'survive that. They have been cleared. Re-enter the password in '
    'Settings > Mail accounts (and sign in to Google again for Gmail '
    'accounts).';

/// Thrown when a stored secret exists but cannot be decrypted, so the user
/// has to re-enter it. Distinct from "nothing stored", which is a normal
/// not-configured-yet state.
class CredentialsUnreadable implements Exception {
  const CredentialsUnreadable();

  @override
  String toString() => credentialsUnreadableMessage;
}
