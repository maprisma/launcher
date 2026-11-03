/// The core service: requests from the GUI (docs/protocol.md) answered from
/// the scan and the desktop adapter. Runs in the GUI's background isolate.
library;

import 'dart:convert';

import 'apps.dart';
import 'desktop_entries.dart';
import 'desktops.dart';
import 'icon_theme.dart';
import 'launch.dart';
import 'protocol.dart';

const coreVersion = '0.1.0';

/// An entry's stable key: its desktop file, else its kind and id.
String appKey(Map app) {
  final path = app['desktop_path'] as String? ?? '';
  return path.isNotEmpty ? path : 'argv:${app['desktop_id']}';
}

final class CoreService {
  CoreService({Map<String, String>? environment, Session? session})
    : session = session ?? Session(environment: environment ?? const {}) {
    desktop = detectDesktop(this.session);
  }

  final Session session;
  late final Desktop desktop;
  IconTheme? _icons;
  String? _iconThemeName;
  final _apps = <String, Map<String, dynamic>>{};

  late final Map<String, Future<Map<String, dynamic>> Function(Map<String, dynamic>)>
  routes = {
    'core.hello': (_) async => {
      'version': coreVersion,
      'protocol': protocolVersion,
      'desktop': desktop.name,
    },
    'desktop.look': (_) => desktop.look(),
    'apps.list': (_) => _list(),
    'apps.launch': (params) => _launch(params, null),
    'apps.action': (params) {
      final action = params['action'];
      if (action is! String || action.isEmpty) throw ServiceError('bad_params');
      return _launch(params, action);
    },
  };

  Future<IconTheme> _iconTheme() async {
    final name = await desktop.iconTheme();
    if (_icons == null || name != _iconThemeName) {
      _icons = IconTheme(session, name);
      _iconThemeName = name;
    }
    return _icons!;
  }

  Future<Map<String, dynamic>> _list() async {
    final apps = await scanApps(session);
    final icons = await _iconTheme();
    _apps.clear();
    final out = <Map<String, dynamic>>[];
    for (final app in apps) {
      final key = appKey(app);
      _apps[key] = app;
      out.add({
        ...app,
        'key': key,
        'icon_file': icons.lookup(app['icon'] as String? ?? '') ??
            icons.lookup('application-x-executable'),
      });
    }
    return {'apps': out, 'icon_theme': _iconThemeName};
  }

  Future<Map<String, dynamic>> _launch(
    Map<String, dynamic> params,
    String? action,
  ) async {
    final key = params['key'];
    final app = key is String ? _apps[key] : null;
    if (app == null) throw ServiceError('unknown_app');
    final ok = action == null
        ? await desktop.launch(app)
        : await launchApp(app, session, terminal: desktop.terminal(), action: action);
    if (!ok) throw ServiceError('launch_failed');
    return {'started': true};
  }

  Future<String> handleAsync(String frame) async {
    int? id;
    try {
      final request = Request.decode(frame);
      id = request.id;
      final route = routes[request.method];
      if (route == null) throw ServiceError('unknown_route');
      final result = await route(request.params);
      return jsonEncode({'id': id, 'result': result});
    } on ServiceError catch (e) {
      return jsonEncode({
        'id': id,
        'error': {'code': e.code, 'message': ?e.reason},
      });
    } on FormatException {
      return jsonEncode({
        'id': id,
        'error': {'code': 'bad_request'},
      });
    } catch (e) {
      return jsonEncode({
        'id': id,
        'error': {'code': 'internal'},
      });
    }
  }

  void dispose() {}
}
