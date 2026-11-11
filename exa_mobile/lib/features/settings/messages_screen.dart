import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models/inbound_media.dart';
import '../../data/models/inbound_message.dart';
import '../../data/repositories/inbound_message_repository.dart';
import '../../services/messaging/message_channels.dart';
import '../../shared/providers.dart';
import '../../shared/widgets/exa_empty_state.dart';

/// Chat messages Exa has captured, grouped by conversation.
///
/// Grouped rather than a flat list because a flat one is unreadable the
/// moment a group chat is involved — forty messages from six people
/// interleaved with two from a contact is not something anyone can scan.
class MessagesScreen extends ConsumerWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatsAsync = ref.watch(conversationsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Captured messages'),
        actions: [
          IconButton(
            tooltip: 'Take in new messages',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              final result = await ref
                  .read(messageIngestServiceProvider)
                  .syncAllDetailed();
              ref.invalidate(conversationsProvider);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(result.summary)));
              }
            },
          ),
        ],
      ),
      body: chatsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (chats) {
          if (chats.isEmpty) {
            return const ExaEmptyState(
              icon: Icons.forum_outlined,
              title: 'No chat messages yet',
              message: 'Turn on capture in Settings > Chat apps to let Exa '
                  'read WhatsApp messages as they arrive, or share a chat '
                  'export to Exa to give it history.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [for (final chat in chats) _ChatTile(chat: chat)],
          );
        },
      ),
    );
  }
}

class _ChatTile extends ConsumerWidget {
  const _ChatTile({required this.chat});

  final ConversationSummary chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ExpansionTile(
      leading: Icon(chat.isGroup ? Icons.groups_outlined : Icons.person_outline),
      title: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          MessageChannels.displayName(chat.channel),
          '${chat.messageCount} message${chat.messageCount == 1 ? '' : 's'}',
          if (chat.hasMedia) 'with media',
          if (chat.undigestedCount > 0) '${chat.undigestedCount} new',
          if (chat.lastMessageAt != null)
            DateFormat('MMM d, HH:mm').format(chat.lastMessageAt!),
        ].join(' · '),
      ),
      trailing: chat.undigestedCount > 0
          ? Badge(label: Text('${chat.undigestedCount}'))
          : null,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      onExpansionChanged: (expanded) {
        if (expanded) ref.invalidate(_chatMessagesProvider(chat));
      },
      children: [
        _ChatBody(chat: chat),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (chat.undigestedCount > 0)
              TextButton.icon(
                icon: const Icon(Icons.done_all, size: 18),
                label: const Text('Mark all digested'),
                onPressed: () async {
                  await ref
                      .read(inboundMessageRepositoryProvider)
                      .markConversationDigested(
                        channel: chat.channel,
                        conversationId: chat.conversationId,
                      );
                  ref.invalidate(conversationsProvider);
                  ref.invalidate(_chatMessagesProvider(chat));
                },
              ),
            const SizedBox(width: 8),
          ],
        ),
        if (!chat.canReply)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Exa cannot reply to this chat right now — Android only allows '
              'a reply while a message is still unread in the shade.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// The small "photo 1.2 MB" marker on an inbox row. Deliberately a label
/// rather than a thumbnail or a play button: this screen shows what was
/// captured, and Android hands Exa a reply action, not a media viewer.
class _MediaChip extends StatelessWidget {
  const _MediaChip({required this.media});

  final InboundMedia media;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final audio = media.kind == InboundMedia.kindAudio;
    final size = media.sizeBytes == null
        ? ''
        : ' ${InboundMedia.formatBytes(media.sizeBytes!)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            audio ? Icons.play_circle_outline : Icons.image_outlined,
            size: 13,
            color: theme.textTheme.labelSmall?.color,
          ),
          const SizedBox(width: 4),
          Text(
            '${audio ? 'Voice note' : 'Photo'}$size',
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

/// Messages of one chat, fetched only when its tile is opened.
final _chatMessagesProvider = FutureProvider.autoDispose
    .family<List<InboundMessage>, ConversationSummary>((ref, chat) {
  return ref.watch(inboundMessageRepositoryProvider).inConversation(
        channel: chat.channel,
        conversationId: chat.conversationId,
        limit: 40,
      );
});

class _ChatBody extends ConsumerWidget {
  const _ChatBody({required this.chat});

  final ConversationSummary chat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messagesAsync = ref.watch(_chatMessagesProvider(chat));
    final theme = Theme.of(context);

    return messagesAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: LinearProgressIndicator(),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Error: $error'),
      ),
      data: (messages) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final message in messages.reversed.take(20).toList().reversed)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [
                      message.displaySender,
                      if (message.sentAt != null)
                        DateFormat('MMM d, HH:mm').format(message.sentAt!),
                      if (message.source == MessageSource.export) 'imported',
                      if (!message.digested) 'new',
                    ].join(' · '),
                    style: theme.textTheme.labelSmall,
                  ),
                  Text(
                    message.displayBody,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  if (message.hasMedia)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          for (final media in message.media)
                            _MediaChip(media: media),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
