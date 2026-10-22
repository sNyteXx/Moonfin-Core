import 'package:server_core/server_core.dart';
import 'package:test/test.dart';

void main() {
  test('display preferences preserve nullable custom values on roundtrip', () {
    const customPrefs = <String, String?>{
      'tvhome': null,
      'dashboardTheme': null,
      'skipForwardLength': '30000',
      'empty': '',
    };

    final prefs = DisplayPreferences.fromJson({
      'Id': 'preferences-1',
      'CustomPrefs': customPrefs,
    });

    expect(prefs.customPrefs, customPrefs);
    expect(prefs.toJson()['CustomPrefs'], customPrefs);
  });

  test('absent or null custom preferences remain an empty map', () {
    for (final json in <Map<String, dynamic>>[
      {'Id': 'preferences-1'},
      {'Id': 'preferences-1', 'CustomPrefs': null},
    ]) {
      final prefs = DisplayPreferences.fromJson(json);

      expect(prefs.customPrefs, isEmpty);
      expect(prefs.toJson()['CustomPrefs'], isEmpty);
    }
  });
}
