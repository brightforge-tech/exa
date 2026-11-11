import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/chat_message.dart';

class ChatRepository {
  ChatRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<ChatMessage> append(
    String role,
    String content, {
    Map<String, Object?>? meta,
  }) async {
    final message = ChatMessage(
      id: _uuid.v4(),
      role: role,
      content: content,
      meta: meta,
      createdAt: DateTime.now(),
    );
    await _database.db.insert('chat_messages', message.toRow());
    return message;
  }

  Future<List<ChatMessage>> recent({int limit = 100}) async {
    final rows = await _database.db.query(
      'chat_messages',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(ChatMessage.fromRow).toList().reversed.toList();
  }

  Future<void> clear() => _database.db.delete('chat_messages');
}
