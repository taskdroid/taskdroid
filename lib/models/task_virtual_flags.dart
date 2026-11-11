import 'package:taskdroid/src/rust/api.dart';

const int taskwarriorDefaultDueDays = 7;

/// Tags Taskwarrior reports but does not store as user tags.
///
/// Keep this in sync with `is_virtual_tag_name` in
/// `rust/src/core/utils.rs`, which is the single source of truth; the Rust
/// function also lists `INSTANCE`.
const Set<String> taskwarriorVirtualTags = {
  'BLOCKED',
  'UNBLOCKED',
  'BLOCKING',
  'DUE',
  'DUETODAY',
  'TODAY',
  'OVERDUE',
  'WEEK',
  'MONTH',
  'QUARTER',
  'YEAR',
  'ACTIVE',
  'SCHEDULED',
  'PARENT',
  'CHILD',
  'UNTIL',
  'WAITING',
  'ANNOTATED',
  'READY',
  'YESTERDAY',
  'TOMORROW',
  'TAGGED',
  'PENDING',
  'COMPLETED',
  'DELETED',
  'UDA',
  'ORPHAN',
  'PRIORITY',
  'PROJECT',
  'LATEST',
  'INSTANCE',
};

/// The virtual tags the "Show task state tags" setting may reveal.
const Set<String> taskStateTags = {'READY', 'WAITING', 'SCHEDULED', 'ACTIVE'};

bool isVirtualTagName(String tag) => taskwarriorVirtualTags.contains(tag);

/// Strips virtual tags, leaving the tags the user actually assigned.
List<String> userTags(Iterable<String> tags) =>
    tags.where((tag) => !isVirtualTagName(tag)).toList();

/// Tags to show in the task list: user tags always, plus the four state tags
/// when [showStateTags] is on. Every other virtual tag stays hidden.
List<String> visibleTaskTags(
  Iterable<String> tags, {
  required bool showStateTags,
}) {
  return tags
      .where(
        (tag) =>
            !isVirtualTagName(tag) ||
            (showStateTags && taskStateTags.contains(tag)),
      )
      .toList();
}

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
