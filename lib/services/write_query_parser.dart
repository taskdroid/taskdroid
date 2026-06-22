class WriteQueryDefaults {
  final Set<String> tags;
  final String? project;
  final String? priority;

  WriteQueryDefaults({required this.tags, this.project, this.priority});
}

WriteQueryDefaults parseWriteQuery(String query) {
  final tags = <String>{};
  String? project;
  String? priority;

  final tokens = _tokenizeQuery(query.trim());
  for (final token in tokens) {
    if (token.startsWith('+') && token.length > 1) {
      tags.add(_unquote(token.substring(1)));
    } else if (token.startsWith('project:') && token.length > 8) {
      project = _unquote(token.substring(8));
    } else if (token.startsWith('priority:') && token.length > 9) {
      priority = _unquote(token.substring(9));
    }
  }

  return WriteQueryDefaults(tags: tags, project: project, priority: priority);
}

  List<String> _tokenizeQuery(String query) {
    final tokens = <String>[];
    int i = 0;
    while (i < query.length) {
      if (query[i] == ' ') {
        i++;
        continue;
      }
      int end = i;
      bool inQuote = false;
      while (end < query.length) {
        if (query[end] == '\\' && end + 1 < query.length) {
          end += 2;
          continue;
        }
        if (query[end] == '"' || query[end] == '\'') {
          inQuote = !inQuote;
        } else if (query[end] == ' ' && !inQuote) {
          break;
        }
        end++;
      }
      tokens.add(query.substring(i, end));
      i = end;
    }
    return tokens;
  }

String _unquote(String s) {
  if (s.length >= 2) {
    if (s.startsWith('"') && s.endsWith('"')) {
      return s.substring(1, s.length - 1);
    }
    if (s.startsWith("'") && s.endsWith("'")) {
      return s.substring(1, s.length - 1);
    }
  }
  if (s.startsWith('"') || s.startsWith("'")) {
    return s.substring(1);
  }
  return s;
}
