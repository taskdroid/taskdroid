import 'dart:async';
import 'dart:isolate';
import 'package:taskdroid/src/rust/api.dart';
import 'package:taskdroid/src/rust/frb_generated.dart';

class SyncIsolateService {
  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _receivePort;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _nextId = 0;
  Future<void>? _ensureIsolateFuture;

  Future<void> _ensureIsolate() async {
    if (_isolate != null) return;
    if (_ensureIsolateFuture != null) return _ensureIsolateFuture!;

    _ensureIsolateFuture = _startIsolate();
    try {
      await _ensureIsolateFuture!;
    } finally {
      _ensureIsolateFuture = null;
    }
  }

  Future<void> _startIsolate() async {
    final initCompleter = Completer<void>();
    _receivePort = ReceivePort();

    int messagesReceived = 0;
    _receivePort!.listen(
      (data) {
        if (messagesReceived == 0) {
          _sendPort = data as SendPort;
          messagesReceived = 1;
        } else if (messagesReceived == 1) {
          assert((data as Map<String, dynamic>)['type'] == 'ready');
          messagesReceived = 2;
          initCompleter.complete();
        } else {
          _handleResponse(data);
        }
      },
      onError: (Object error) {
        _failPending('Isolate error: $error');
        _cleanup();
      },
      onDone: () {
        _failPending('Isolate terminated unexpectedly');
        _cleanup();
      },
      cancelOnError: false,
    );

    _isolate = await Isolate.spawn(_syncIsolateEntry, _receivePort!.sendPort);
    await initCompleter.future;
  }

  void _handleResponse(dynamic data) {
    final response = data as Map<String, dynamic>;
    final id = response['id'] as int;
    final completer = _pending.remove(id);
    if (completer != null) {
      completer.complete(response);
    }
  }

  void _failPending(String reason) {
    for (final entry in _pending.entries) {
      entry.value.complete({'success': false, 'error': reason});
    }
    _pending.clear();
  }

  void _cleanup() {
    _isolate = null;
    _sendPort = null;
    _receivePort?.close();
    _receivePort = null;
  }

  Future<String?> sync(
    String directoryPath,
    String url,
    String clientId,
    String encryptionSecret,
    int recurrenceLimit,
  ) async {
    await _ensureIsolate();

    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    _sendPort!.send({
      'type': 'sync',
      'id': id,
      'directoryPath': directoryPath,
      'url': url,
      'clientId': clientId,
      'encryptionSecret': encryptionSecret,
      'recurrenceLimit': recurrenceLimit,
    });

    final response = await completer.future;
    if (!(response['success'] as bool)) return response['error'] as String?;
    return null;
  }

  void dispose() {
    if (_sendPort != null) {
      _sendPort!.send({'type': 'dispose'});
    }
    _isolate?.kill();
    _cleanup();
    _ensureIsolateFuture = null;
  }
}

Future<void> _syncIsolateEntry(SendPort mainSendPort) async {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  await RustLib.init();
  mainSendPort.send({'type': 'ready'});

  TaskManager? manager;
  String? loadedDirectory;

  await for (final message in receivePort) {
    final map = message as Map<String, dynamic>;
    final type = map['type'] as String;

    if (type == 'sync') {
      try {
        final dir = map['directoryPath'] as String;
        if (manager == null || loadedDirectory != dir) {
          manager = TaskManager();
          await manager.loadProfile(directoryPath: dir);
          loadedDirectory = dir;
        }

        await manager.setRecurrenceLimit(
          limit: BigInt.from(map['recurrenceLimit'] as int),
        );
        await manager.sync_(
          url: map['url'] as String,
          clientId: map['clientId'] as String,
          encryptionSecret: map['encryptionSecret'] as String,
        );
        mainSendPort.send(<String, dynamic>{
          'type': 'response',
          'id': map['id'],
          'success': true,
        });
      } catch (e) {
        mainSendPort.send(<String, dynamic>{
          'type': 'response',
          'id': map['id'],
          'success': false,
          'error': e.toString(),
        });
      }
    } else if (type == 'dispose') {
      break;
    }
  }
}
