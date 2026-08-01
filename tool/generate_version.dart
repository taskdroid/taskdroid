import 'dart:io';

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final versionMatch = RegExp(
    r'^version:\s*(.+)$',
    multiLine: true,
  ).firstMatch(pubspec);
  if (versionMatch == null) {
    stderr.writeln('Could not find version in pubspec.yaml');
    exit(1);
  }
  final version = versionMatch.group(1)!.trim();
  final output =
      '''
// Generated file - do not edit manually
class AppVersion {
  static const String version = '$version';
}
''';
  File('lib/version.dart').writeAsStringSync(output);
  stdout.writeln('Generated lib/version.dart with version $version');
}
