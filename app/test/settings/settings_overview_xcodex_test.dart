// The settings hub's overview card on a phone with the on-device runtime that
// is still signed out (no DeepSeek account, no key): the card no longer offers
// the DeepSeek sign-in, it offers the xcodex account entry and opens the remote
// hosts screen where the xcodex device sign-in and QR pairing live.
//
//   flutter test test/settings/settings_overview_xcodex_test.dart

import 'package:dsh_app/remote/relay/relay_backend.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/account_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../account/support.dart' show FixedAccount;
import '../phone/support.dart' show FixedActiveHost, FixedHosts;
import '../shell/golden_harness.dart';

const _bundled = 'r5-dsh0.2.1-rc.2-node24.22.1-ubuntu24.04.5-b3f6c96ee2f2';
const _missing = RuntimeStatus(phase: RuntimePhase.notInstalled, bundledVersion: _bundled, abi: 'arm64-v8a');

/// A relay (xcodex) account frozen at a given state.
class _FixedRelayAccount extends RelayAccountController {
  _FixedRelayAccount(this.initial);

  final RelayAccountState initial;

  @override
  Future<RelayAccountState> build() async => initial;
}

List<Override> _overrides({
  RuntimeStatus runtime = _missing,
  HostRef host = HostRef.local,
  HostLinkPhase link = HostLinkPhase.connected,
  AppSettings settings = const AppSettings(loaded: true),
  RelayAccountState? relay,
}) => [
  localRuntimeProvider.overrideWith(() => FakeRuntime(LocalRuntimeState(loaded: true, status: runtime))),
  settingsProvider.overrideWith(() => FakeSettings(settings)),
  accountProvider.overrideWith(() => FixedAccount(const AccountState(phase: AccountPhase.signedOut))),
  activeHostProvider.overrideWith(() => FixedActiveHost(host)),
  hostsProvider.overrideWith(FixedHosts.new),
  hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(HostLinkStatus(link))),
  networkKicksProvider.overrideWithValue(const Stream.empty()),
  secretStoreProvider.overrideWithValue(MemorySecretStore()),
  if (relay != null) relayAccountProvider.overrideWith(() => _FixedRelayAccount(relay)),
];

Future<void> _pump(WidgetTester tester, List<Override> overrides) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: const Scaffold(body: SettingsOverview()),
      brightness: Brightness.light,
      overrides: overrides,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('local, signed out: the card offers xcodex, not DeepSeek', (tester) async {
    await _pump(tester, _overrides());
    expect(find.text('登录 xcodex 账号'), findsOneWidget);
    expect(find.text('登录 DeepSeek 账号'), findsNothing);
    expect(find.text('或填写 API Key'), findsNothing);
    expect(find.text('使用浏览器授权登录'), findsOneWidget);
  });

  testWidgets('local, signed out: tapping opens the remote hosts screen', (tester) async {
    await _pump(tester, _overrides());
    await tester.tap(find.text('登录 xcodex 账号'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(RemoteScreen), findsOneWidget);
  });

  testWidgets('runtime installed, local, signed out: still the xcodex entry', (tester) async {
    await _pump(tester, _overrides(runtime: runningStatus));
    expect(find.text('登录 xcodex 账号'), findsOneWidget);
    expect(find.text('登录 DeepSeek 账号'), findsNothing);
  });

  testWidgets('xcodex signed in: the card shows the account, not a sign-in entry', (tester) async {
    await _pump(
      tester,
      _overrides(
        relay: const RelayAccountState(available: true, server: 'agent.xcodex.vip', user: RelayUser(id: 'xc1', displayName: 'Joseph')),
      ),
    );
    expect(find.text('登录 xcodex 账号'), findsNothing);
    expect(find.text('使用浏览器授权登录'), findsNothing);
    expect(find.text('Joseph'), findsOneWidget);
  });
}

