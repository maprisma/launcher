import 'dart:convert';
import 'dart:io';

import 'package:appmanager_core/appmanager_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('search output', () {
    test('pacman and the AUR', () {
      final found = parsePacmanSearch(
        'extra/gimp 3.2.6-2\n    GNU Image Manipulation Program\n'
        'extra/krita 5.2.9-1 (kde-applications) [installed]\n    Edit and paint images\n'
        'core/bad\$name 1-1\n    skipped\n',
        'pacman',
      );
      expect(found.map((f) => [f['repo'], f['package'], f['version'], f['installed'], f['description']]), [
        ['extra', 'gimp', '3.2.6-2', false, 'GNU Image Manipulation Program'],
        ['extra', 'krita', '5.2.9-1', true, 'Edit and paint images'],
      ]);
      final aur = parsePacmanSearch('aur/myx 0.5.0-1 (+0 0.00) [55d] \n    A lean terminal Spotify player\n', 'aur');
      expect(aur.single['aur'], isTrue);
      expect(aur.single['description'], 'A lean terminal Spotify player');
    });

    test('flatpak, apt, dnf (4 and 5), zypper, snap', () {
      expect(
        parseFlatpakSearch('org.gimp.GIMP\t3.0.4\tflathub\tGNU Image Manipulation Program\tCreate images\nbad line\n')
            .single,
        containsPair('remote', 'flathub'),
      );
      expect(parseAptSearch('gimp - GNU Image Manipulation Program\nlibgimp2.0 - libraries\n').map((f) => f['package']),
          ['gimp', 'libgimp2.0']);
      expect(parseDnfSearch('gimp.x86_64 : GNU Image Manipulation Program\n').single['package'], 'gimp');
      expect(parseDnfSearch('Matched fields: name\n gimp.x86_64\tGNU Image Manipulation Program\n').single['package'],
          'gimp');
      final zypper = parseZypperSearch(
        'S  | Name | Summary                        | Type\n---+------+--------------------------------+--------\n'
        'i+ | gimp | GNU Image Manipulation Program | package\n   | gimp | GIMP                           | srcpackage\n',
      );
      expect(zypper.single['installed'], isTrue);
      expect(parseSnapFind('Name  Version  Publisher  Notes  Summary\ngimp  2.10.38  snapcrafters✪  -  GNU Image Manipulation Program\n')
          .single['version'], '2.10.38');
    });
  });

  group('commands', () {
    final managers = Managers(Session(environment: {'HOME': '/h', 'PATH': '/usr/bin:/bin'}));
    final term = ['xdg-terminal-exec'];

    test('the package is a positional argument, never shell text', () {
      if (managers.installed()['pacman'] == null) return; // Arch only
      final argv = managers.installCommand('pacman', {'package': 'gimp'}, term)!;
      expect(argv.sublist(0, 3), ['xdg-terminal-exec', 'sh', '-c']);
      expect(argv[3], startsWith('sudo pacman -S -- "\$1"'));
      expect(argv.sublist(4), ['install', 'gimp']);
      for (final hostile in ['gimp; rm -rf ~', '\$(id)', '-Syu', 'a b', '']) {
        expect(managers.installCommand('pacman', {'package': hostile}, term), isNull, reason: hostile);
        expect(managers.removeCommand('pacman', hostile, term), isNull, reason: hostile);
      }
      expect(managers.removeCommand('pacman', 'gimp', term)![3], startsWith('sudo pacman -Rns -- "\$1"'));
    });

    test('the AUR helper never gets --noconfirm', () {
      if (managers.installed()['aur'] == null) return;
      final argv = managers.installCommand('aur', {'package': 'spotify'}, term)!;
      expect(argv[3], isNot(contains('noconfirm')));
      expect(argv[3], matches(RegExp(r'^(yay|paru) -S -- "\$1"')));
    });
  });

  test('core: install only what a search found; the shown command; AUR off by default', () async {
    final home = Directory.systemTemp.createTempSync('am-pkg-');
    addTearDown(() => home.deleteSync(recursive: true));
    final core = CoreService(environment: {...Platform.environment, 'HOME': home.path});
    Future<Map> call(String method, [Map<String, dynamic> params = const {}]) async =>
        jsonDecode(await core.handleAsync(jsonEncode({'id': 1, 'protocol': 1, 'method': method, 'params': params})))
            as Map;
    final managers = (await call('packages.managers'))['result']['managers'] as List;
    final aur = managers.where((m) => m['id'] == 'aur').firstOrNull;
    if (aur != null) expect(aur['enabled'], isFalse);
    final refused = await call('packages.install_plan', {'manager': 'pacman', 'package': 'gimp'});
    expect(refused['error']['code'], 'not_found');
    if (managers.every((m) => m['id'] != 'pacman')) return;
    final results = (await call('packages.search', {'query': 'gimp'}))['result']['results'] as List;
    expect(results.any((r) => r['package'] == 'gimp' && r['manager'] == 'pacman'), isTrue);
    final plan = (await call('packages.install_plan', {'manager': 'pacman', 'package': 'gimp'}))['result'] as Map;
    expect(plan['command'], 'sudo pacman -S -- gimp');
    // An AUR package cannot be planned while the AUR is not enabled.
    final aurPlan = await call('packages.install_plan', {'manager': 'aur', 'package': 'gimp'});
    expect(aurPlan['error']['code'], 'not_found');
  });

  test('the trash: files/ and info/, names kept apart', () {
    final home = Directory.systemTemp.createTempSync('am-trash-');
    addTearDown(() => home.deleteSync(recursive: true));
    final session = Session(environment: {'HOME': home.path});
    String make() => (File(p.join(home.path, 'My App.desktop'))..writeAsStringSync('x')).path;
    final first = moveToTrash(make(), session)!;
    final second = moveToTrash(make(), session)!;
    expect(p.basename(first), 'My App.desktop');
    expect(p.basename(second), 'My App.desktop.2');
    final info = File(p.join(home.path, '.local/share/Trash/info/My App.desktop.trashinfo')).readAsStringSync();
    expect(info, contains('Path=${p.join(home.path, 'My%20App.desktop')}'));
    expect(info, contains('DeletionDate='));
    expect(File(p.join(home.path, 'My App.desktop')).existsSync(), isFalse);
  });
}
