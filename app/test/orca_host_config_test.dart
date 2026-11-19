import 'package:dsh_app/remote/orca/orca_host_config.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  late SharedPreferencesStorePlatform previousPrefs;

  setUp(() {
    previousPrefs = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  });
  tearDown(() => SharedPreferencesStorePlatform.instance = previousPrefs);

  test('HostRef.orca 编解码往返不丢字段', () {
    final r = HostRef.orca('o1');
    expect(HostRef.decode(r.encode()), r);
    expect(r.kind, HostKind.orca);
  });

  test('pairingCode 走 SecretStore，endpoint 不进 secret 存储', () async {
    final container = ProviderContainer(overrides: [
      secretStoreProvider.overrideWithValue(MemorySecretStore()),
    ]);
    addTearDown(container.dispose);
    final secretStore = container.read(secretStoreProvider) as MemorySecretStore;
    final controller = container.read(orcaHostsProvider.notifier);
    await controller.ready;

    await controller.save(
      OrcaHostConfig(id: 'o1', endpoint: 'ws://127.0.0.1:6769', name: '测试机'),
      pairingCode: 'code-1',
    );
    final loaded = await controller.load('o1');
    expect(loaded, isNotNull);
    expect(loaded!.endpoint, 'ws://127.0.0.1:6769');
    expect(loaded.name, '测试机');
    expect(loaded.pairingCode, 'code-1');
    // endpoint/name live in prefs, pairingCode only in the secret store.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(OrcaHostConfig.prefsKey), isNotNull);
    expect(secretStore.values[OrcaHostConfig.pairingCodeKey('o1')], 'code-1');
    expect(secretStore.values.containsKey(OrcaHostConfig.prefsKey), isFalse);

    await controller.remove('o1');
    expect(await controller.load('o1'), isNull);
    expect(secretStore.values[OrcaHostConfig.pairingCodeKey('o1')], isNull);
  });

  test('hostLabel(HostKind.orca, name) 返回 l10n 文案', () {
    expect(hostLabel(HostKind.orca, '我的 Mac'), isNotEmpty);
  });
}
