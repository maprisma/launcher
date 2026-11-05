/// Bounded spelling/spacing alternatives shared by package and GitHub searches.
library;

String _letters(String text) => text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

int _distance(String a, String b) {
  var row = List.generate(b.length + 1, (i) => i);
  for (var i = 0; i < a.length; i++) {
    final next = [i + 1];
    for (var j = 0; j < b.length; j++) {
      final values = [next[j] + 1, row[j + 1] + 1, row[j] + (a[i] == b[j] ? 0 : 1)];
      next.add(values.reduce((a, b) => a < b ? a : b));
    }
    row = next;
  }
  return row.last;
}

/// Suggestions may correct a nearby name, but cannot turn "craft" into an
/// unrelated app such as "Minecraft". Only search terms are generated here.
List<String> searchTerms(String query, {Iterable<String> suggestions = const []}) {
  final clean = query.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (!RegExp(r'^[\w .+/-]{1,120}$').hasMatch(clean)) return [];
  final base = _letters(clean);
  final corrected = <String>[];
  for (final suggestion in suggestions.take(5)) {
    final term = suggestion.trim();
    if (!RegExp(r'^[\w .+-]{1,80}$').hasMatch(term)) continue;
    final name = _letters(term);
    final limit = base.length < 5
        ? 1
        : base.length < 10
        ? 2
        : 3;
    if (name.isNotEmpty && _distance(base, name) <= limit) corrected.add(term);
  }
  return <String>{
    clean,
    ...corrected,
    clean.replaceAll(RegExp(r'[ _-]+'), '-'),
    clean.replaceAll(RegExp(r'[ _-]+'), ''),
  }.take(4).toList();
}

/// Prefer whole app-name matches, including a checked correction, over broad
/// description matches. Keep source relevance order when scores are equal.
int searchRank(String name, List<String> terms) {
  final key = _letters(name);
  if (terms.any((t) => _letters(t) == key)) return 0;
  if (terms.any((t) => key.startsWith(_letters(t)))) return 1;
  if (terms.any((t) => key.contains(_letters(t)))) return 2;
  return 3;
}
