import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../services/phone/phone_bridge.dart';
import '../../shared/theme/exa_theme.dart';

/// Grants the three runtime permissions behind the phone tools and says, in
/// the same breath, what Exa does and does not do with them: every text,
/// call and WhatsApp message is confirmed in chat first, and a scheduled one
/// happens only for a job the user set up with that exact grant.
class PhoneAccessScreen extends ConsumerStatefulWidget {
  const PhoneAccessScreen({super.key});

  @override
  ConsumerState<PhoneAccessScreen> createState() => _PhoneAccessScreenState();
}

class _PhoneAccessScreenState extends ConsumerState<PhoneAccessScreen> {
  PhonePermissions _status = const PhonePermissions();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final status = await ref.read(phoneBridgeProvider).permissions();
    if (!mounted) return;
    setState(() {
      _status = status;
      _loaded = true;
    });
  }

  Future<void> _request(Permission permission) async {
    final result = await permission.request();
    if (result.isPermanentlyDenied && mounted) {
      // Android will not show the prompt again; the system page is the only
      // way left, so offer it rather than a button that does nothing.
      final open = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Allow it in system settings'),
          content: const Text(
              'Android has stopped asking for this permission. Open Exa\'s '
              'app settings and allow it under Permissions.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Not now')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Open settings')),
          ],
        ),
      );
      if (open == true) await openAppSettings();
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Phone access')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'Let Exa text, call and message people for you. In chat '
                    'Exa always shows you the recipient and the wording and '
                    'asks before sending. A scheduled job ("text Mum every '
                    'Friday at five") can only send if you set it up with '
                    'that exact permission - it is written on the job in '
                    'Settings > Scheduled jobs.',
                    style:
                        TextStyle(color: ExaColors.textSecondary, height: 1.4),
                  ),
                ),
                if (!_status.telephony)
                  const ListTile(
                    leading: Icon(Icons.signal_cellular_off,
                        color: ExaColors.warning),
                    title: Text('This device has no phone radio'),
                    subtitle: Text('Texts and calls are not available here; '
                        'WhatsApp and contacts still are.'),
                  ),
                _PermissionTile(
                  icon: Icons.contacts_outlined,
                  title: 'Contacts',
                  granted: _status.contacts,
                  grantedText: 'Exa can turn a name into a number',
                  deniedText: 'Needed to text or call someone by name '
                      'instead of by number',
                  onRequest: () => _request(Permission.contacts),
                ),
                _PermissionTile(
                  icon: Icons.sms_outlined,
                  title: 'Send text messages (SMS)',
                  granted: _status.sms,
                  grantedText: 'Sent from your own number, after you confirm',
                  deniedText: 'Without this, "text Mum" can only open your '
                      'messaging app',
                  onRequest: () => _request(Permission.sms),
                ),
                _PermissionTile(
                  icon: Icons.call_outlined,
                  title: 'Make phone calls',
                  granted: _status.call,
                  grantedText: 'Exa can start the call itself, after you '
                      'confirm',
                  deniedText: 'Without this, "call Dad" opens the dialler '
                      'with the number ready for you to tap',
                  onRequest: () => _request(Permission.phone),
                ),
                const Divider(),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'WhatsApp needs no permission - and gives none: a '
                    'personal WhatsApp account has no way for an app to send '
                    'on its own. Exa replies through a chat\'s notification '
                    'while the message is still unread in your shade; '
                    'otherwise it opens WhatsApp with the message typed in '
                    'and you tap Send. A scheduled WhatsApp becomes a '
                    'one-tap notification. Exa will always tell you which of '
                    'these happened.\n\n'
                    'A scheduled call dials only while the phone is on and '
                    'unlocked; otherwise you get a "Call now" notification '
                    'instead of a phone ringing someone from your pocket.',
                    style:
                        TextStyle(color: ExaColors.textSecondary, height: 1.4),
                  ),
                ),
              ],
            ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({
    required this.icon,
    required this.title,
    required this.granted,
    required this.grantedText,
    required this.deniedText,
    required this.onRequest,
  });

  final IconData icon;
  final String title;
  final bool granted;
  final String grantedText;
  final String deniedText;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: granted ? ExaColors.success : null),
      title: Text(title),
      subtitle: Text(granted ? grantedText : deniedText),
      trailing: granted
          ? const Icon(Icons.check_circle, color: ExaColors.success)
          : FilledButton.tonal(
              onPressed: onRequest,
              child: const Text('Allow'),
            ),
    );
  }
}
