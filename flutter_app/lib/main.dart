import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'apps_page.dart';
import 'backend.dart';
import 'core_call.dart';

export 'apps_page.dart' show AppView, WideLayout;
export 'core_call.dart';
import 'theme.dart';

/// The runner's channel: "shown" (the window came back), "titlebar"
/// (dark or light), "hide".
const windowChannel = MethodChannel('appmanager/window');

/// Counts the times the window was shown again (--toggle, a second start).
final shownAgain = ValueNotifier<int>(0);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final backend = await Backend.start();
  final look = await backend.call('desktop.look').catchError((_) => <String, dynamic>{});
  windowChannel.setMethodCallHandler((call) async {
    if (call.method == 'shown') shownAgain.value++;
  });
  runApp(AppManager(core: backend.call, look: look));
}

class AppManager extends StatefulWidget {
  const AppManager({super.key, required this.core, required this.look});
  final CoreCall core;
  final Map<String, dynamic> look;
  @override
  State<AppManager> createState() => _AppManagerState();
}

class _AppManagerState extends State<AppManager> with WidgetsBindingObserver {
  late Map<String, dynamic> look = widget.look;
  String cornersSetting = 'windows';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    shownAgain.addListener(_reloadLook);
    _syncTitlebar();
  }

  @override
  void dispose() {
    shownAgain.removeListener(_reloadLook);
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
    return MaterialApp(
      title: 'App Manager',
      debugShowCheckedModeBanner: false,
      theme: appTheme(MediaQuery.platformBrightnessOf(context), look['colors'] as Map? ?? {}, radius),
      home: AppsPage(
        core: widget.core,
        desktop: '${look['desktop'] ?? ''}',
        shownAgain: shownAgain,
        onHide: () => windowChannel.invokeMethod('hide').ignore(),
      ),
    );
  }
}
