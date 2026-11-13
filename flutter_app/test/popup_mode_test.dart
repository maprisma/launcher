import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_launcher/main.dart';

/// Popup mode needs Hyprland (the core's window.popup places and sizes it);
/// on COSMIC and KDE the Launcher stays a normal, decorated window.
void main() {
  test('popup only where Hyprland can place it', () {
    const omarchy = {'desktop': 'omarchy', 'hyprland': true};
    const hyprland = {'desktop': 'generic', 'hyprland': true};
    const kde = {'desktop': 'kde', 'hyprland': false};
    const cosmic = {'desktop': 'cosmic', 'hyprland': false};
    for (final look in [omarchy, hyprland]) {
      expect(isPopup({}, look), isTrue);
      expect(isPopup({'window_mode': 'popup'}, look), isTrue);
      expect(isPopup({'window_mode': 'window'}, look), isFalse);
    }
    for (final look in [kde, cosmic]) {
      expect(popupPossible(look), isFalse);
      expect(isPopup({}, look), isFalse);
      // settings saved on Hyprland (shared home) fall back here
      expect(isPopup({'window_mode': 'popup'}, look), isFalse);
    }
  });
}
