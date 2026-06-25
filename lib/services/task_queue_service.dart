import 'package:taskdroid/src/rust/api.dart';

enum TaskQueueView { ready, waiting, scheduled }

class TaskQueueService {
  TaskQueueView _queueView = TaskQueueView.ready;

  TaskQueueView get queueView => _queueView;

  void setQueueView(TaskQueueView view) {
    _queueView = view;
  }

  List<TaskView> sourceTasksForView(
    List<TaskView> readyTasks,
    List<TaskView> waitingTasks,
    List<TaskView> scheduledTasks,
  ) {
    switch (_queueView) {
      case TaskQueueView.ready:
        return readyTasks;
      case TaskQueueView.waiting:
        return waitingTasks;
      case TaskQueueView.scheduled:
        return scheduledTasks;
    }
  }
}
