import 'package:flutter/services.dart';
import 'package:taskdroid/src/rust/api.dart';

class CalendarInfo {
  final int id;
  final String name;
  final String accountName;
  final String accountType;
  final bool isPrimary;
  final int? color;

  const CalendarInfo({
    required this.id,
    required this.name,
    required this.accountName,
    required this.accountType,
    required this.isPrimary,
    required this.color,
  });

  factory CalendarInfo.fromMap(Map<dynamic, dynamic> map) {
    return CalendarInfo(
      id: (map['id'] as num).toInt(),
      name: map['name'] as String? ?? 'Calendar',
      accountName: map['accountName'] as String? ?? '',
      accountType: map['accountType'] as String? ?? '',
      isPrimary: map['isPrimary'] as bool? ?? false,
      color: (map['color'] as num?)?.toInt(),
    );
  }
}

class CalendarService {
  static const _channel = MethodChannel('org.taskdroid/calendar');

  Future<bool> checkPermissions() async {
    final bool result = await _channel.invokeMethod('checkPermissions');
    return result;
  }

  Future<bool> requestPermissions() async {
    final bool result = await _channel.invokeMethod('requestPermissions');
    return result;
  }

  Future<List<CalendarInfo>> listCalendars() async {
    final result = await _channel.invokeMethod<List<dynamic>>('listCalendars');
    return (result ?? [])
        .map((item) => CalendarInfo.fromMap(item as Map<dynamic, dynamic>))
        .toList();
  }

  Future<void> syncTask(
    TaskView task, {
    int? calendarId,
    int? reminderMinutes,
  }) async {
    if (task.status == TaskStatus.deleted ||
        task.status == TaskStatus.completed) {
      await deleteTask(task.uuid);
      return;
    }

    final event = _mapTaskToEvent(
      task,
      calendarId: calendarId,
      reminderMinutes: reminderMinutes,
    );
    if (event == null) {
      await deleteTask(task.uuid);
      return;
    }

    await _channel.invokeMethod('saveTask', event);
  }

  Future<void> deleteTask(String uuid) async {
    await _channel.invokeMethod('deleteTask', {'uuid': uuid});
  }

  Future<int> deleteAllEvents() async {
    final int count = await _channel.invokeMethod('deleteAllEvents');
    return count;
  }

  Future<String> batchSync(
    List<TaskView> tasks, {
    int? calendarId,
    int? reminderMinutes,
  }) async {
    final calendarTasks = tasks
        .where((t) => t.status == TaskStatus.pending)
        .map(
          (t) => _mapTaskToEvent(
            t,
            calendarId: calendarId,
            reminderMinutes: reminderMinutes,
          ),
        )
        .nonNulls
        .toList();

    final String result = await _channel.invokeMethod('batchSync', {
      'tasks': calendarTasks,
      'calendarId': calendarId,
      'reminderMinutes': reminderMinutes,
    });
    return result;
  }

  Map<String, dynamic>? _mapTaskToEvent(
    TaskView task, {
    int? calendarId,
    int? reminderMinutes,
  }) {
    final dueDate = _parseTaskDate(task.due);
    final scheduledDate = _parseTaskDate(task.scheduled);
    final waitDate = _parseTaskDate(task.wait);
    final durationUda = task.udas.firstWhere(
      (u) => u.key == 'duration',
      orElse: () => const UdaPair(key: 'duration', value: ''),
    );
    final durationMinutes = _parseDurationMinutes(durationUda.value);

    final eventWindow = _resolveEventWindow(
      due: dueDate,
      scheduled: scheduledDate,
      wait: waitDate,
      durationMinutes: durationMinutes,
    );
    if (eventWindow == null) return null;

    final buffer = StringBuffer();
    if (task.project != null) buffer.writeln("Project: ${task.project}");
    if (task.tags.isNotEmpty) buffer.writeln("Tags: ${task.tags.join(', ')}");
    if (scheduledDate != null) buffer.writeln("Scheduled: $scheduledDate");
    if (waitDate != null) buffer.writeln("Wait: $waitDate");
    if (dueDate != null) buffer.writeln("Due: $dueDate");
    buffer.writeln("Duration: $durationMinutes minutes");
    buffer.writeln("Urgency: ${task.urgency.toStringAsFixed(2)}");

    return {
      'uuid': task.uuid,
      'title': task.description,
      'description': buffer.toString().trim(),
      'start': eventWindow.start.millisecondsSinceEpoch,
      'end': eventWindow.end.millisecondsSinceEpoch,
      'calendarId': calendarId,
      'reminderMinutes': reminderMinutes,
    };
  }

  DateTime? _parseTaskDate(String? value) {
    if (value == null) return null;
    return DateTime.tryParse(value)?.toLocal();
  }

  int _parseDurationMinutes(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed <= 0) return 60;
    return parsed.clamp(1, 24 * 60);
  }

  ({DateTime start, DateTime end})? _resolveEventWindow({
    required DateTime? due,
    required DateTime? scheduled,
    required DateTime? wait,
    required int durationMinutes,
  }) {
    final duration = Duration(minutes: durationMinutes);
    final explicitStart = scheduled ?? wait;

    if (explicitStart != null) {
      final durationEnd = explicitStart.add(duration);
      final end = due != null && due.isAfter(explicitStart)
          ? (due.isBefore(durationEnd) ? due : durationEnd)
          : durationEnd;
      return (start: explicitStart, end: end);
    }

    if (due != null) {
      final end = due.add(duration);
      return (start: due, end: end);
    }

    return null;
  }
}
