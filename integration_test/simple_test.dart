import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:taskdroid/src/rust/api.dart';
import 'package:taskdroid/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late TaskManager manager;
  late String testDbPath;

  setUpAll(() async {
    await RustLib.init();
  });

  setUp(() async {
    final Directory tempDir = await getTemporaryDirectory();
    testDbPath =
        "${tempDir.path}/test_db_${DateTime.now().millisecondsSinceEpoch}";
    manager = TaskManager();
    await manager.loadProfile(directoryPath: testDbPath);
  });

  tearDown(() async {
    try {
      final dir = Directory(testDbPath);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  });

  // Helper to fetch all tasks regardless of status
  Future<List<TaskView>> fetchAllTasks() async {
    final result = await manager.listTasks(
      filter: TaskFilter(
        tags: [],
        offset: BigInt.zero,
        limit: BigInt.from(10000),
      ),
    );
    return result.tasks;
  }

  // Helper to fetch only pending tasks
  Future<List<TaskView>> fetchPendingTasks() async {
    final result = await manager.listTasks(
      filter: TaskFilter(
        status: TaskStatus.pending,
        tags: [],
        offset: BigInt.zero,
        limit: BigInt.from(10000),
      ),
    );
    return result.tasks;
  }

  group('TaskManager Integration Tests', () {
    testWidgets('Create a simple pending task', (WidgetTester tester) async {
      final params = CreateTaskParams(
        description: "Buy milk",
        status: TaskStatus.pending,
        tags: [],
        udas: [],
      );

      final uuid = await manager.addTask(params: params);
      expect(uuid, isNotEmpty);
      expect(uuid.length, greaterThan(0));
    });

    testWidgets('Create task with all fields and retrieve it', (
      WidgetTester tester,
    ) async {
      final params = CreateTaskParams(
        description: "Complete project documentation",
        status: TaskStatus.pending,
        project: "work",
        priority: "H",
        tags: ["urgent", "important"],
        due: "2024-12-31T23:59:59Z",
        wait: "2024-01-01T00:00:00Z",
        udas: [],
      );

      final uuid = await manager.addTask(params: params);
      expect(uuid, isNotEmpty);

      final task = await manager.getTask(uuidStr: uuid);
      expect(task.uuid, uuid);
      expect(task.description, "Complete project documentation");
      expect(task.status, TaskStatus.pending);
      expect(task.project, "work");
      expect(task.priority, "H");
      expect(task.tags, containsAll(["urgent", "important"]));
      expect(task.due, isNotNull);
      expect(task.wait, isNotNull);
      expect(task.entry, isNotEmpty);
      expect(task.modified, isNotEmpty);
    });

    testWidgets('List pending tasks filters correctly', (
      WidgetTester tester,
    ) async {
      // Create pending task
      final pendingUuid = await manager.addTask(
        params: CreateTaskParams(
          description: "Pending task",
          status: TaskStatus.pending,
          tags: [],
          udas: [],
        ),
      );

      // Create completed task
      await manager.addTask(
        params: CreateTaskParams(
          description: "Completed task",
          status: TaskStatus.completed,
          tags: [],
          udas: [],
        ),
      );

      // Create deleted task
      await manager.addTask(
        params: CreateTaskParams(
          description: "Deleted task",
          status: TaskStatus.deleted,
          tags: [],
          udas: [],
        ),
      );

      final pendingTasks = await fetchPendingTasks();
      expect(pendingTasks.length, 1);
      expect(pendingTasks.first.uuid, pendingUuid);
      expect(pendingTasks.first.description, "Pending task");
      expect(pendingTasks.first.status, TaskStatus.pending);
    });

    testWidgets('Get all tasks returns all statuses', (
      WidgetTester tester,
    ) async {
      await manager.addTask(
        params: CreateTaskParams(
          description: "Task 1",
          status: TaskStatus.pending,
          tags: [],
          udas: [],
        ),
      );
      await manager.addTask(
        params: CreateTaskParams(
          description: "Task 2",
          status: TaskStatus.completed,
          tags: [],
          udas: [],
        ),
      );
      await manager.addTask(
        params: CreateTaskParams(
          description: "Task 3",
          status: TaskStatus.deleted,
          tags: [],
          udas: [],
        ),
      );

      final allTasks = await fetchAllTasks();
      expect(allTasks.length, 3);
    });

    testWidgets('Search term +COMPLETED returns completed tasks', (
      WidgetTester tester,
    ) async {
      await manager.addTask(
        params: CreateTaskParams(
          description: "Open task",
          status: TaskStatus.pending,
          tags: [],
          udas: [],
        ),
      );
      final completedUuid = await manager.addTask(
        params: CreateTaskParams(
          description: "Completed task",
          status: TaskStatus.completed,
          tags: [],
          udas: [],
        ),
      );

      final result = await manager.listTasks(
        filter: TaskFilter(
          searchTerm: "+COMPLETED",
          tags: [],
          offset: BigInt.zero,
          limit: BigInt.from(100),
        ),
      );

      expect(result.tasks.length, 1);
      expect(result.tasks.first.uuid, completedUuid);
      expect(result.tasks.first.status, TaskStatus.completed);
    });

    testWidgets('Update task description', (WidgetTester tester) async {
      final uuid = await manager.addTask(
        params: CreateTaskParams(
          description: "Original description",
          status: TaskStatus.pending,
          tags: [],
          udas: [],
        ),
      );

      await manager.updateTask(
        uuidStr: uuid,
        params: UpdateTaskParams(
          description: "Updated description",
          start: false,
          addTags: [],
          removeTags: [],
          addDepends: [],
          removeDepends: [],
          setUdas: [],
          addAnnotation: null,
          removeAnnotations: [],
        ),
      );

      final task = await manager.getTask(uuidStr: uuid);
      expect(task.description, "Updated description");
    });

    testWidgets('Update task status to completed', (WidgetTester tester) async {
      final uuid = await manager.addTask(
        params: CreateTaskParams(
          description: "Task to complete",
          status: TaskStatus.pending,
          tags: [],
          udas: [],
        ),
      );

      await manager.updateTask(
        uuidStr: uuid,
        params: UpdateTaskParams(
          status: TaskStatus.completed,
          start: false,
          addTags: [],
          removeTags: [],
          addDepends: [],
          removeDepends: [],
          setUdas: [],
          addAnnotation: null,
          removeAnnotations: [],
        ),
      );

      final task = await manager.getTask(uuidStr: uuid);
      expect(task.status, TaskStatus.completed);

      final pendingTasks = await fetchPendingTasks();
      expect(pendingTasks.length, 0);
    });

    testWidgets('Add and remove tags', (WidgetTester tester) async {
      final uuid = await manager.addTask(
        params: CreateTaskParams(
          description: "Task with tags",
          status: TaskStatus.pending,
          tags: ["tag1", "tag2"],
          udas: [],
        ),
      );

      // Add more tags
      await manager.updateTask(
        uuidStr: uuid,
        params: UpdateTaskParams(
          start: false,
          addTags: ["tag3", "tag4"],
          removeTags: [],
          addDepends: [],
          removeDepends: [],
          setUdas: [],
          addAnnotation: null,
          removeAnnotations: [],
        ),
      );

      var task = await manager.getTask(uuidStr: uuid);
      expect(task.tags, containsAll(["tag1", "tag2", "tag3", "tag4"]));

      // Remove some tags
      await manager.updateTask(
        uuidStr: uuid,
        params: UpdateTaskParams(
          start: false,
          addTags: [],
          removeTags: ["tag2", "tag3"],
          addDepends: [],
          removeDepends: [],
          setUdas: [],
          addAnnotation: null,
          removeAnnotations: [],
        ),
      );

      task = await manager.getTask(uuidStr: uuid);
      expect(task.tags, containsAll(["tag1", "tag4"]));
      expect(task.tags, isNot(contains("tag2")));
      expect(task.tags, isNot(contains("tag3")));
    });

    testWidgets('Update project and priority', (WidgetTester tester) async {
      final uuid = await manager.addTask(
        params: CreateTaskParams(
          description: "Task",
          status: TaskStatus.pending,
          project: "old-project",
          priority: "L",
          tags: [],
          udas: [],
        ),
      );

      await manager.updateTask(
        uuidStr: uuid,
        params: UpdateTaskParams(
          project: "new-project",
          priority: "H",
          start: false,
          addTags: [],
          removeTags: [],
          addDepends: [],
          removeDepends: [],
          setUdas: [],
          addAnnotation: null,
          removeAnnotations: [],
        ),
      );

      final task = await manager.getTask(uuidStr: uuid);
      expect(task.project, "new-project");
      expect(task.priority, "H");
    });

    testWidgets('Remove project and priority', (WidgetTester tester) async {
      final uuid = await manager.addTask(
        params: CreateTaskParams(
          description: "Task",
          status: TaskStatus.pending,
          project: "project",
          priority: "H",
          tags: [],
          udas: [],
        ),
      );

      await manager.updateTask(
        uuidStr: uuid,
        params: UpdateTaskParams(
          project: "",
          priority: "",
          start: false,
          addTags: [],
          removeTags: [],
          addDepends: [],
          removeDepends: [],
          setUdas: [],
          addAnnotation: null,
          removeAnnotations: [],
        ),
      );

      final task = await manager.getTask(uuidStr: uuid);
      expect(task.project, isNull);
      expect(task.priority, isNull);
    });

    testWidgets('Update due date', (WidgetTester tester) async {
      final uuid = await manager.addTask(
        params: CreateTaskParams(
          description: "Task",
          status: TaskStatus.pending,
          tags: [],
          udas: [],
        ),
      );

      // Set due date
      await manager.updateTask(
        uuidStr: uuid,
        params: UpdateTaskParams(
          start: false,
          addTags: [],
          removeTags: [],
          addDepends: [],
          removeDepends: [],
          setUdas: [],
          addAnnotation: null,
          removeAnnotations: [],
          due: "2024-12-25T00:00:00Z",
        ),
      );

      var task = await manager.getTask(uuidStr: uuid);
      expect(task.due, isNotNull);
      expect(task.due, contains("2024-12-25"));

      // Remove due date (empty string clears it)
      await manager.updateTask(
        uuidStr: uuid,
        params: UpdateTaskParams(
          start: false,
          addTags: [],
          removeTags: [],
          addDepends: [],
          removeDepends: [],
          setUdas: [],
          addAnnotation: null,
          removeAnnotations: [],
          due: "",
        ),
      );

      task = await manager.getTask(uuidStr: uuid);
      expect(task.due, isNull);
    });

    testWidgets('Update wait date', (WidgetTester tester) async {
      final uuid = await manager.addTask(
        params: CreateTaskParams(
          description: "Task",
          status: TaskStatus.pending,
          tags: [],
          udas: [],
        ),
      );

      // Set wait date
      await manager.updateTask(
        uuidStr: uuid,
        params: UpdateTaskParams(
          start: false,
          addTags: [],
          removeTags: [],
          addDepends: [],
          removeDepends: [],
          setUdas: [],
          addAnnotation: null,
          removeAnnotations: [],
          wait: "2024-01-01T00:00:00Z",
        ),
      );

      var task = await manager.getTask(uuidStr: uuid);
      expect(task.wait, isNotNull);
      expect(task.wait, contains("2024-01-01"));

      // Remove wait date
      await manager.updateTask(
        uuidStr: uuid,
        params: UpdateTaskParams(
          start: false,
          addTags: [],
          removeTags: [],
          addDepends: [],
          removeDepends: [],
          setUdas: [],
          addAnnotation: null,
          removeAnnotations: [],
          wait: "",
        ),
      );

      task = await manager.getTask(uuidStr: uuid);
      expect(task.wait, isNull);
    });

    testWidgets('Delete tasks', (WidgetTester tester) async {
      final uuid = await manager.addTask(
        params: CreateTaskParams(
          description: "Task to delete",
          status: TaskStatus.pending,
          tags: [],
          udas: [],
        ),
      );

      await manager.deleteTasks(uuidStrs: [uuid]);

      final allTasks = await fetchAllTasks();
      expect(allTasks.length, 1);
      expect(allTasks.first.status, TaskStatus.deleted);

      final pendingTasks = await fetchPendingTasks();
      expect(pendingTasks.length, 0);
    });

    testWidgets('Mark tasks done', (WidgetTester tester) async {
      final uuid = await manager.addTask(
        params: CreateTaskParams(
          description: "Task to complete",
          status: TaskStatus.pending,
          tags: [],
          udas: [],
        ),
      );

      await manager.doneTasks(uuidStrs: [uuid]);

      final pendingTasks = await fetchPendingTasks();
      expect(pendingTasks.length, 0);

      final allTasks = await fetchAllTasks();
      final completed = allTasks.firstWhere((t) => t.uuid == uuid);
      expect(completed.status, TaskStatus.completed);
    });

    testWidgets('Multiple operations on same task', (
      WidgetTester tester,
    ) async {
      // Create task
      final uuid = await manager.addTask(
        params: CreateTaskParams(
          description: "Complex task",
          status: TaskStatus.pending,
          project: "project1",
          priority: "M",
          tags: ["tag1"],
          udas: [],
        ),
      );

      // Update multiple times
      await manager.updateTask(
        uuidStr: uuid,
        params: UpdateTaskParams(
          description: "Updated description",
          project: "project2",
          start: false,
          addTags: ["tag2"],
          removeTags: [],
          addDepends: [],
          removeDepends: [],
          setUdas: [],
          addAnnotation: null,
          removeAnnotations: [],
          due: "2024-12-31T00:00:00Z",
        ),
      );

      await manager.updateTask(
        uuidStr: uuid,
        params: UpdateTaskParams(
          priority: "H",
          start: false,
          addTags: ["tag3"],
          removeTags: ["tag1"],
          addDepends: [],
          removeDepends: [],
          setUdas: [],
          addAnnotation: null,
          removeAnnotations: [],
          wait: "2024-01-01T00:00:00Z",
        ),
      );

      final task = await manager.getTask(uuidStr: uuid);
      expect(task.description, "Updated description");
      expect(task.project, "project2");
      expect(task.priority, "H");
      expect(task.tags, containsAll(["tag2", "tag3"]));
      expect(task.tags, isNot(contains("tag1")));
      expect(task.due, isNotNull);
      expect(task.wait, isNotNull);
    });

    testWidgets('Create tasks with different statuses', (
      WidgetTester tester,
    ) async {
      await manager.addTask(
        params: CreateTaskParams(
          description: "Pending",
          status: TaskStatus.pending,
          tags: [],
          udas: [],
        ),
      );
      await manager.addTask(
        params: CreateTaskParams(
          description: "Completed",
          status: TaskStatus.completed,
          tags: [],
          udas: [],
        ),
      );
      await manager.addTask(
        params: CreateTaskParams(
          description: "Deleted",
          status: TaskStatus.deleted,
          tags: [],
          udas: [],
        ),
      );
      await manager.addTask(
        params: CreateTaskParams(
          description: "Recurring",
          status: TaskStatus.recurring,
          tags: [],
          udas: [],
        ),
      );

      final allTasks = await fetchAllTasks();
      expect(allTasks.length, 4);

      final pendingTasks = await fetchPendingTasks();
      expect(pendingTasks.length, 1);
      expect(pendingTasks.first.description, "Pending");
    });

    testWidgets('Date parsing with different formats', (
      WidgetTester tester,
    ) async {
      // Test ISO 8601 format
      final uuid1 = await manager.addTask(
        params: CreateTaskParams(
          description: "Task 1",
          status: TaskStatus.pending,
          due: "2024-12-31T23:59:59Z",
          tags: [],
          udas: [],
        ),
      );

      // Test date-only format
      final uuid2 = await manager.addTask(
        params: CreateTaskParams(
          description: "Task 2",
          status: TaskStatus.pending,
          due: "2024-12-31",
          tags: [],
          udas: [],
        ),
      );

      final tasks = await fetchAllTasks();
      expect(tasks.length, 2);
      expect(tasks.firstWhere((t) => t.uuid == uuid1).due, isNotNull);
      expect(tasks.firstWhere((t) => t.uuid == uuid2).due, isNotNull);
    });

    testWidgets('Add and remove annotations', (WidgetTester tester) async {
      final uuid = await manager.addTask(
        params: CreateTaskParams(
          description: "Task with notes",
          status: TaskStatus.pending,
          tags: [],
          udas: [],
        ),
      );

      // Add annotation
      await manager.updateTask(
        uuidStr: uuid,
        params: UpdateTaskParams(
          addAnnotation: "First note",
          start: false,
          addTags: [],
          removeTags: [],
          addDepends: [],
          removeDepends: [],
          setUdas: [],
          removeAnnotations: [],
        ),
      );

      var task = await manager.getTask(uuidStr: uuid);
      expect(task.annotations.length, 1);
      expect(task.annotations.first.description, "First note");

      // Remove annotation by its entry date
      final entryDate = task.annotations.first.entry;
      await manager.updateTask(
        uuidStr: uuid,
        params: UpdateTaskParams(
          start: false,
          addTags: [],
          removeTags: [],
          addDepends: [],
          removeDepends: [],
          setUdas: [],
          addAnnotation: null,
          removeAnnotations: [entryDate],
        ),
      );

      task = await manager.getTask(uuidStr: uuid);
      expect(task.annotations.length, 0);
    });

    testWidgets('Export and import tasks', (WidgetTester tester) async {
      await manager.addTask(
        params: CreateTaskParams(
          description: "Export test",
          status: TaskStatus.pending,
          project: "testing",
          tags: ["export"],
          udas: [],
        ),
      );

      final exported = await manager.exportTasks(includeDeleted: false);
      expect(exported, contains("Export test"));
      expect(exported, contains("testing"));

      // Import into fresh database
      final importDbPath =
          "${testDbPath}_import_${DateTime.now().millisecondsSinceEpoch}";
      final importManager = TaskManager();
      await importManager.loadProfile(directoryPath: importDbPath);

      final count = await importManager.importTasks(jsonData: exported);
      expect(count, 1);

      final imported = await importManager.listTasks(
        filter: TaskFilter(
          status: TaskStatus.pending,
          tags: [],
          offset: BigInt.zero,
          limit: BigInt.from(100),
        ),
      );
      expect(imported.tasks.length, 1);
      expect(imported.tasks.first.description, "Export test");

      // Cleanup
      try {
        await Directory(importDbPath).delete(recursive: true);
      } catch (_) {}
    });
  });
}
