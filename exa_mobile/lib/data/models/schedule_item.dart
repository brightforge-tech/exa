import 'agent_datetime_label.dart';

class ScheduleItem {
  final String id;
  final String title;
  final String? description;
  final String? location;
  final DateTime startAt;
  final DateTime? endAt;
  final String source;
  final String? externalId;
  final String status;

  /// Minutes before [startAt] to fire the heads-up notification (0 = at start).
  final int leadTimeMinutes;

  /// Ref ("calendarId:eventId") of this event's mirror on the phone calendar,
  /// or null when it has not been mirrored there.
  final String? deviceEventId;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ScheduleItem({
    required this.id,
    required this.title,
    this.description,
    this.location,
    required this.startAt,
    this.endAt,
    this.source = 'local',
    this.externalId,
    this.status = 'Confirmed',
    this.leadTimeMinutes = 0,
    this.deviceEventId,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, Object?> toRow() => {
        'id': id,
        'title': title,
        'description': description,
        'location': location,
        'start_at': startAt.toIso8601String(),
        'end_at': endAt?.toIso8601String(),
        'source': source,
        'external_id': externalId,
        'status': status,
        'lead_time_minutes': leadTimeMinutes,
        'device_event_id': deviceEventId,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory ScheduleItem.fromRow(Map<String, Object?> row) => ScheduleItem(
        id: row['id'] as String,
        title: row['title'] as String,
        description: row['description'] as String?,
        location: row['location'] as String?,
        startAt: DateTime.tryParse(row['start_at'] as String? ?? '') ??
            DateTime.now(),
        endAt: row['end_at'] is String
            ? DateTime.tryParse(row['end_at'] as String)
            : null,
        source: row['source'] as String? ?? 'local',
        externalId: row['external_id'] as String?,
        status: row['status'] as String? ?? 'Confirmed',
        leadTimeMinutes: (row['lead_time_minutes'] as int?) ?? 0,
        deviceEventId: row['device_event_id'] as String?,
        createdAt:
            DateTime.tryParse(row['created_at'] as String? ?? '') ??
                DateTime.now(),
        updatedAt:
            DateTime.tryParse(row['updated_at'] as String? ?? '') ??
                DateTime.now(),
      );

  Map<String, Object?> toAgentJson() => {
        'id': id,
        'title': title,
        if (description != null) 'description': description,
        if (location != null) 'location': location,
        'start_at': startAt.toIso8601String(),
        // Quote this, don't re-derive the weekday - see [agentDateTimeLabel].
        'start_at_label': agentDateTimeLabel(startAt),
        if (endAt != null) 'end_at': endAt!.toIso8601String(),
        if (endAt != null) 'end_at_label': agentDateTimeLabel(endAt!),
        if (leadTimeMinutes > 0) 'lead_time_minutes': leadTimeMinutes,
        'status': status,
        if (deviceEventId != null) 'on_phone_calendar': true,
      };
}
