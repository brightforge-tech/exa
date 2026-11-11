/// The chat apps Exa can read, mirrored from Kotlin's `ChatPackages`.
///
/// The two copies exist because the notification listener has to decide
/// whether to keep a notification with no Flutter engine alive, and this
/// side has to render a settings list and name a channel in a tool result.
/// `messaging_channels_test.dart` reads the Kotlin source and fails if they
/// disagree — cheaper than a platform round trip on every render, and it
/// catches the failure that actually happens (someone adds Telegram to one
/// list only).
class MessageChannels {
  MessageChannels._();

  static const whatsapp = 'whatsapp';
  static const whatsappBusiness = 'whatsapp_business';
  static const signal = 'signal';
  static const telegram = 'telegram';
  static const sms = 'sms';
  static const teams = 'teams';
  static const outlook = 'outlook';
  static const gmail = 'gmail';

  /// Channel key → the package that produces it.
  static const packageByChannel = <String, String>{
    whatsapp: 'com.whatsapp',
    whatsappBusiness: 'com.whatsapp.w4b',
    signal: 'org.thoughtcrime.securesms',
    telegram: 'org.telegram.messenger',
    sms: 'com.google.android.apps.messaging',
    teams: 'com.microsoft.teams',
    outlook: 'com.microsoft.office.outlook',
    gmail: 'com.google.android.gm',
  };

  static const displayNames = <String, String>{
    whatsapp: 'WhatsApp',
    whatsappBusiness: 'WhatsApp Business',
    signal: 'Signal',
    telegram: 'Telegram',
    sms: 'Messages (SMS)',
    teams: 'Microsoft Teams',
    outlook: 'Outlook',
    gmail: 'Gmail',
  };

  static const all = [
    whatsapp,
    whatsappBusiness,
    signal,
    telegram,
    sms,
    teams,
    outlook,
    gmail,
  ];

  static String displayName(String channel) =>
      displayNames[channel] ?? channel;

  static bool isKnown(String channel) => packageByChannel.containsKey(channel);

  static String? channelForPackage(String package) {
    for (final entry in packageByChannel.entries) {
      if (entry.value == package) return entry.key;
    }
    return null;
  }
}
