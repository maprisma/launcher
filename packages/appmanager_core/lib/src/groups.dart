/// Groups: reference/gnome-launcher/groups.py. Every entry is in exactly
/// one group; a move by hand is remembered by desktop id. Built-in groups
/// keep an empty name until renamed (the UI shows their translated name).
library;

const other = 'other';
const running = '_running';
const maxGroups = 50, maxMembers = 5000, maxName = 40;

const builtinNames = {
  'office': 'Office',
  'internet': 'Internet',
  'media': 'Media',
  'graphics': 'Graphics',
  'development': 'Development',
  'games': 'Games',
  'system': 'System',
  'utilities': 'Utilities',
};
const builtinOrder = [
  'office', 'internet', 'media', 'graphics', 'development', 'games', 'system', 'utilities',
];
const categoryGroups = [
  ('games', {'Game'}),
  ('development', {'Development', 'IDE'}),
  ('office', {'Office'}),
  ('media', {'AudioVideo', 'Audio', 'Video', 'Player', 'Music'}),
  ('graphics', {'Graphics', 'Photography'}),
  ('internet', {'Network', 'WebBrowser', 'Email', 'Chat', 'InstantMessaging'}),
  ('system', {
    'System', 'Settings', 'Monitor', 'PackageManager', 'TerminalEmulator',
    'FileManager', 'HardwareSettings',
  }),
  ('utilities', {'Utility', 'Accessibility', 'Education', 'Science'}),
];

final _idRe = RegExp(r'^[a-z0-9_-]{1,40}$');
final _controlRe = RegExp(
  r'[\x00-\x1f\x7f-\x9f\u2028\u2029\u202a-\u202e\u2066-\u2069]',
  unicode: true,
);

/// The refusal a user sees (English; the UI translates it).
final class GroupError implements Exception {
  const GroupError(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef GroupData = Map<String, dynamic>;

GroupData defaultPage() => {
  'groups': [for (final id in builtinOrder) {'id': id, 'name': ''}],
  'members': <String, String>{},
  'collapsed': <String>[],
  'order': <String>[],
};

String cleanName(Object? text) {
  final spaced = '${text ?? ''}'.replaceAll(_controlRe, ' ');
  final single = spaced.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  final cut = single.length > maxName ? single.substring(0, maxName) : single;
  return cut.trim();
}

/// _clean_page: the saved page, anything malformed dropped entry by entry.
GroupData cleanPage(Object? data, Iterable<String> origins) {
  if (data is! Map || data['groups'] is! List) return defaultPage();
  final groups = <Map<String, dynamic>>[];
  final seen = {other, running};
  for (final group in (data['groups'] as List).take(maxGroups)) {
    if (group is! Map) continue;
    final id = group['id'];
    final rawName = group.containsKey('name') ? group['name'] : '';
    if (id is! String || !_idRe.hasMatch(id) || seen.contains(id)) continue;
    seen.add(id);
    final name = rawName is String ? cleanName(rawName) : '';
    if (name.isEmpty && !builtinNames.containsKey(id)) continue;
    groups.add({'id': id, 'name': name, if (group['new'] == true) 'new': true});
  }
  final members = <String, String>{};
  final rawMembers = data['members'];
  if (rawMembers is Map) {
    for (final e in rawMembers.entries.take(maxMembers)) {
      final key = e.key, gid = e.value;
      if (key is String && key.isNotEmpty && key.length <= 300 && gid is String && seen.contains(gid)) {
        members[key] = gid;
      }
    }
  }
  final foldable = {...seen, ...origins};
  final rawCollapsed = data['collapsed'];
  final collapsed = rawCollapsed is List
      ? rawCollapsed.whereType<String>().where(foldable.contains).take(maxGroups + 5).toList()
      : <String>[];
  final rawOrder = data['order'];
  final order = rawOrder is List
      ? {
          for (final k in rawOrder)
            if (k is String && k.isNotEmpty && k.length <= 300) k,
        }.take(maxMembers).toList()
      : <String>[];
  return {'groups': groups, 'members': members, 'collapsed': collapsed, 'order': order};
}

List<String> groupIds(GroupData data) => [
  for (final g in data['groups'] as List) g['id'] as String,
];

/// display_name in English: own name, else the built-in one.
String displayName(String gid, GroupData data) {
  if (gid == other) return 'Other';
  if (gid == running) return 'Running';
  final group = (data['groups'] as List).cast<Map>().where((g) => g['id'] == gid).firstOrNull;
  if (group == null) return 'Other';
  final name = group['name'];
  return name is String && name.isNotEmpty ? name : builtinNames[gid] ?? gid;
}

String suggestedGroup(Map app) {
  final categories = {...(app['categories'] as List? ?? const []).whereType<String>()};
  for (final (gid, names) in categoryGroups) {
    if (categories.any(names.contains)) return gid;
  }
  return app['pwa'] == true ? 'internet' : other;
}

String groupOf(Map app, GroupData data) {
  final ids = groupIds(data).toSet();
  final chosen = (data['members'] as Map)[app['desktop_id']];
  if (chosen is String && ids.contains(chosen)) return chosen;
  final suggested = suggestedGroup(app);
  return ids.contains(suggested) ? suggested : other;
}

void assign(GroupData data, String desktopId, String gid) {
  if (gid != other && !groupIds(data).contains(gid)) throw GroupError(gid);
  final members = data['members'] as Map;
  if (members.length >= maxMembers && !members.containsKey(desktopId)) {
    throw const GroupError('Too many entries.');
  }
  members[desktopId] = gid;
  for (final group in data['groups'] as List) {
    if (group['id'] == gid) (group as Map).remove('new');
  }
}

bool nameTaken(
  GroupData data,
  String name,
  String? exceptId, {
  String Function(String)? tr,
}) {
  final t = tr ?? (String s) => s;
  final folded = name.toLowerCase();
  String shown(Map g) {
    final n = g['name'] as String;
    return n.isNotEmpty ? n : t(builtinNames[g['id']] ?? g['id'] as String);
  }

  return (data['groups'] as List).cast<Map>().any(
        (g) => g['id'] != exceptId && shown(g).toLowerCase() == folded,
      ) ||
      [t('Other'), t('Running'), t('Running in the bar')].any((s) => s.toLowerCase() == folded);
}

String addGroup(GroupData data, String name, {String Function(String)? tr}) {
  name = cleanName(name);
  if (name.isEmpty) throw const GroupError('Enter a name.');
  if (nameTaken(data, name, null, tr: tr)) {
    throw const GroupError('A group with this name exists already.');
  }
  final groups = data['groups'] as List;
  if (groups.length >= maxGroups) throw const GroupError('That is the most groups there can be.');
  final ids = groupIds(data).toSet();
  var number = 1;
  while (ids.contains('g$number')) {
    number++;
  }
  groups.add({'id': 'g$number', 'name': name, 'new': true});
  return 'g$number';
}

void renameGroup(GroupData data, String gid, String name, {String Function(String)? tr}) {
  name = cleanName(name);
  if (name.isEmpty) throw const GroupError('Enter a name.');
  if (nameTaken(data, name, gid, tr: tr)) {
    throw const GroupError('A group with this name exists already.');
  }
  for (final group in data['groups'] as List) {
    if (group['id'] == gid) {
      group['name'] = name;
      return;
    }
  }
  throw const GroupError('Unknown group');
}

void deleteGroup(GroupData data, String gid) {
  data['groups'] = [for (final g in data['groups'] as List) if (g['id'] != gid) g];
  data['members'] = {
    for (final e in (data['members'] as Map).entries) if (e.value != gid) e.key: e.value,
  };
  data['collapsed'] = [for (final g in data['collapsed'] as List) if (g != gid) g];
}

bool moveGroup(GroupData data, String gid, int delta) {
  final groups = data['groups'] as List;
  final index = groupIds(data).indexOf(gid);
  if (index < 0 || index + delta < 0 || index + delta >= groups.length) return false;
  final g = groups[index];
  groups[index] = groups[index + delta];
  groups[index + delta] = g;
  return true;
}

bool reorderGroup(GroupData data, String gid, String target, {bool after = false}) {
  final groups = data['groups'] as List;
  final ids = groupIds(data);
  if (gid == target || !ids.contains(gid) || !ids.contains(target)) return false;
  final group = groups.removeAt(ids.indexOf(gid));
  final index = groupIds(data).indexOf(target) + (after ? 1 : 0);
  groups.insert(index, group);
  final now = groupIds(data);
  return now.join('\x00') != ids.join('\x00');
}

void toggleCollapsed(GroupData data, String gid) {
  final collapsed = data['collapsed'] as List;
  if (!collapsed.remove(gid)) collapsed.add(gid);
}

/// Entries placed by hand first, in their order; the others after them.
List<Map> inHandOrder(List<Map> members, GroupData data) {
  final order = data['order'] as List? ?? const [];
  final position = {for (var i = 0; i < order.length; i++) order[i]: i};
  final last = position.length;
  final indexed = [for (var i = 0; i < members.length; i++) (i, members[i])];
  indexed.sort((a, b) {
    final r = (position[a.$2['desktop_id']] ?? last).compareTo(position[b.$2['desktop_id']] ?? last);
    return r != 0 ? r : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// [(group id, entries)] in display order: Running (when given), the
/// groups, then Other. Empty groups are included.
List<(String, List<Map>)> sections(
  List<Map> entries,
  GroupData data, {
  bool Function(Map)? isRunning,
}) {
  final order = [...groupIds(data), other];
  final buckets = {for (final g in order) g: <Map>[]};
  final first = <Map>[];
  for (final app in entries) {
    if (isRunning != null && isRunning(app)) first.add(app);
    buckets[groupOf(app, data)]!.add(app);
  }
  return [
    if (isRunning != null) (running, first),
    for (final g in order) (g, inHandOrder(buckets[g]!, data)),
  ];
}

/// Put an entry into group gid before (or after) targetId; at the end
/// when targetId is not among memberIds (the group's entries as shown).
void place(
  GroupData data,
  String desktopId,
  String gid,
  String? targetId,
  List<String> memberIds, {
  bool after = false,
}) {
  assign(data, desktopId, gid);
  final ids = [for (final i in memberIds) if (i != desktopId) i];
  final index = targetId != null && ids.contains(targetId)
      ? ids.indexOf(targetId) + (after ? 1 : 0)
      : ids.length;
  ids.insert(index, desktopId);
  final moved = ids.toSet();
  final order = [
    for (final k in data['order'] as List? ?? const []) if (!moved.contains(k)) k,
    ...ids,
  ];
  data['order'] = order.length > maxMembers ? order.sublist(order.length - maxMembers) : order;
}

/// Sections of the "by origin" view, in [origins] order.
List<(String, List<Map>)> originSections(
  List<Map> entries,
  List<String> origins,
  String Function(Map) classify, {
  bool Function(Map)? isRunning,
}) {
  final buckets = {for (final o in origins) o: <Map>[]};
  final first = <Map>[];
  for (final app in entries) {
    if (isRunning != null && isRunning(app)) first.add(app);
    buckets['o-${classify(app)}']?.add(app);
  }
  return [
    if (isRunning != null) (running, first),
    for (final o in origins) (o, buckets[o]!),
  ];
}
