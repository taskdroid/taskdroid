class Profile {
  final String id;
  final String name;
  final String uuid;
  final String secret;
  final String serverUrl;
  final bool calendarSync;
  final int? calendarId;
  final String? calendarName;
  final int? calendarReminderMinutes;
  final int recurrenceLimit;

  Profile({
    required this.id,
    required this.name,
    required this.uuid,
    required this.secret,
    required this.serverUrl,
    this.calendarSync = false,
    this.calendarId,
    this.calendarName,
    this.calendarReminderMinutes = 0,
    this.recurrenceLimit = 1,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'uuid': uuid,
      'secret': secret,
      'serverUrl': serverUrl,
      'calendarSync': calendarSync,
      'calendarId': calendarId,
      'calendarName': calendarName,
      'calendarReminderMinutes': calendarReminderMinutes,
      'recurrenceLimit': recurrenceLimit,
    };
  }

  static Profile fromJson(Map<String, dynamic> json) {
    return Profile(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      uuid: json['uuid'] as String? ?? '',
      secret: json['secret'] as String? ?? '',
      serverUrl: json['serverUrl'] as String? ?? '',
      calendarSync: json['calendarSync'] as bool? ?? false,
      calendarId: (json['calendarId'] as num?)?.toInt(),
      calendarName: json['calendarName'] as String?,
      calendarReminderMinutes:
          (json['calendarReminderMinutes'] as num?)?.toInt() ?? 0,
      recurrenceLimit: (json['recurrenceLimit'] as num?)?.toInt() ?? 1,
    );
  }

  Profile copyWith({
    String? id,
    String? name,
    String? uuid,
    String? secret,
    String? serverUrl,
    bool? calendarSync,
    int? calendarId,
    String? calendarName,
    int? calendarReminderMinutes,
    bool clearCalendar = false,
    bool clearCalendarReminder = false,
    int? recurrenceLimit,
  }) {
    return Profile(
      id: id ?? this.id,
      name: name ?? this.name,
      uuid: uuid ?? this.uuid,
      secret: secret ?? this.secret,
      serverUrl: serverUrl ?? this.serverUrl,
      calendarSync: calendarSync ?? this.calendarSync,
      calendarId: clearCalendar ? null : calendarId ?? this.calendarId,
      calendarName: clearCalendar ? null : calendarName ?? this.calendarName,
      calendarReminderMinutes: clearCalendarReminder
          ? null
          : calendarReminderMinutes ?? this.calendarReminderMinutes,
      recurrenceLimit: recurrenceLimit ?? this.recurrenceLimit,
    );
  }
}
