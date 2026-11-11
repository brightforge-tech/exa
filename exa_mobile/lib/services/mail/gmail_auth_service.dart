import 'package:google_sign_in/google_sign_in.dart';

/// A Gmail-auth failure with a message safe to show the user (and the
/// agent, which relays it).
class GmailAuthException implements Exception {
  const GmailAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// "Sign in with Google" for Gmail mail accounts.
///
/// Interactive sign-in happens once, from the Mail accounts screen. After
/// that, [accessTokenFor] silently gets a fresh OAuth access token from
/// Play Services whenever the mail service connects - tokens are never
/// stored by the app, and Google handles refresh under the hood.
///
/// The `https://mail.google.com/` scope is full IMAP/SMTP access, which is
/// what XOAUTH2 authentication against Gmail's mail servers requires.
class GmailAuthService {
  GmailAuthService({GoogleSignIn? googleSignIn}) : _injected = googleSignIn;

  static const scopes = ['https://mail.google.com/', 'email'];

  final GoogleSignIn? _injected;
  GoogleSignIn? _lazy;

  // Constructed on first use so merely creating this service (e.g. in unit
  // tests or on app start) never touches the plugin channel.
  GoogleSignIn get _google =>
      _injected ?? (_lazy ??= GoogleSignIn(scopes: scopes));

  /// Interactive sign-in. Returns the signed-in account, or null when the
  /// user cancels the Google account picker.
  Future<GoogleSignInAccount?> signIn() async {
    try {
      return await _google.signIn();
    } on Exception catch (e) {
      throw GmailAuthException(_friendly(e));
    }
  }

  /// A fresh access token for [emailAddress], obtained silently. Throws
  /// [GmailAuthException] with reconnect guidance when that isn't possible
  /// (signed out, account switched, consent revoked).
  Future<String> accessTokenFor(String emailAddress) async {
    GoogleSignInAccount? account;
    try {
      account = _google.currentUser ?? await _google.signInSilently();
    } on Exception catch (e) {
      throw GmailAuthException(_friendly(e));
    }
    if (account == null) {
      throw const GmailAuthException(
          'Google sign-in has expired. Open Settings > Mail accounts and '
          'sign in with Google again.');
    }
    if (account.email.toLowerCase() != emailAddress.toLowerCase()) {
      throw GmailAuthException(
          'A different Google account (${account.email}) is signed in. '
          'Open Settings > Mail accounts and sign in with Google as '
          '$emailAddress.');
    }
    final auth = await account.authentication;
    final token = auth.accessToken;
    if (token == null || token.isEmpty) {
      throw const GmailAuthException(
          'Google did not return an access token. Open Settings > Mail '
          'accounts and sign in with Google again.');
    }
    return token;
  }

  /// Disconnects the Google session (used when the user removes their
  /// Gmail account). Best-effort: a failure here must not block removal.
  Future<void> signOut() async {
    try {
      await _google.disconnect();
    } catch (_) {
      try {
        await _google.signOut();
      } catch (_) {}
    }
  }

  static String _friendly(Exception e) {
    final text = e.toString();
    if (text.contains('network_error')) {
      return 'Could not reach Google - check your internet connection.';
    }
    if (text.contains('sign_in_failed') || text.contains('10:')) {
      return 'Google sign-in failed. This build may not be registered in '
          'Google Cloud yet (the OAuth client needs this app\'s package '
          'name and signing fingerprint).';
    }
    if (text.contains('MissingPluginException')) {
      return 'Google sign-in is not available in this environment.';
    }
    return 'Google sign-in failed: $text';
  }
}
