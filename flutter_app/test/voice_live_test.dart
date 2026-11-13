// Live check against the installed maprisma-voice (MAPRISMA_LIVE_TESTS=1 only): a 1 s session
// that is cancelled, so nothing is transcribed: listening → cancelled → closed.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_launcher/voice_input.dart';

void main() {
  final live = Platform.environment['MAPRISMA_LIVE_TESTS'] == '1';
  test('real service: listening, then cancelled and closed', () async {
    VoiceInput.environment = Map.of(Platform.environment)..remove('FLUTTER_TEST');
    final status = await VoiceInput.available(fresh: true);
    expect(status.usable, isTrue, reason: status.message);
    final s = await VoiceInput.start(appId: 'com.maprisma.Launcher');
    final states = <String>[];
    final done = Completer<String>();
    var levels = 0;
    Timer? stop;
    s.events.listen((e) {
      switch (e) {
        case VoiceStateEvent(:final state):
          states.add(state);
          if (state == 'listening') stop = Timer(const Duration(seconds: 1), s.cancel);
        case VoiceLevel():
          levels++;
        case VoiceError(:final code, :final message):
          states.add('error $code: $message');
        case VoiceClosed(:final reason):
          done.complete(reason);
        default:
      }
    });
    final reason = await done.future.timeout(const Duration(seconds: 20));
    stop?.cancel();
    s.dispose();
    // ignore: avoid_print
    print('states $states, $levels level events, closed: $reason, exit ${await s.exitCode}');
    expect(states.first, 'listening');
    expect(states.last, 'cancelled');
    expect(reason, 'cancelled');
  }, skip: live ? false : 'set MAPRISMA_LIVE_TESTS=1');
}
