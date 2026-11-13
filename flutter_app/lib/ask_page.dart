import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_icon.dart';
import 'backend.dart';
import 'core_call.dart';
import 'i18n.dart';
import 'install_page.dart';
import 'mic_button.dart';
import 'shortcut_page.dart';
import 'theme.dart';

/// What the Ask page may do with an installed app: the same flows as the
/// app's own menu (open, uninstall, update, details).
typedef AppActions = ({
  void Function(Map app) open,
  Future<void> Function(Map app) uninstall,

  /// One review for the whole list; packages others need are left out.
  Future<void> Function(List<Map> apps) uninstallAll,
  Future<void> Function(Map app) update,
  Future<void> Function(Map app) updateAppImage,
  Future<void> Function() updateSystem,
  Future<void> Function(Map app) details,

  /// Hide from the launcher's list (true) or show again (false).
  Future<void> Function(Map app, bool hidden) setHidden,

  /// 'flatpak', 'appimage', 'package' (with the whole system), or null.
  String? Function(Map app) updateKind,
});

/// Ask AI (docs/proposals/ask-ai.md, step 2): one question, one checked
/// proposal; every action goes through the normal reviews. Tokens are spent
/// only when the user clicks Ask (at most two answers per click).
class AskPage extends StatefulWidget {
  const AskPage({
    super.key,
    required this.core,
    required this.apps,
    required this.actions,
    this.aiEnabled = true,
  });
  final CoreCall core;

  /// The installed apps by key (from apps.list).
  final Map<String, Map<String, dynamic>> apps;
  final AppActions actions;
  final bool aiEnabled;
  @override
  State<AskPage> createState() => _AskPageState();
}

class _AskPageState extends State<AskPage> {
  final request = TextEditingController();
  List<Map<String, dynamic>> helpers = [];

  /// The helper an Ask uses now (the core's `chosen`).
  String? helper;

  /// The shared choice of all Maprisma apps: "auto" or a helper id.
  String choice = 'auto';
  bool asking = false;
  Map<String, dynamic>? result;
  String? error;
  String? lastRequest;

  /// What dictation heard so far (shown greyed under the field); empty: nothing.
  String heard = '';

  /// Flatpaks being updated now (their row shows a spinner).
  final Set<String> updating = {};
  bool updatingAll = false;
  bool uninstallingAll = false;

  /// Hidden or shown here, by key: the buttons follow at once.
  final Map<String, bool> hiddenNow = {};

  bool _isHidden(Map app) =>
      hiddenNow['${app['key']}'] ?? app['hidden'] == true;

  /// Hide / Unhide as a toggle: one click each way, nothing without it.
  Widget _hideButton(Map app) {
    final hidden = _isHidden(app);
    return TextButton.icon(
      onPressed: () async {
        await widget.actions.setHidden(app, !hidden);
        if (mounted) setState(() => hiddenNow['${app['key']}'] = !hidden);
      },
      icon: Icon(hidden ? Icons.visibility : Icons.visibility_off, size: 16),
      label: Text(hidden ? tr('Unhide') : tr('Hide')),
    );
  }

  /// Your own suggestions under the field (setting ask_prompts); null: the
  /// built-in ones. [editingPrompt]: the one being edited in place.
  List<String>? ownPrompts;
  int? editingPrompt;
  final promptEdit = TextEditingController();

  static const maxPrompts = 12;

  List<String> get builtInPrompts => [
    tr('Suggest a photo editor'),
    tr('Find an app to cut videos'),
    tr('Which installed app opens PDFs?'),
    tr('What can I update?'),
  ];

  List<String> get prompts => ownPrompts ?? builtInPrompts;

  @override
  void initState() {
    super.initState();
    _loadHelpers();
    _loadPrompts();
  }

  @override
  void dispose() {
    request.dispose();
    _field.dispose();
    promptEdit.dispose();
    super.dispose();
  }

  Future<void> _loadPrompts() async {
    try {
      final settings = await widget.core('settings.get');
      final saved = settings['ask_prompts'];
      if (mounted && saved is List) {
        setState(() => ownPrompts = saved.cast<String>());
      }
    } on ServiceError {
      // The built-in suggestions stay.
    }
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  /// Saves the list (null: back to the built-in suggestions).
  Future<void> _storePrompts(List<String>? next) async {
    try {
      final settings = await widget.core('settings.set', {
        'key': 'ask_prompts',
        'value': next,
      });
      if (!mounted) return;
      final saved = settings['ask_prompts'];
      setState(() {
        ownPrompts = saved is List ? saved.cast<String>() : null;
        editingPrompt = null;
      });
    } on ServiceError {
      _say(tr('Could not save the setting'));
    }
  }

  static String _tidy(String text) => text.trim();

  static const _tight = VisualDensity(horizontal: -4, vertical: -4);

  /// The bookmark by the field: what you typed becomes a suggestion.
  Future<void> _savePrompt() async {
    final text = _tidy(request.text);
    final list = prompts;
    if (text.isEmpty) {
      _say(tr('Write a request first, then save it as a suggestion.'));
    } else if (list.contains(text)) {
      _say(tr('That is already a suggestion.'));
    } else if (list.length >= maxPrompts) {
      _say(trf('At most {0} suggestions: remove one first.', ['$maxPrompts']));
    } else {
      await _storePrompts([...list, text]);
      if (mounted) _say(tr('Saved as suggestion.'));
    }
  }

  void _editPrompt(int index) => setState(() {
    editingPrompt = index;
    promptEdit.text = prompts[index];
    promptEdit.selection = TextSelection.collapsed(
      offset: promptEdit.text.length,
    );
  });

  /// Enter or ✓ saves the edit (empty removes it); Esc cancels.
  Future<void> _finishEdit(bool save) async {
    final index = editingPrompt;
    if (index == null) return;
    final list = [...prompts];
    final text = _tidy(promptEdit.text);
    if (!save || index >= list.length || text == list[index]) {
      setState(() => editingPrompt = null);
      return;
    }
    if (text.isEmpty) {
      list.removeAt(index);
    } else if (list.contains(text)) {
      _say(tr('That is already a suggestion.'));
      return;
    } else {
      list[index] = text;
    }
    await _storePrompts(list);
  }

  Future<void> _removePrompt(int index) =>
      _storePrompts([...prompts]..removeAt(index));

  /// One suggestion: click asks with it, ✎ edits it in place, × removes it.
  Widget _promptChip(int index, String text, ColorScheme scheme) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(cornerSizes(context).control),
      side: BorderSide(color: scheme.outlineVariant),
    );
    if (editingPrompt == index) {
      return Material(
        shape: shape,
        color: scheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 320,
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape): () =>
                        _finishEdit(false),
                  },
                  child: TextField(
                    key: const ValueKey('prompt-edit'),
                    controller: promptEdit,
                    autofocus: true,
                    maxLength: 2000,
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      counterText: '',
                      hintText: tr('Edit suggestion'),
                    ),
                    onSubmitted: (_) => _finishEdit(true),
                  ),
                ),
              ),
              IconButton(
                tooltip: tr('Save'),
                visualDensity: _tight,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                iconSize: 18,
                onPressed: () => _finishEdit(true),
                icon: const Icon(Icons.check),
              ),
            ],
          ),
        ),
      );
    }
    return Material(
      shape: shape,
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () {
              request.text = text;
              _ask();
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Tooltip(
                  message: text,
                  child: Text(
                    text.replaceAll('\n', ' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: tr('Edit suggestion'),
            visualDensity: _tight,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 30),
            iconSize: 16,
            onPressed: () => _editPrompt(index),
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: tr('Remove suggestion'),
            visualDensity: _tight,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 30),
            iconSize: 16,
            onPressed: () => _removePrompt(index),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  /// The helpers and the shared choice (read again each time the page opens).
  Future<void> _loadHelpers() async {
    final r = await widget.core('ask.helpers');
    if (mounted) setState(() => _takeHelpers(r));
  }

  void _takeHelpers(Map<String, dynamic> r) {
    helpers = [
      for (final h in r['helpers'] as List) Map<String, dynamic>.from(h),
    ];
    choice = r['choice'] is String ? r['choice'] as String : 'auto';
    helper = r['chosen'] as String?;
  }

  /// A new choice goes to the shared file (Maprisma Manager › AI and every
  /// Maprisma app use the same one).
  Future<void> _choose(String value) async {
    try {
      final r = await widget.core('ai.helper.set', {'helper': value});
      if (mounted) setState(() => _takeHelpers(r));
    } on ServiceError {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('Could not save the setting'))),
        );
      }
    }
  }

  /// The drop-down's value: the shared choice, or Automatic when the chosen
  /// helper is not installed here.
  String get _shownChoice => helpers.any(
        (h) => h['installed'] == true && h['command'] == choice,
      )
      ? choice
      : 'auto';

  /// A helper's name, "(untested)" when the catalog's entry was never tried.
  static String helperLabel(Map h) =>
      '${h['name']}${h['verified'] == false ? tr(' (untested)') : ''}';

  Map<String, dynamic>? get chosen =>
      helpers.where((h) => h['command'] == helper).firstOrNull;

  /// The core's reason, without Dart's "Bad state: " and at most one line.
  static String? _why(String? reason) {
    if (reason == null || reason.trim().isEmpty) return null;
    final line = reason
        .replaceFirst(RegExp(r'^(Bad state|StateError|Exception): '), '')
        .split('\n')
        .first
        .trim();
    return line.length > 300 ? '${line.substring(0, 300)}…' : line;
  }

  Future<void> _ask({String? answer}) async {
    final text = answer == null ? request.text.trim() : (lastRequest ?? '');
    if (text.isEmpty || helper == null || asking) return;
    setState(() {
      asking = true;
      error = null;
      if (answer == null) {
        hiddenNow.clear(); // A new question: the apps as they are now.
      }
      if (answer == null) result = null;
      lastRequest = text;
    });
    try {
      final r = await widget.core('ask.run', {
        'request': text,
        'helper': helper,
        'language': I18n.language,
        'answer': ?answer,
      });
      if (mounted) setState(() => result = r);
    } on ServiceError catch (e) {
      if (mounted) {
        setState(
          () => error = e.code == 'helper_failed'
              // Why, when the core knows (e.g. the local model server did not start).
              ? [tr('The helper did not answer.'), ?_why(e.reason)].join(' ')
              : trf('That did not work ({0}).', [e.code]),
        );
      }
    } finally {
      if (mounted) setState(() => asking = false);
    }
  }

  Future<void> _stop() => widget.core('ask.cancel');

  /// A started request in the field, the cursor at its end (the user names the app).
  void _start(String text) {
    request.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _field.requestFocus();
  }

  final _field = FocusNode();

  /// The hint card: what Ask AI can do with keyboard shortcuts.
  Widget _shortcutHint(ColorScheme scheme) => Container(
    key: const ValueKey('ask-shortcut-hint'),
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(corners(context)),
      border: Border.all(color: scheme.outlineVariant),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.keyboard_outlined, size: 16, color: scheme.primary),
            const SizedBox(width: 8),
            Text(
              tr('Manage shortcuts for an app'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          tr(
            'List the keys that open your apps, remove one, or add a new one with the shortcut card.',
          ),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ActionChip(
              avatar: const Icon(Icons.list, size: 16),
              label: Text(tr('List all shortcuts')),
              onPressed: () {
                request.text = tr('List the shortcuts of all apps');
                _ask();
              },
            ),
            ActionChip(
              avatar: const Icon(Icons.remove_circle_outline, size: 16),
              label: Text(tr('Remove a shortcut…')),
              onPressed: () => _start(tr('Remove the shortcut of ')),
            ),
            ActionChip(
              avatar: const Icon(Icons.add_circle_outline, size: 16),
              label: Text(tr('Add a shortcut…')),
              onPressed: () => _start(tr('Add a shortcut for ')),
            ),
          ],
        ),
      ],
    ),
  );

  /// Ctrl+Enter: a line break at the cursor (Enter alone asks).
  void _newLine() {
    final value = request.value;
    if (asking) return;
    final sel = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    // The field's own limit (2000) holds for the line break too.
    if (value.text.length - (sel.end - sel.start) + 1 > 2000) return;
    final text = value.text.replaceRange(sel.start, sel.end, '\n');
    request.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: sel.start + 1),
    );
  }

  /// Back (button, Esc, Backspace): from an answer to the Ask AI start
  /// (the words stay in the field), from there out of the page.
  void _back() {
    if (result != null || error != null) {
      setState(() {
        result = null;
        error = null;
        editingPrompt = null;
      });
      _field.requestFocus();
      return;
    }
    Navigator.maybePop(context);
  }

  /// Backspace goes back, except while typing (in the field: once it is
  /// empty, so deleting the last letter does not leave the page at once).
  bool _backspaceGoesBack() {
    final focus = FocusManager.instance.primaryFocus;
    if (editingPrompt != null) return false;
    if (focus == _field) return request.text.isEmpty && result != null;
    return focus?.context?.widget is! EditableText;
  }

  Widget _header(ColorScheme scheme, {required bool ready}) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 12, 16, 4),
    child: Row(
      children: [
        TextButton.icon(
          onPressed: _back,
          icon: const Icon(Icons.arrow_back, size: 18),
          label: Text(tr('Back')),
        ),
        const Spacer(),
        Text(
          !widget.aiEnabled || (helpers.isNotEmpty && !ready)
              ? tr('INSTALL APPS')
              : tr('ASK AI'),
          style: TextStyle(
            letterSpacing: 1.2,
            fontWeight: FontWeight.w700,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  /// No helper yet (or AI disabled in Settings): show the Install apps package
  /// search directly, with a compact hint explaining why Ask AI is not
  /// available and which helpers can be connected.
  Widget _onboarding(ColorScheme scheme) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(corners(context)),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.aiEnabled) ...[
                Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_outlined,
                      size: 16,
                      color: markColors(context).update,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tr(
                          'To get app suggestions from an AI, connect an AI helper:',
                        ),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final h in helpers)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(cornerSizes(context).small),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.smart_toy_outlined, size: 14),
                            const SizedBox(width: 4),
                            Text(
                              helperLabel(h),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              h['installed'] != true
                                  ? tr('Not installed')
                                  : h['signed_in'] == true
                                  ? tr('Ready')
                                  : tr('Installed — needs sign-in'),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  if (!widget.aiEnabled) ...[
                    Icon(
                      Icons.auto_awesome_outlined,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      tr(
                        'Without AI, Install apps searches the packages by name.',
                      ),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      Expanded(child: InstallPage(core: widget.core, embedded: true)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ready =
        widget.aiEnabled && helpers.any((h) => h['installed'] == true);
    return Scaffold(
      body: Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _back();
            return KeyEventResult.handled;
          }
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.backspace &&
              _backspaceGoesBack()) {
            _back();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Column(
          children: [
            _header(scheme, ready: ready),
            if (!widget.aiEnabled || (helpers.isNotEmpty && !ready))
              Expanded(child: _onboarding(scheme)),
            if (ready) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Row(
                  children: [
                    Text(tr('Helper:')),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      key: const ValueKey('ask-helper'),
                      borderRadius: BorderRadius.circular(corners(context)),
                      value: _shownChoice,
                      underline: const SizedBox.shrink(),
                      items: [
                        DropdownMenuItem(
                          value: 'auto',
                          child: Text(
                            chosen == null
                                ? tr('Automatic')
                                : '${tr('Automatic')} · ${helperLabel(chosen!)}',
                          ),
                        ),
                        for (final h in helpers.where(
                          (h) => h['installed'] == true,
                        ))
                          DropdownMenuItem(
                            value: h['command'] as String,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // On this PC: a local model, no tokens.
                                if (h['local'] == true) ...[
                                  Tooltip(
                                    message: tr('On this PC'),
                                    child: const Icon(Icons.computer, size: 16),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                Text(
                                  '${helperLabel(h)}${h['signed_in'] == true ? '' : ' (${tr('needs sign-in')})'}',
                                ),
                              ],
                            ),
                          ),
                      ],
                      onChanged: asking
                          ? null
                          : (v) => v == null ? null : _choose(v),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${chosen?['local'] == true ? trf('Runs on this PC with {0}: no tokens, nothing leaves the computer.', [chosen?['name'] ?? '']) : trf('Uses your {0} plan or tokens, only when you click Ask.', [chosen?['name'] ?? ''])} '
                        '${tr('Enter asks, Ctrl+Enter: new line.')}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                // Enter asks; Ctrl+Enter starts a new line (where the cursor is).
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(
                      LogicalKeyboardKey.enter,
                      control: true,
                    ): _newLine,
                    const SingleActivator(
                      LogicalKeyboardKey.numpadEnter,
                      control: true,
                    ): _newLine,
                  },
                  child: TextField(
                    controller: request,
                    focusNode: _field,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 2000,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: tr(
                        'What do you need? e.g. “something to edit photos”',
                      ),
                      counterText: '',
                      helperText: heard.isEmpty ? null : heard,
                      helperMaxLines: 2,
                      suffixIcon: asking
                          ? IconButton(
                              tooltip: tr('Stop'),
                              onPressed: _stop,
                              icon: const Icon(Icons.stop_circle_outlined),
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                MicButton(
                                  appId: 'com.maprisma.Launcher',
                                  tr: tr,
                                  controller: request,
                                  focusNode: _field,
                                  onPartial: (t) {
                                    if (mounted) setState(() => heard = t);
                                  },
                                ),
                                IconButton(
                                  tooltip: tr('Save as suggestion'),
                                  onPressed: _savePrompt,
                                  icon: const Icon(Icons.bookmark_add_outlined),
                                ),
                                IconButton(
                                  tooltip: tr('Ask'),
                                  onPressed: () => _ask(),
                                  icon: Icon(Icons.send, color: scheme.primary),
                                ),
                              ],
                            ),
                    ),
                    onSubmitted: (_) => _ask(),
                  ),
                ),
              ),
              if (asking)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const LinearProgressIndicator(),
                      if (RegExp(
                        r'update|upgrade|newer version|aktualisier',
                        caseSensitive: false,
                      ).hasMatch(lastRequest ?? ''))
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(tr('Checking updates…')),
                        ),
                    ],
                  ),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(error!, style: TextStyle(color: scheme.error)),
                ),
              Expanded(
                child: result != null
                    ? _result(scheme, result!)
                    : asking
                    ? const SizedBox.shrink()
                    // The suggestions and the shortcut card scroll in a small window.
                    : SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  for (final (index, text) in prompts.indexed)
                                    _promptChip(index, text, scheme),
                                  if (ownPrompts != null)
                                    IconButton(
                                      tooltip: tr(
                                        'Back to the built-in suggestions',
                                      ),
                                      onPressed: () => _storePrompts(null),
                                      icon: const Icon(Icons.undo, size: 18),
                                    ),
                                ],
                              ),
                            ),
                            _shortcutHint(scheme),
                          ],
                        ),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _appRow(Map app, List<Widget> buttons) => ListTile(
    leading: AppIcon(app['icon_file'] as String?, size: 32),
    title: Text('${app['name']}'),
    subtitle: Text(
      tr(app['description'] as String? ?? ''),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: Wrap(spacing: 4, children: buttons),
  );

  Widget _result(ColorScheme scheme, Map<String, dynamic> r) {
    final a = widget.actions;
    final apps = [
      for (final k in (r['apps'] as List? ?? const [])) ?widget.apps[k],
    ];
    final installed = [
      for (final k in (r['installed'] as List? ?? const [])) ?widget.apps[k],
    ];
    final children = <Widget>[];
    switch (r['action']) {
      case 'install':
        final picks = [
          for (final x in r['picks'] as List? ?? const [])
            Map<String, dynamic>.from(x),
        ];
        if ('${r['summary'] ?? ''}'.isNotEmpty) {
          children.add(Text('${r['summary']}'));
        }
        if (installed.isNotEmpty) {
          children.add(_section(tr('Already installed')));
          for (final app in installed) {
            children.add(
              _appRow(app, [
                TextButton(
                  onPressed: () => a.open(app),
                  child: Text(tr('Open')),
                ),
              ]),
            );
          }
        }
        if (picks.isEmpty && installed.isEmpty) {
          children.add(
            Text(
              trf('Nothing found for “{0}”.', [
                (r['queries'] as List? ?? const []).join(', '),
              ]),
            ),
          );
        }
        if (picks.isNotEmpty) children.add(_section(tr('Suggestions')));
        for (final pick in picks) {
          final aur = pick['aur'] == true;
          children.add(
            Card(
              child: ListTile(
                title: Text('${pick['package']}  ${pick['version'] ?? ''}'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if ('${pick['reason'] ?? ''}'.isNotEmpty)
                      Text('${pick['reason']}'),
                    Text(
                      '${pick['description'] ?? ''}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                leading: Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    aur ? 'AUR' : '${pick['manager']}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  backgroundColor: aur
                      ? markColors(context).update.withValues(alpha: .2)
                      : null,
                ),
                trailing: pick['installed'] == true
                    ? Icon(
                        Icons.check_circle,
                        color: markColors(context).running,
                      )
                    : TextButton(
                        onPressed: () => reviewInstall(
                          context,
                          widget.core,
                          pick,
                          aur ? 'AUR' : '${pick['manager']}',
                        ),
                        child: Text(tr('Install…')),
                      ),
              ),
            ),
          );
        }
      case 'hide' || 'unhide' || 'list_hidden':
        final listing = r['action'] == 'list_hidden';
        children.add(
          _section(
            listing
                ? trn('{0} hidden app', '{0} hidden apps', apps.length)
                : r['action'] == 'hide'
                ? tr('Hide from the list')
                : tr('Show in the list again'),
          ),
        );
        if (apps.isEmpty) {
          children.add(
            Text(listing ? tr('No app is hidden.') : tr('Nothing to change.')),
          );
        }
        for (final app in apps) {
          children.add(_appRow(app, [_hideButton(app)]));
        }
      case 'remove':
        // "Uninstall all" on the heading's line, in the column of the row buttons.
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, right: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr('Uninstall'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (uninstallingAll)
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (apps.length > 1)
                  TextButton(
                    onPressed: () => _uninstallAll(apps),
                    child: Text(tr('Uninstall all')),
                  ),
              ],
            ),
          ),
        );
        for (final app in apps) {
          children.add(
            _appRow(app, [
              TextButton(
                onPressed: () => a.uninstall(app),
                child: Text(tr('Uninstall…')),
              ),
            ]),
          );
        }
      case 'update':
        // "Update all" on the heading's line, in the column of the row buttons.
        final updatable = apps.where(
          (app) => const {
            'flatpak',
            'appimage',
            'package',
          }.contains(a.updateKind(app)),
        );
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, right: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr('Update'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (updatingAll)
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  TextButton(
                    onPressed: updatable.isEmpty || updating.isNotEmpty
                        ? null
                        : () => _updateAll(apps),
                    child: Text(tr('Update all')),
                  ),
              ],
            ),
          ),
        );
        for (final app in apps) {
          final key = '${app['key']}';
          children.add(
            _appRow(app, [
              switch (a.updateKind(app)) {
                // A Flatpak updates alone; the row shows it is working.
                ('flatpak' || 'appimage') when updating.contains(key) =>
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                'flatpak' => TextButton(
                  onPressed: () async {
                    setState(() => updating.add(key));
                    try {
                      await a.update(app);
                    } finally {
                      if (mounted) setState(() => updating.remove(key));
                    }
                  },
                  child: Text(tr('Update')),
                ),
                'appimage' => TextButton(
                  onPressed: () async {
                    setState(() => updating.add(key));
                    try {
                      await a.updateAppImage(app);
                    } finally {
                      if (mounted) setState(() => updating.remove(key));
                    }
                  },
                  child: Text(tr('Update')),
                ),
                // A package: on Arch never alone, so with the whole system.
                'package' => TextButton(
                  onPressed: a.updateSystem,
                  child: Text(tr('Update system…')),
                ),
                _ => Text(
                  tr('No update known'),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              },
            ]),
          );
        }
        children.add(
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: a.updateSystem,
              child: Text(tr('Update system…')),
            ),
          ),
        );
      case 'update_system':
        children.add(
          Text(
            tr(
              'Updates the whole system in a terminal (on Arch never one package alone).',
            ),
          ),
        );
        children.add(
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: a.updateSystem,
              child: Text(tr('Update system…')),
            ),
          ),
        );
      case 'explain':
        if ('${r['answer'] ?? ''}'.isNotEmpty) {
          children.add(SelectableText('${r['answer']}'));
        }
        for (final app in apps) {
          children.add(
            _appRow(app, [
              TextButton(onPressed: () => a.open(app), child: Text(tr('Open'))),
              TextButton(
                onPressed: () => a.details(app),
                child: Text(tr('Details…')),
              ),
            ]),
          );
        }
      // Shortcuts: the app's shortcut card (shortcut_page.dart); every change is a click there.
      case 'shortcuts' || 'remove_shortcut' || 'add_shortcut':
        final adding = r['action'] == 'add_shortcut';
        final label = '${r['shortcut'] ?? ''}';
        // Adding: the card's own "Add a shortcut" is the heading.
        if (!adding) {
          children.add(
            _section(
              r['action'] == 'shortcuts'
                  ? trn(
                      'Shortcuts of {0} app',
                      'Shortcuts of {0} apps',
                      apps.length,
                    )
                  : label.isEmpty
                  ? tr('Remove a shortcut')
                  : trf('Remove {0}', [label]),
            ),
          );
        }
        if (apps.isEmpty) children.add(Text(tr('No app has a shortcut yet.')));
        if (r['action'] == 'remove_shortcut' && apps.isNotEmpty) {
          children.add(
            Text(
              tr('Click ✕ at a shortcut to remove it.'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          );
        }
        for (final app in apps) {
          children.add(
            ShortcutPage(
              // A new answer: new cards.
              key: ValueKey(
                'ask-shortcuts-${identityHashCode(r)}-${app['key']}',
              ),
              core: widget.core,
              app: app,
              embedded: true,
              full: adding,
              mods: adding
                  ? (r['mods'] as List? ?? const []).cast<String>()
                  : null,
              comboKey: adding ? r['key'] as String? : null,
              highlight: label.isEmpty ? null : label,
            ),
          );
        }
      case 'clarify':
        children.add(
          Text(
            '${r['question']}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        );
        children.add(const SizedBox(height: 8));
        children.add(
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final choice in (r['choices'] as List? ?? const []))
                ActionChip(
                  label: Text('$choice'),
                  onPressed: () => _ask(answer: '$choice'),
                ),
            ],
          ),
        );
        children.add(
          Text(
            tr('Choosing asks the helper once more.'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        );
      default:
        final hint = '${r['hint'] ?? ''}';
        children.add(
          Text(
            hint.isNotEmpty
                ? hint
                : tr(
                    'Maprisma Launcher can find, install, update, remove and explain apps and manage their shortcuts.',
                  ),
          ),
        );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final c in children)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: c),
      ],
    );
  }

  /// Every app of the list with an update, one after another (each row shows
  /// its own progress); packages update with the whole system, once, at the end.
  Future<void> _updateAll(List<Map> apps) async {
    final a = widget.actions;
    setState(() => updatingAll = true);
    var system = false;
    try {
      for (final app in apps) {
        if (!mounted) return;
        final kind = a.updateKind(app);
        final key = '${app['key']}';
        if (kind == 'flatpak' || kind == 'appimage') {
          setState(() => updating.add(key));
          try {
            if (kind == 'flatpak') {
              await a.update(app);
            } else {
              await a.updateAppImage(app);
            }
          } finally {
            if (mounted) setState(() => updating.remove(key));
          }
        } else if (kind == 'package') {
          system = true;
        }
      }
      if (system && mounted) a.updateSystem();
    } finally {
      if (mounted) setState(() => updatingAll = false);
    }
  }

  Future<void> _uninstallAll(List<Map> apps) async {
    setState(() => uninstallingAll = true);
    try {
      await widget.actions.uninstallAll(apps);
    } finally {
      if (mounted) setState(() => uninstallingAll = false);
    }
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
  );
}
