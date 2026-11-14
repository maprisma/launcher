import 'dart:convert';
import 'dart:io';
import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';

void main(List<String> args) {
  final home = args[0], id = args[1];
  final session = Session(
    environment: {
      'HOME': home,
      'XDG_CONFIG_HOME': '$home/config',
      'XDG_STATE_HOME': '$home/state',
    },
  );
  for (var i = 0; i < 80; i++) {
    if (id == 'a') {
      writeAiChoice(session, i.isEven ? 'auto' : 'claude');
    } else {
      // An independent Settings-style key writer, using exactly the shared protocol.
      Posix.instance.withFlock('${aiSettingsDir(session)}/settings.lock', () {
        final data = {...readSharedObject(session)!, 'peer': i};
        final tmp = '${aiSettingsDir(session)}/.peer.$pid.$i';
        if (!Posix.instance.writeNewPrivate(tmp, utf8.encode(jsonEncode(data))))
          throw StateError('write');
        File(tmp).renameSync(sharedAiFile(session));
      });
    }
    appendAskAiLog(
      session,
      op: '$id-$i',
      app: 'launcher',
      action: 'launcher.hide',
      target: id,
      result: 'done',
    );
  }
}
