import 'dart:convert';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:server_box/core/extension/context/locale.dart';
import 'package:server_box/data/res/store.dart';
import 'package:server_box/data/store/history.dart';
import 'package:server_box/data/store/private_key.dart';
import 'package:server_box/data/store/server.dart';
import 'package:server_box/data/store/server_dist.dart';
import 'package:server_box/data/store/setting.dart';
import 'package:server_box/generated/l10n/l10n.dart';
import 'package:server_box/view/page/setting/entry.dart';
import 'package:server_box/view/page/ssh/page/page.dart';
import 'package:server_box/view/page/ssh/tab.dart';

import '../helpers/spi_fixture.dart';
import '../helpers/test_db.dart';

/// What a fresh start shows.
///
/// Terminals used to be reopened from the tab set the last run left behind,
/// which connected to every server that was on screen when the process went
/// away. They no longer are: a fresh start is the device list, and connecting
/// is a tap on it. Nothing reads the saved set any more, and nothing writes
/// it either — the store property stays, because a database column outlives
/// the feature that used it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('server-box-sshtab-');
    await openTestDb();
    // In memory: this tree writes as it builds, and a test has no
    // business leaving a database behind.
    getIt.registerSingleton<SettingStore>(SettingStore('setting_test'));
    // The rail draws each server's distribution mark, which reads this.
    getIt.registerSingleton<ServerDistStore>(ServerDistStore());
    getIt.registerSingleton<ServerStore>(ServerStore());
    getIt.registerSingleton<PrivateKeyStore>(PrivateKeyStore());
    getIt.registerSingleton<HistoryStore>(HistoryStore('history_test'));
  });

  tearDown(() async {
    await getIt.reset();
    await SqliteDb.close();
    await tempDir.delete(recursive: true);
  });

  /// The tab set as the store holds it.
  List<Map<String, dynamic>> stored() {
    final saved = Stores.history.sshTabs.fetch();
    if (saved.isEmpty) return const [];
    return [
      for (final e in jsonDecode(saved) as List)
        if (e is Map) e.cast<String, dynamic>(),
    ];
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // In a Scaffold, as the home page hosts it: the tab strip's buttons
          // are `InkWell`s and want a Material above them.
          home: const Scaffold(body: SSHTabPage()),
        ),
      ),
    );
    // Counted out: a page holding terminals always has something scheduled.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  test('a server rename rewrites saved tab ids', () {
    Stores.history.sshTabs.put(
      jsonEncode([
        {'sourceId': 'server-old', 'tmuxSession': 'work'},
        {'serverId': 'server-old'},
      ]),
    );

    Stores.history.renameSshServer('server-old', 'server-new');

    expect(stored().map((entry) => entry['sourceId'] ?? entry['serverId']), [
      'server-new',
      'server-new',
    ]);
  });

  testWidgets('a saved tab set is not reopened on a fresh start', (tester) async {
    // The one this exists for. The last run died with terminals on screen —
    // killed, swiped away, the ordinary way a phone app ends — and opening
    // the app again must show the device list, not connect to whatever was
    // open. A terminal built is a terminal started, so none is built.
    Stores.server.put(spiFixture(id: 'srv-1', name: 'web', ip: 'h', user: 'u'));
    Stores.history.sshTabs.put(
      jsonEncode([
        {'sourceId': 'srv-1'},
        {'sourceId': 'srv-1', 'tmuxSession': 'work', 'tmuxWindow': 3},
      ]),
    );

    await pump(tester);

    expect(find.byType(SSHPage), findsNothing);
    // And nothing rewrites what it did not read.
    expect(
      stored().map((t) => t['sourceId']),
      ['srv-1', 'srv-1'],
    );
  });

  testWidgets('terminal settings are editable from the terminal page', (
    tester,
  ) async {
    await pump(tester);

    expect(
      find.byKey(const ValueKey('terminal-settings')),
      findsOneWidget,
      reason: 'a split terminal page should not show the action twice',
    );
    await tester.tap(
      find.byKey(const ValueKey('terminal-settings')).hitTestable().first,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(SettingsSectionPage), findsOneWidget);
    expect(find.text(l10n.wakeLock), findsOneWidget);

    final wakeLock = find.ancestor(
      of: find.text(l10n.wakeLock),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: wakeLock, matching: find.byType(Switch)),
    );
    await tester.pump();

    expect(Stores.setting.sshWakeLock.fetch(), isFalse);
  });
}
