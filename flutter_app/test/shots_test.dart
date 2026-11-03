/// Screenshots of the real app, offscreen: `SHOTS=folder` flutter test
/// test/shots_test.dart. The core runs here on this machine's apps; fonts
/// are the system's sans and Flutter's Material icons. Skipped without SHOTS.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

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

String fcMatch(String pattern) =>
    (Process.runSync('fc-match', [pattern, '--format=%{file}']).stdout as String).trim();

void main() {
  final key = GlobalKey();

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    Layout layout = Layout.list,
    String query = '',
    Size size = const Size(920, 640),
  }) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    late Map<String, dynamic> look, list;
    final core = CoreService(environment: Platform.environment);
    await tester.runAsync(() async {
      await loadFont('Roboto', [fcMatch('sans-serif'), fcMatch('sans-serif:bold')]);
      await loadFont('MaterialIcons', [
        '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ]);
      look = await call(core, 'desktop.look');
      list = await call(core, 'apps.list');
    });
    Future<Map<String, dynamic>> fake(String method, [Map<String, dynamic> params = const {}]) async =>
        switch (method) {
          'desktop.look' => look,
          'apps.list' => list,
          _ => throw ServiceError('not_in_shots'),
        };
    await tester.pumpWidget(RepaintBoundary(key: key, child: AppManager(core: fake, look: look, initialLayout: layout)));
    await tester.pump();
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

  testWidgets('list', (t) => shoot(t, 'list'), skip: shots == null);
  testWidgets('icons', (t) => shoot(t, 'icons', layout: Layout.icons), skip: shots == null);
  testWidgets('filter', (t) => shoot(t, 'filter', query: 'co'), skip: shots == null);
}

Future<Map<String, dynamic>> call(CoreService core, String method) async {
  final reply = await core.handleAsync('{"id":1,"protocol":1,"method":"$method"}');
  return Map<String, dynamic>.from((jsonDecode(reply) as Map)['result'] as Map);
}
