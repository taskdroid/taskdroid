import 'dart:convert';

import 'package:file_selector/file_selector.dart' show openFile, XTypeGroup;
import 'package:flutter/services.dart';

const XTypeGroup _jsonTypeGroup = XTypeGroup(
  label: 'JSON',
  extensions: ['json'],
  mimeTypes: ['application/json'],
);

const MethodChannel _fileIoChannel = MethodChannel('org.taskdroid/fileio');

/// pick json file and return its contents
Future<String?> pickBackupFile() async {
  final file = await openFile(acceptedTypeGroups: const [_jsonTypeGroup]);
  if (file == null) return null;
  return file.readAsString();
}

/// save [json] to a user-chosen location
Future<bool?> saveBackupFile(
  String json, {
  String suggestedName = 'taskdroid-backup.json',
}) async {
  final bytes = utf8.encode(json);
  try {
    return await _fileIoChannel.invokeMethod<bool>('saveFile', {
      'suggestedName': suggestedName,
      'data': bytes,
    });
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}
