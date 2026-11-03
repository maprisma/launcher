import 'package:maprisma_launcher_core/maprisma_launcher_core.dart';
import 'package:test/test.dart';

void main() {
  test('the popup: centred in the free area under the bar, kept inside it', () {
    final monitors = [
      {'x': 0, 'y': 0, 'width': 3840, 'height': 2160, 'scale': 2, 'focused': true, 'reserved': [0, 30, 0, 0]},
    ];
    final clients = [
      {'pid': 7, 'address': '0x55aa'},
      {'pid': 8, 'address': 'bad'},
    ];
    final g = popupGeometry(monitors, clients, 7, 1100, 760)!;
    // Logical 1920x1080, 30 px bar: free 1920x1050.
    expect([g.address, g.width, g.height, g.x, g.y], ['0x55aa', 1100, 760, 410, 30 + 145]);
    final big = popupGeometry(monitors, clients, 7, 5000, 5000)!;
    expect([big.width, big.height], [1900, 1030]);
    expect(popupGeometry(monitors, clients, 8, 100, 100), isNull); // no valid address
    expect(popupGeometry(monitors, clients, 9, 100, 100), isNull);
  });
}
