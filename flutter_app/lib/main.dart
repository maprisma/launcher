import 'dart:async';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'apps_page.dart';
import 'backend.dart';
import 'core_call.dart';
import 'window_shots.dart';
import 'i18n.dart';

export 'apps_page.dart' show AppView, WideLayout;
export 'core_call.dart';
import 'theme.dart';

/// The runner's channel: "shown" (the window came back), "titlebar"
/// (dark or light), "hide".
const windowChannel = MethodChannel('maprisma-launcher/window');

/// Counts the times the window was shown again (--toggle, a second start).
final shownAgain = ValueNotifier<int>(0);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final backend = await Backend.start();
  final look = await backend.call('desktop.look').catchError((_) => <String, dynamic>{});
  final settings = await backend.call('settings.get').catchError((_) => <String, dynamic>{});
  await I18n.use(settings['language'] as String? ?? 'auto');
  windowChannel.setMethodCallHandler((call) async {
    if (call.method == 'shown') shownAgain.value++;
  });
  runApp(MaprismaLauncherApp(core: backend.call, look: look, settings: settings));
}

class MaprismaLauncherApp extends StatefulWidget {
  const MaprismaLauncherApp({super.key, required this.core, required this.look, this.settings = const {}});
  final CoreCall core;
  final Map<String, dynamic> look;
  final Map<String, dynamic> settings;
  @override
  State<MaprismaLauncherApp> createState() => _MaprismaLauncherState();
}

class _MaprismaLauncherState extends State<MaprismaLauncherApp> with WidgetsBindingObserver {
  late Map<String, dynamic> look = widget.look;
  late String cornersSetting = widget.settings['corners'] as String? ?? 'windows';
  late Map<String, dynamic> settings = widget.settings;

  /// F12: a picture of this window and a note (window_shots.dart).
  final _windowShots = WindowShots.fromEnvironment(Platform.environment);
  final _shotArea = GlobalKey();
  final _navigator = GlobalKey<NavigatorState>();
  bool _shooting = false;

  bool _shotKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.f12) return false;
    if (settings['screenshot_key'] == false) return false;
    unawaited(_takeShot());
    return true;
  }

  Future<void> _takeShot() async {
    final context = _navigator.currentContext;
    final area = _shotArea.currentContext?.findRenderObject();
    if (context == null || _shooting || area is! RenderRepaintBoundary) return;
    _shooting = true;
    try {
      final time = DateTime.now();
      final image = await area.toImage(pixelRatio: MediaQuery.devicePixelRatioOf(context));
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final path = await _windowShots.saveTo(
        settings['screenshot_folder'] as String?,
        data.buffer.asUint8List(),
        time,
      );
      if (!context.mounted) return;
      final note = await showDialog<String>(context: context, builder: (_) => ShotNote(path));
      await _windowShots.note(path, note ?? '');
    } catch (_) {
      // A picture must never disturb the app.
    } finally {
      _shooting = false;
    }
  }

  /// Settings › Corners and Language take effect at once.
  void _onSettings(Map<String, dynamic> settings) {
    setState(() {
      this.settings = settings;
      cornersSetting = settings['corners'] as String? ?? 'windows';
    });
    I18n.use(settings['language'] as String? ?? 'auto');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    shownAgain.addListener(_reloadLook);
    HardwareKeyboard.instance.addHandler(_shotKey);
    _syncTitlebar();
  }

  @override
  void dispose() {
    shownAgain.removeListener(_reloadLook);
    HardwareKeyboard.instance.removeHandler(_shotKey);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => _reloadLook();

  /// A theme switch while hidden shows when the window comes back.
  Future<void> _reloadLook() async {
    try {
      final fresh = await widget.core('desktop.look');
      if (mounted) setState(() => look = fresh);
      _syncTitlebar();
    } on Object {
      // The old look stays.
    }
  }

  void _syncTitlebar() {
    final platform = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final dark = appTheme(platform, look['colors'] as Map? ?? {}, 12).brightness == Brightness.dark;
    windowChannel.invokeMethod('titlebar', dark).ignore();
  }

  @override
  Widget build(BuildContext context) {
    final radius = cornerRadius(cornersSetting, look['rounding'] as int?);
    return ValueListenableBuilder(
      valueListenable: I18n.changed,
      builder: (context, _, _) => MaterialApp(
        navigatorKey: _navigator,
        // The picture F12 takes: the whole window, dialogs included.
        builder: (context, child) => RepaintBoundary(key: _shotArea, child: child),
        title: 'Maprisma Launcher',
        debugShowCheckedModeBanner: false,
        theme: appTheme(MediaQuery.platformBrightnessOf(context), look['colors'] as Map? ?? {}, radius),
        home: AppsPage(
          core: widget.core,
          desktop: '${look['desktop'] ?? ''}',
          shownAgain: shownAgain,
          onHide: () => windowChannel.invokeMethod('hide').ignore(),
          onSettings: _onSettings,
          windowRounding: look['rounding'] as int?,
        ),
      ),
    );
  }
}
