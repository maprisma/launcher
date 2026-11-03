/// Newly installed apps, marked with a star (reference newapps.py).
/// seen.json remembers when each entry (desktop id) was first seen. The
/// first look records everything already there as old, so only later
/// installs count as new. An entry stays new for [newDays], or until it is
/// opened from App Manager.
library;

const newDays = 7;
const maxSeenEntries = 5000;
const seenKinds = ['apps', 'plugins'];

typedef SeenData = Map<String, dynamic>;

SeenData emptySeen() => {'baseline': <String>[], 'seen': <String, int>{}};

/// newapps.load's cleaning, for data read from seen.json.
SeenData cleanSeen(Object? data) {
  if (data is! Map) return emptySeen();
  final rawBaseline = data['baseline'];
  final baseline = rawBaseline is List
      ? {for (final k in rawBaseline) if (seenKinds.contains(k)) k as String}.toList()
      : <String>[];
  final rawSeen = data['seen'] is Map ? data['seen'] as Map : const {};
  final seen = <String, int>{};
  for (final e in rawSeen.entries.take(maxSeenEntries)) {
    final key = e.key, value = e.value;
    if (key is String && key.isNotEmpty && key.length <= 300 && value is num && value >= 0) {
      seen[key] = value.toInt();
    }
  }
  return {'baseline': baseline, 'seen': seen};
}

/// Record entries seen on page [kind]; true when something changed.
/// [installed]: {id: when it was installed (seconds)}, where known.
bool noteSeen(SeenData data, Iterable<String> ids, String kind, {int? now, Map<String, num> installed = const {}}) {
  final at = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final seen = data['seen'] as Map<String, int>;
  final baseline = data['baseline'] as List<String>;
  final firstLook = !baseline.contains(kind);
  var changed = firstLook;
  for (final key in ids) {
    if (key.isEmpty || seen.containsKey(key)) continue;
    final when = installed[key];
    seen[key] = firstLook ? 0 : (when != null && when > 0 && when < at ? when.toInt() : at);
    if (at - seen[key]! >= newDays * 86400) seen[key] = 0;
    changed = true;
  }
  if (firstLook) baseline.add(kind);
  if (seen.length > maxSeenEntries) {
    final oldest = seen.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
    for (final e in oldest.take(seen.length - maxSeenEntries)) {
      seen.remove(e.key);
    }
  }
  return changed;
}

bool isNewApp(SeenData data, String key, {int? now}) {
  final first = (data['seen'] as Map<String, int>)[key] ?? 0;
  final at = now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return first > 0 && at - first < newDays * 86400;
}

/// Opened from App Manager: not new any more. True when it was.
bool openedApp(SeenData data, String key) {
  final seen = data['seen'] as Map<String, int>;
  if ((seen[key] ?? 0) != 0) {
    seen[key] = 0;
    return true;
  }
  return false;
}
