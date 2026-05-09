import 'package:taskdroid/src/rust/api.dart';

const int taskwarriorDefaultDueDays = 7;

extension TaskVirtualFlags on TaskView {
  bool get hasProject => project != null && project!.trim().isNotEmpty;

  DateTime? _parseUtc(String? value) {
    if (value == null || value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  DateTime? get dueDateUtc {
    return _parseUtc(due);
  }

  DateTime? get waitDateUtc {
    return _parseUtc(wait);
  }

  DateTime? get scheduledDateUtc {
    return _parseUtc(scheduled);
  }

  bool isDue(DateTime nowUtc) {
    final dueDate = dueDateUtc;
    if (dueDate == null) return false;
    return !dueDate.isAfter(
      nowUtc.add(const Duration(days: taskwarriorDefaultDueDays)),
    );
  }

  bool isDueToday(DateTime nowUtc) {
    final dueDate = dueDateUtc;
    if (dueDate == null) return false;
    final localDue = dueDate.toLocal();
    final localNow = nowUtc.toLocal();
    return localDue.year == localNow.year &&
        localDue.month == localNow.month &&
        localDue.day == localNow.day;
  }

  bool isOverdue(DateTime nowUtc) {
    final dueDate = dueDateUtc;
    if (dueDate == null) return false;
    return dueDate.isBefore(nowUtc);
  }

  bool isWaitingAt(DateTime nowUtc) {
    final waitDate = waitDateUtc;
    if (waitDate != null && waitDate.isAfter(nowUtc)) {
      return true;
    }
    return isWaiting;
  }

  bool isScheduledForFuture(DateTime nowUtc) {
    final scheduledDate = scheduledDateUtc;
    if (scheduledDate == null) return false;
    return scheduledDate.isAfter(nowUtc);
  }

  bool isReadyAt(DateTime nowUtc) {
    return status == TaskStatus.pending &&
        !isBlocked &&
        !isWaitingAt(nowUtc) &&
        !isScheduledForFuture(nowUtc);
  }

  bool isSomeday(DateTime nowUtc) {
    final waitDate = waitDateUtc;
    if (waitDate == null) return false;
    return waitDate.isAfter(nowUtc.add(const Duration(days: 30)));
  }

  bool get isTemplate => isRecurringTemplate;
}
