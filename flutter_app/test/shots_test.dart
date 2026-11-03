/// Screenshots of the real app, offscreen: `SHOTS=folder` flutter test
/// test/shots_test.dart. The core runs here on this machine's apps; fonts
/// are the system's sans and Flutter's Material icons. Skipped without SHOTS.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:appmanager/i18n.dart';
import 'package:appmanager/main.dart';
import 'package:appmanager_core/appmanager_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final shots = Platform.environment['SHOTS'];

Future<void> loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final file in files) {
    final bytes = File(file).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

String fcMatch(String pattern) => (Process.runSync('fc-match', [pattern, '--format=%{file}']).stdout as String).trim();

void main() {
  final key = GlobalKey();

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    AppView view = AppView.list,
    WideLayout wide = WideLayout.folders,
    String language = 'en',
    bool settingsPage = false,
    String query = '',
    Size size = const Size(920, 640),
  }) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    late Map<String, dynamic> look, list, facts;
    // A throwaway config folder: the first start copies the old apps' files
    // into it (read only there), never into ~/.config/appmanager.
    final config = Directory.systemTemp.createTempSync('am-shots-');
    addTearDown(() => config.deleteSync(recursive: true));
    final core = CoreService(environment: Platform.environment, configDir: config.path);
    await tester.runAsync(() async {
      await loadFont('Roboto', [fcMatch('sans-serif'), fcMatch('sans-serif:bold')]);
      await loadFont('MaterialIcons', [
        '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ]);
      look = await call(core, 'desktop.look');
      list = await call(core, 'apps.list');
      facts = await call(core, 'apps.facts');
      await call(core, 'settings.set', {'key': 'view', 'value': view.name});
      await call(core, 'settings.set', {'key': 'wide_layout', 'value': wide.name});
      await call(core, 'settings.set', {'key': 'language', 'value': language});
      // Uwe's copied settings switch the filter field off; the shots want it.
      await call(core, 'settings.set', {'key': 'filter_field', 'value': true});
      await I18n.use(language);
    });
    Future<Map<String, dynamic>> fake(String method, [Map<String, dynamic> params = const {}]) async =>
        switch (method) {
          'desktop.look' => look,
          'apps.list' => list,
          'apps.facts' => facts,
          // Never in shots: checkupdates and flatpak fetch from the network.
          'updates.check' => <String, dynamic>{'apps': {}, 'flatpaks': {}},
          // The other routes only read and write files: they run here.
          _ => await call(core, method, params),
        };
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: AppManager(core: fake, look: look),
      ),
    );
    await tester.pump();
    if (settingsPage) {
      await tester.tap(find.byIcon(Icons.settings_outlined));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    if (query.isNotEmpty) {
      await tester.enterText(find.byType(TextField), query);
    }
    // Images and SVGs decode for real: let them arrive.
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$shots/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  const narrow = Size(440, 640);
  testWidgets('list', (t) => shoot(t, 'list', size: narrow), skip: shots == null);
  testWidgets(
    'groups',
    (t) => shoot(t, 'groups', view: AppView.groups, size: narrow),
    skip: shots == null,
  );
  testWidgets(
    'origin',
    (t) => shoot(t, 'origin', view: AppView.origin, size: narrow),
    skip: shots == null,
  );
  testWidgets('folders', (t) => shoot(t, 'folders'), skip: shots == null);
  testWidgets('cards', (t) => shoot(t, 'cards', wide: WideLayout.cards), skip: shots == null);
  testWidgets('icons', (t) => shoot(t, 'icons', wide: WideLayout.icons), skip: shots == null);
  testWidgets(
    'filter',
    (t) => shoot(t, 'filter', query: 'co', wide: WideLayout.icons),
    skip: shots == null,
  );
  testWidgets(
    'settings de',
    (t) => shoot(t, 'settings-de', language: 'de', settingsPage: true, size: narrow),
    skip: shots == null,
  );
  testWidgets('folders de', (t) => shoot(t, 'folders-de', language: 'de'), skip: shots == null);
  testWidgets('big folders', (t) => shoot(t, 'folders-big', size: const Size(1524, 860)), skip: shots == null);
}

Future<Map<String, dynamic>> call(CoreService core, String method, [Map<String, dynamic> params = const {}]) async {
  final reply = jsonDecode(
    await core.handleAsync(jsonEncode({'id': 1, 'protocol': 1, 'method': method, 'params': params})),
  ) as Map;
  if (reply['error'] case final Map error) throw ServiceError('${error['code']}');
  return Map<String, dynamic>.from(reply['result'] as Map);
}
