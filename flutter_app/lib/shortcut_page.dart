import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backend.dart';
import 'core_call.dart';
import 'i18n.dart';
import 'theme.dart';

/// The key map's keys from a key event (keysym names, as the core takes
/// them); the letter is the layout's own. Tab moves the focus instead.
final _eventKeys = <LogicalKeyboardKey, String>{
  for (var i = 0; i < 26; i++)
    LogicalKeyboardKey(LogicalKeyboardKey.keyA.keyId + i): String.fromCharCode(65 + i),
  for (var i = 0; i < 10; i++)
    LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + i): '$i',
  LogicalKeyboardKey.f1: 'F1', LogicalKeyboardKey.f2: 'F2', LogicalKeyboardKey.f3: 'F3',
  LogicalKeyboardKey.f4: 'F4', LogicalKeyboardKey.f5: 'F5', LogicalKeyboardKey.f6: 'F6',
  LogicalKeyboardKey.f7: 'F7', LogicalKeyboardKey.f8: 'F8', LogicalKeyboardKey.f9: 'F9',
  LogicalKeyboardKey.f10: 'F10', LogicalKeyboardKey.f11: 'F11', LogicalKeyboardKey.f12: 'F12',
  LogicalKeyboardKey.enter: 'Return', LogicalKeyboardKey.space: 'space',
  // German keys: Flutter names a printable key by its character.
  const LogicalKeyboardKey(0xdf): 'ssharp', const LogicalKeyboardKey(0xfc): 'udiaeresis',
  const LogicalKeyboardKey(0xf6): 'odiaeresis', const LogicalKeyboardKey(0xe4): 'adiaeresis',
  const LogicalKeyboardKey(0x2b): 'plus', const LogicalKeyboardKey(0x23): 'numbersign',
  const LogicalKeyboardKey(0x3c): 'less',
  LogicalKeyboardKey.backspace: 'BackSpace', LogicalKeyboardKey.delete: 'Delete',
  LogicalKeyboardKey.home: 'Home', LogicalKeyboardKey.end: 'End',
  LogicalKeyboardKey.pageUp: 'Page_Up', LogicalKeyboardKey.pageDown: 'Page_Down',
  LogicalKeyboardKey.insert: 'Insert', LogicalKeyboardKey.minus: 'minus', LogicalKeyboardKey.equal: 'equal',
  LogicalKeyboardKey.bracketLeft: 'bracketleft', LogicalKeyboardKey.bracketRight: 'bracketright',
  LogicalKeyboardKey.backslash: 'backslash', LogicalKeyboardKey.semicolon: 'semicolon',
  LogicalKeyboardKey.quote: 'apostrophe', LogicalKeyboardKey.backquote: 'grave',
  LogicalKeyboardKey.comma: 'comma', LogicalKeyboardKey.period: 'period', LogicalKeyboardKey.slash: 'slash',
};

/// The US key map, used until the core sends its rows for the session's
/// keyboard layout (keyboard_layout.dart); the core colours each key.
const keyRows = [
  ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0', 'minus', 'equal'],
  ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', 'bracketleft', 'bracketright'],
  ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', 'semicolon', 'apostrophe', 'backslash'],
  ['grave', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', 'comma', 'period', 'slash'],
  ['F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'],
  ['Return', 'space', 'BackSpace', 'Delete', 'Home', 'End', 'Page_Up', 'Page_Down', 'Insert', 'Tab'],
];

const modOrder = ['SUPER', 'SHIFT', 'CTRL', 'ALT'];
const modNames = {'SUPER': 'Super', 'SHIFT': 'Shift', 'CTRL': 'Ctrl', 'ALT': 'Alt'};

/// Shortcut… (launcher.py's shortcut page): what opens the app now (any
/// source; change, remove, turn off and on), then a new key: modifiers, a key
/// from the map coloured by who has it, what it opens, Assign. Esc cancels a
/// change, then goes back; Enter assigns.
///
/// [embedded]: a card inside another page (Ask AI) instead of a page of its
/// own: no Back header, Esc is left to the page around it. [full] false shows
/// only the current shortcuts (with "Add a shortcut…" to open the rest);
/// [mods] and [comboKey] preset a proposed key (the user still assigns it);
/// [highlight] marks the shortcut with that label.
class ShortcutPage extends StatefulWidget {
  const ShortcutPage({
    super.key,
    required this.core,
    required this.app,
    this.embedded = false,
    this.readOnly = false,
    this.full = true,
    this.mods,
    this.comboKey,
    this.highlight,
  });
  final CoreCall core;
  final Map app;
  final bool embedded;
  final bool readOnly;
  final bool full;
  final List<String>? mods;
  final String? comboKey;
  final String? highlight;
  @override
  State<ShortcutPage> createState() => ShortcutPageState();
}

class ShortcutPageState extends State<ShortcutPage> {
  Map<String, dynamic> view = const {};
  bool loading = true;
  List<String> mods = [];
  String? key;
  String action = '';

  /// The shortcut being changed: {mods, key, then?, action, external, label}.
  Map<String, dynamic>? editing;
  String message = '';
  bool messageOk = false;
  bool busy = false;
  int _asked = 0;
  final _focus = FocusNode();

  /// The Add controls and the key map are shown (always on a page of its own).
  late bool full = widget.full || !widget.embedded;

  String get appName => '${widget.app['name']}';
  String get desktop => '${view['desktop'] ?? ''}';
  List<Map> get actions => [for (final a in view['actions'] as List? ?? const []) a as Map];

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    // A new shortcut always starts from the default modifiers (Super + Shift
    // unless changed); the key stays open until one is pressed or picked.
    final first = await _state(fresh: true);
    if (first == null || !mounted) return;
    mods = widget.mods != null && widget.mods!.isNotEmpty
        ? [for (final m in modOrder) if (widget.mods!.contains(m)) m]
        : [...(first['default_mods'] as List? ?? const ['SUPER', 'SHIFT']).cast<String>()];
    key = widget.comboKey;
    await _refresh();
    // A proposed new key in Ask AI: key presses go to the card at once.
    if (mounted && widget.embedded && widget.full) _focus.requestFocus();
  }

  Future<Map<String, dynamic>?> _state({bool fresh = false}) async {
    final mine = ++_asked;
    try {
      final result = await widget.core('shortcuts.state', {
        'key': widget.app['key'],
        'mods': mods,
        'action': action,
        if (editing != null) 'editing': editing,
        if (fresh) 'fresh': true,
      });
      if (!mounted || mine != _asked) return null;
      setState(() {
        view = result;
        loading = false;
      });
      return result;
    } on ServiceError catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          message = trf('Not applied: {0}', [e.reason ?? e.code]);
          messageOk = false;
        });
      }
      return null;
    }
  }

  Future<void> _refresh({bool fresh = false}) => _state(fresh: fresh);

  Map? _keyInfo(String name) =>
      (view['keys'] as List?)?.cast<Map>().where((k) => '${k['key']}'.toLowerCase() == name.toLowerCase()).firstOrNull;

  static String keyLabel(String name) => const {
    'Return': 'Enter', 'space': 'Space', 'BackSpace': 'Backspace', 'Page_Up': 'Page Up', 'Page_Down': 'Page Down',
    'minus': '-', 'equal': '=', 'bracketleft': '[', 'bracketright': ']', 'backslash': r'\', 'semicolon': ';',
    'apostrophe': "'", 'grave': '`', 'comma': ',', 'period': '.', 'slash': '/',
    'ssharp': 'ß', 'udiaeresis': 'Ü', 'odiaeresis': 'Ö', 'adiaeresis': 'Ä', 'plus': '+', 'numbersign': '#',
    'less': '<',
  }[name] ?? name;

  String comboLabel(List mods, String key) => [for (final m in mods) modNames[m] ?? '$m', keyLabel(key)].join(' + ');
  String get pickedLabel => key == null ? '' : comboLabel(mods, key!);

  String targetName(String actionId) {
    if (actionId.isEmpty) return appName;
    return '${actions.where((a) => a['id'] == actionId).firstOrNull?['name'] ?? actionId}';
  }

  Future<void> _setMods(List<String> value) async {
    setState(() => mods = [for (final m in modOrder) if (value.contains(m)) m]);
    await _refresh();
  }

  /// Clicking the picked key again clears it, as a second click turns a modifier off.
  void pick(String name) => setState(() => key = key?.toLowerCase() == name.toLowerCase() ? null : name);

  /// (text, kind, button, enabled) for the picked combo (update_shortcut_status).
  (String, String, String, bool) status() {
    if (key == null) return (tr('Press a key, or pick a free key below.'), 'info', tr('Assign'), false);
    if (mods.isEmpty) return (tr('Choose at least one modifier — Super is recommended.'), 'info', tr('Assign'), false);
    final info = _keyInfo(key!);
    if (info == null) return (tr('That key cannot be used for a shortcut.'), 'info', tr('Assign'), false);
    final level = '${info['level']}', owner = '${info['owner'] ?? ''}';
    final target = targetName(action);
    final assign = editing != null ? tr('Change') : tr('Assign');
    final same = editing != null && _sameCombo(editing!, mods, key!);
    if (same) {
      return level == 'same'
          ? (tr('That is the current key — press a different one, or pick something else to open.'), 'info', assign, false)
          : (trf('✓ Same key, now opens {0}.', [target]), 'free', tr('Change'), true);
    }
    return switch (level) {
      'retarget' => (trf('Opens {0} now — assigning makes it open {1}.', [targetName(owner), target]), 'info', tr('Change'), true),
      'free' => (
        tr('✓ Free.') + (mods.contains('SUPER') ? '' : ' ${tr('Without Super, apps can no longer receive it.')}'),
        'free',
        assign,
        true,
      ),
      'same' => (trf('Already opens {0} — nothing to add.', [owner.isNotEmpty && owner != appName ? '$target (“$owner”)' : target]), 'info', assign, false),
      'launcher' => (trf('Opens {0} now. Assigning moves it to {1}.', [owner, target]), 'warn', tr('Move here'), true),
      'custom' => (
        trf('Your custom shortcut “{0}”. Assigning turns it off while this shortcut exists; removing the shortcut brings it back.', [owner]),
        'warn',
        tr('Rebind'),
        true,
      ),
      _ => (
        trf("{1}'s “{0}”. Assigning turns it off while this shortcut exists; removing the shortcut brings it back.", [owner, desktop]),
        'desktop',
        tr('Rebind'),
        true,
      ),
    };
  }

  static bool _sameCombo(Map a, List mods, String key) =>
      (a['then'] ?? '') == '' &&
      '${a['key']}'.toLowerCase() == key.toLowerCase() &&
      (a['mods'] as List).toSet().containsAll(mods) &&
      mods.toSet().containsAll(a['mods'] as List);

  Future<bool> _commit(String method, Map<String, dynamic> params, String done) async {
    if (busy || widget.readOnly) return false;
    setState(() => busy = true);
    try {
      await widget.core(method, {'key': widget.app['key'], 'proposal': ?widget.app['proposal'], ...params});
      if (!mounted) return true;
      setState(() {
        message = done;
        messageOk = true;
        key = null;
        editing = null;
      });
      await _refresh(fresh: true);
      return true;
    } on ServiceError catch (e) {
      if (mounted) {
        setState(() {
          message = trf('Not applied: {0}', [e.reason ?? e.code]);
          messageOk = false;
        });
      }
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> assign() async {
    final (_, _, _, enabled) = status();
    if (!enabled || key == null) return;
    final target = targetName(action);
    final label = pickedLabel;
    var done = trf('✓ Saved — {0} opens {1}.', [label, target]);
    if (editing != null) {
      done = _sameCombo(editing!, mods, key!)
          ? trf('✓ {0} now opens {1}.', [label, target])
          : trf('✓ Changed {0} to {1}.', [editing!['label'], label]);
    }
    await _commit('shortcuts.set', {
      'mods': mods,
      'combo_key': key,
      'action': action,
      if (editing != null) 'editing': editing,
    }, done);
  }

  Map<String, dynamic> _combo(Map s) => {'mods': s['mods'], 'key': s['key'], if (s['then'] != null) 'then': s['then']};

  Future<void> remove(Map s) {
    final replaces = '${s['replaces'] ?? ''}';
    return _commit(
      'shortcuts.remove',
      {'combo': _combo(s)},
      trf('✓ Removed {0}.', [s['label']]) + (replaces.isNotEmpty ? ' ${trf('“{0}” works again', [replaces])}.' : ''),
    );
  }

  Future<void> turnOff(Map s) =>
      _commit('shortcuts.disable', {'combo': _combo(s)}, trf('✓ Turned off {0}. Turn it on again any time.', [s['label']]));

  Future<void> turnOn(Map s) => _commit('shortcuts.restore', {'combo': _combo(s)}, trf('✓ {0} is on again.', [s['label']]));

  /// start_change_shortcut: the Add controls pick a new key for it.
  Future<void> change(Map s) async {
    setState(() {
      full = true;
      editing = {
        ..._combo(s),
        'action': s['action'] ?? '',
        'external': s['source'] == 'external',
        'label': s['label'],
      };
      action = '${s['action'] ?? ''}';
      mods = [...(s['mods'] as List).cast<String>()];
      key = null;
      message = '';
    });
    await _refresh();
  }

  Future<void> cancelChange() async {
    setState(() {
      editing = null;
      key = null;
      mods = [...(view['default_mods'] as List? ?? const ['SUPER', 'SHIFT']).cast<String>()];
    });
    await _refresh();
  }

  Future<void> _setDefault(bool on) async {
    try {
      final r = await widget.core('shortcuts.default_mods', {'mods': on ? mods : <String>[]});
      if (mounted) setState(() => view = {...view, 'default_mods': r['default_mods']});
    } on ServiceError catch (e) {
      if (mounted) setState(() => message = trf('Could not save the default: {0}', [e.code]));
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (widget.readOnly) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final held = [
      if (keyboard.isMetaPressed) 'SUPER',
      if (keyboard.isShiftPressed) 'SHIFT',
      if (keyboard.isControlPressed) 'CTRL',
      if (keyboard.isAltPressed) 'ALT',
    ];
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (editing != null) {
        cancelChange();
      } else if (widget.embedded) {
        return KeyEventResult.ignored;
      } else {
        Navigator.maybePop(context);
      }
      return KeyEventResult.handled;
    }
    if (!full) return KeyEventResult.ignored;
    // Plain Enter assigns; with modifiers held it is the key being captured.
    if ((event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        held.isEmpty) {
      assign();
      return KeyEventResult.handled;
    }
    final name = _eventKeys[event.logicalKey];
    if (name == null || view['available'] != true) return KeyEventResult.ignored;
    if (held.isNotEmpty && held.join() != mods.join()) {
      setState(() => key = name);
      _setMods(held);
    } else {
      setState(() => key = name);
    }
    return KeyEventResult.handled;
  }

  // --- building ------------------------------------------------------------------

  Color levelColor(String level, ColorScheme scheme, MarkColors marks) => switch (level) {
    'free' => marks.running,
    'same' || 'retarget' => scheme.primary,
    'launcher' || 'custom' => marks.fresh,
    _ => marks.update,
  };

  Widget caps(String label, {bool large = false, bool dim = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final part in label.split(' + '))
          Container(
            padding: EdgeInsets.symmetric(horizontal: large ? 12 : 8, vertical: large ? 4 : 2),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(cornerSizes(context).small),
              color: scheme.surfaceContainerHighest.withValues(alpha: dim ? .3 : 1),
            ),
            child: Text(
              part,
              style: (large ? Theme.of(context).textTheme.bodyMedium : Theme.of(context).textTheme.bodySmall)?.copyWith(
                fontWeight: FontWeight.w600,
                color: dim ? scheme.onSurfaceVariant : scheme.onSurface,
              ),
            ),
          ),
      ],
    );
  }

  Widget _row(Map s, {required String note, required String tag, required Widget button, VoidCallback? onChange, bool dim = false}) {
    final scheme = Theme.of(context).colorScheme;
    final changing = editing != null && onChange != null && editing!['label'] == s['label'];
    String plain(Object? label) => '$label'.toLowerCase().replaceAll(RegExp(r'\s'), '');
    final marked = !changing && (widget.highlight ?? '').isNotEmpty && plain(s['label']) == plain(widget.highlight);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(cornerSizes(context).control),
        color: marked ? scheme.errorContainer.withValues(alpha: .35) : null,
        border: Border.all(
          color: changing
              ? scheme.primary
              : marked
              ? scheme.error
              : scheme.outlineVariant.withValues(alpha: .5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onChange,
              child: Tooltip(
                message: onChange == null ? '' : tr('Click to change this shortcut'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    caps('${s['label']}', dim: dim),
                    const SizedBox(height: 4),
                    Text(note, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(tag, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          if (onChange != null)
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: tr('Change this shortcut to another key'),
              onPressed: onChange,
            ),
          button,
        ],
      ),
    );
  }

  List<Widget> _current() {
    final shortcuts = [for (final s in view['shortcuts'] as List? ?? const []) s as Map];
    final disabled = [for (final s in view['disabled'] as List? ?? const []) s as Map];
    final rows = <Widget>[];
    for (final s in shortcuts) {
      final target = targetName('${s['action'] ?? ''}');
      if (s['source'] == 'launcher') {
        var note = trf('Opens {0}', [target]);
        final replaces = '${s['replaces'] ?? ''}';
        if (s['duplicate'] == true) {
          note += ' · ${tr('duplicate of another shortcut — remove it here to tidy up')}';
        } else if (replaces.isNotEmpty) {
          note += ' · ${trf('overrides “{0}”', [replaces])}';
        }
        rows.add(
          _row(
            s,
            note: note,
            tag: tr('Launcher'),
            onChange: widget.readOnly ? null : () => change(s),
            button: IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: tr('Remove this shortcut') + (replaces.isNotEmpty ? ' — ${trf('“{0}” works again', [replaces])}' : ''),
              onPressed: busy || widget.readOnly ? null : () => remove(s),
            ),
          ),
        );
      } else {
        final file = '${s['file'] ?? ''}';
        final origin = switch (file) {
          'GNOME' => tr('GNOME default'),
          'Omarchy' => tr('Omarchy default'),
          _ => tr('Your custom shortcut'),
        };
        var note = '${trf('Opens {0}', [target])} · $origin';
        final description = '${s['description'] ?? ''}';
        if (description.isNotEmpty && description != target) note += ' “$description”';
        rows.add(
          _row(
            s,
            note: note,
            tag: file,
            onChange: widget.readOnly ? null : () => change(s),
            button: IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: tr('Turn off — you can turn it back on here'),
              onPressed: busy || widget.readOnly ? null : () => turnOff(s),
            ),
          ),
        );
      }
    }
    if (shortcuts.isEmpty) {
      rows.add(Padding(padding: const EdgeInsets.all(4), child: Text(tr('None yet — add one below.'))));
    }
    for (final s in disabled) {
      final description = '${s['description'] ?? ''}';
      rows.add(
        _row(
          s,
          dim: true,
          note: tr('Turned off') + (description.isNotEmpty ? ' · ${trf('was “{0}”', [description])}' : ''),
          tag: '${s['source'] ?? desktop}',
          button: TextButton(
            onPressed: busy || widget.readOnly ? null : () => turnOn(s),
            child: Tooltip(message: tr('Use this shortcut again'), child: Text(tr('Turn on'))),
          ),
        ),
      );
    }
    return rows;
  }

  String keyTip(String label, Map info) {
    final owner = '${info['owner'] ?? ''}';
    return switch ('${info['level']}') {
      'free' => trf('{0} — free', [label]),
      'same' || 'retarget' => trf('{0} — already opens {1}', [label, appName]),
      'launcher' => trf('{0} — opens {1}; click to move it here', [label, owner]),
      'custom' => trf('{0} — your custom shortcut “{1}”; click to rebind', [label, owner]),
      _ => trf("{0} — {2}'s “{1}”; click to rebind", [label, owner, desktop]),
    };
  }

  Widget _keyMap(ColorScheme scheme, MarkColors marks) {
    final keys = view['keys'] as List?;
    // The core's rows for the session's keyboard layout (German: QWERTZ).
    final rows = [
      for (final r in view['rows'] as List? ?? keyRows) [for (final k in r as List) '$k'],
    ];
    if (keys == null) {
      final suggestions = [for (final s in view['suggestions'] as List? ?? const []) s as Map];
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final s in suggestions)
            ActionChip(
              label: Text('${s['label']}'.replaceAll(' + ', '+')),
              tooltip: trf('Use {0}', [s['label']]),
              onPressed: () async {
                setState(() => key = '${s['key']}');
                await _setMods([...(s['mods'] as List).cast<String>()]);
              },
            ),
          if (suggestions.isEmpty) Text(tr('Choose modifiers above to see every key.')),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final name in row)
                  if (_keyInfo(name) case final info?)
                    () {
                      final color = levelColor('${info['level']}', scheme, marks);
                      final picked = key?.toLowerCase() == name.toLowerCase();
                      return Tooltip(
                        message: keyTip(comboLabel(mods, name), info),
                        child: InkWell(
                          key: ValueKey('key-$name'),
                          borderRadius: BorderRadius.circular(cornerSizes(context).small),
                          onTap: () => pick(name),
                          child: Container(
                            constraints: const BoxConstraints(minWidth: 30),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(cornerSizes(context).small),
                              color: color.withValues(alpha: picked ? .55 : .18),
                              border: Border.all(color: picked ? scheme.onSurface : color, width: picked ? 2 : 1),
                            ),
                            child: Text(keyLabel(name), textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                          ),
                        ),
                      );
                    }(),
              ],
            ),
          ),
      ],
    );
  }

  Widget _legend(ColorScheme scheme, MarkColors marks) {
    Widget item(String text, Color color) => Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Text('● $text', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color)),
    );
    return Tooltip(
      message: tr('Taken keys can be rebound; the original works again when you remove the shortcut.'),
      child: Wrap(
        children: [
          item(tr('free'), marks.running),
          item(tr('yours'), marks.fresh),
          item(trf('{0} default', [desktop]), marks.update),
        ],
      ),
    );
  }

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
  );

  /// The shortcuts, then (when [full]) the Add controls and the key map.
  List<Widget> _body(ColorScheme scheme, MarkColors marks) {
    final (text, kind, button, enabled) = status();
    final defaults = (view['default_mods'] as List?)?.cast<String>() ?? const ['SUPER', 'SHIFT'];
    final statusColor = switch (kind) {
      'free' => marks.running,
      'warn' => marks.fresh,
      'desktop' => marks.update,
      _ => scheme.onSurfaceVariant,
    };
    if (widget.readOnly) return _current();
    if (!full) {
      return [
        ..._current(),
        if (message.isNotEmpty) Text(message, style: TextStyle(color: messageOk ? marks.running : scheme.error)),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('shortcut-add-open'),
            onPressed: () {
              setState(() => full = true);
              _focus.requestFocus();
            },
            icon: const Icon(Icons.add, size: 18),
            label: Text(tr('Add a shortcut…')),
          ),
        ),
      ];
    }
    return [
      ..._current(),
      const Divider(height: 24),
      Row(
        children: [
          Expanded(
            child: Text(
              editing != null ? trf('Change {0} to', [editing!['label']]) : tr('Add a shortcut'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          if (editing != null)
            Tooltip(
              message: tr('Keep the current key'),
              child: TextButton(onPressed: cancelChange, child: Text(tr('Cancel'))),
            ),
        ],
      ),
      if (actions.isNotEmpty)
        Row(
          children: [
            Text(tr('Opens')),
            const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: tr('Open the app, or one of its own actions such as a private window'),
                child: DropdownButton<String>(
                  borderRadius: BorderRadius.circular(corners(context)),
                  key: const ValueKey('shortcut-action'),
                  isExpanded: true,
                  value: action,
                  items: [
                    DropdownMenuItem(value: '', child: Text(appName)),
                    for (final a in actions)
                      DropdownMenuItem(value: '${a['id']}', child: Text('${a['name']}')),
                  ],
                  onChanged: (value) async {
                    setState(() => action = value ?? '');
                    await _refresh();
                  },
                ),
              ),
            ),
          ],
        ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          for (final m in modOrder)
            FilterChip(
              key: ValueKey('mod-$m'),
              label: Text(modNames[m]!),
              selected: mods.contains(m),
              onSelected: (on) => _setMods(on ? [...mods, m] : [for (final x in mods) if (x != m) x]),
            ),
        ],
      ),
      Tooltip(
        message: trf(
          'Current default: {0}. Check to make the selected modifiers the default; uncheck to go back to Super + Shift.',
          [defaults.map((m) => modNames[m]).join(' + ')],
        ),
        child: CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(tr('Default for apps without a shortcut')),
          value: mods.isNotEmpty && mods.join() == defaults.join(),
          onChanged: mods.isEmpty ? null : (on) => _setDefault(on == true),
        ),
      ),
      Row(
        children: [
          Expanded(
            child: Tooltip(
              message: tr('Press a key now. Hold modifiers while pressing, or toggle them above.'),
              child: key != null
                  ? caps(pickedLabel, large: true)
                  : Row(
                      children: [
                        if (mods.isNotEmpty) caps(mods.map((m) => modNames[m]).join(' + '), large: true),
                        const SizedBox(width: 8),
                        Text(tr('select a key'), style: TextStyle(color: scheme.onSurfaceVariant)),
                      ],
                    ),
            ),
          ),
          FilledButton(
            key: const ValueKey('shortcut-assign'),
            onPressed: enabled && !busy ? assign : null,
            child: Text(button),
          ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(text, style: TextStyle(color: statusColor)),
      ),
      if (message.isNotEmpty)
        Text(message, style: TextStyle(color: messageOk ? marks.running : scheme.error)),
      _section(
        view['keys'] != null
            ? trf('Keys with {0}', [mods.map((m) => modNames[m]).join(' + ')])
            : tr('Free suggestions'),
      ),
      if (view['keys'] != null) _legend(scheme, marks),
      const SizedBox(height: 8),
      _keyMap(scheme, marks),
    ];
  }

  /// [unavailable] or the body, for a page or a card.
  Widget _unavailable() => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(
      view['desktop'] == null
          ? tr('Global shortcuts need GNOME, COSMIC or Omarchy; this desktop has no place to write them to.')
          : trf("{0}'s keyboard settings were not found, so shortcuts cannot be set here.", [desktop]),
      textAlign: TextAlign.center,
    ),
  );

  /// The card inside Ask AI: the app's name, then the body.
  Widget _card(ColorScheme scheme, MarkColors marks) {
    final count = (view['shortcuts'] as List?)?.length ?? 0;
    return Card(
      margin: EdgeInsets.zero,
      child: Focus(
        focusNode: _focus,
        autofocus: full,
        onKeyEvent: _onKey,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const Icon(Icons.keyboard_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        trf('Shortcuts for {0}', [appName]) + (count > 1 ? ' ($count)' : ''),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
              if (loading)
                const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator())
              else if (view['available'] != true)
                _unavailable()
              else
                ..._body(scheme, marks),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final marks = markColors(context);
    if (widget.embedded) return _card(scheme, marks);
    final available = view['available'] == true;
    final count = (view['shortcuts'] as List?)?.length ?? 0;
    return Scaffold(
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 16, 4),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back, size: 18),
                    label: Text(tr('Back')),
                  ),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      trf('Shortcuts for {0}', [appName]) + (count > 1 ? ' ($count)' : ''),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : !available
                  ? Center(child: _unavailable())
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      children: _body(scheme, marks),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
