import 'package:flutter/services.dart';
import 'package:taskdroid/src/rust/api.dart';

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

  Future<void> syncTask(TaskView task) async {
    if (task.status == TaskStatus.deleted ||
        task.status == TaskStatus.completed) {
      await deleteTask(task.uuid);
      return;
    }

    if (task.due == null) {
      await deleteTask(task.uuid);
      return;
    }

    await _channel.invokeMethod('saveTask', _mapTaskToEvent(task));
  }

  Future<void> deleteTask(String uuid) async {
    await _channel.invokeMethod('deleteTask', {'uuid': uuid});
  }

  Future<int> deleteAllEvents() async {
    final int count = await _channel.invokeMethod('deleteAllEvents');
    return count;
  }

  Future<String> batchSync(List<TaskView> tasks) async {
    final calendarTasks = tasks
        .where((t) => t.status == TaskStatus.pending && t.due != null)
        .map((t) => _mapTaskToEvent(t))
        .toList();

    final String result = await _channel.invokeMethod('batchSync', {
      'tasks': calendarTasks,
    });
    return result;
  }

  Map<String, dynamic> _mapTaskToEvent(TaskView task) {
    final dueDate = DateTime.parse(task.due!);
    final startMs = dueDate.millisecondsSinceEpoch;

    int durationMinutes = 60;
    final durationUda = task.udas.firstWhere(
      (u) => u.key == 'duration',
      orElse: () => const UdaPair(key: 'duration', value: ''),
    );
    if (durationUda.value.isNotEmpty) {
      final parsed = int.tryParse(durationUda.value);
      if (parsed != null && parsed > 0) {
        durationMinutes = parsed;
      }
    }

    final endMs = startMs + (durationMinutes * 60 * 1000);

    final buffer = StringBuffer();
    if (task.project != null) buffer.writeln("Project: ${task.project}");
    if (task.tags.isNotEmpty) buffer.writeln("Tags: ${task.tags.join(', ')}");
    buffer.writeln("Urgency: ${task.urgency.toStringAsFixed(2)}");

    return {
      'uuid': task.uuid,
      'title': task.description,
      'description': buffer.toString().trim(),
      'start': startMs,
      'end': endMs,
    };
  }
}
