import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/read_list_cache.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(loadTestFonts);

  testWidgets('managed running turn retains draft and keeps Stop available', (tester) async {
    final input = TextEditingController(text: 'keep my draft');
    addTearDown(input.dispose);
    var sends = 0;
    var stops = 0;
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Composer(
            controller: input,
            running: true,
            connected: true,
            allowWhileRunning: false,
            onSend: () => sends++,
            onStop: () => stops++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The button remains Stop even with nonempty text; stopping never sends it.
    final stop = find.bySemanticsLabel(RegExp('停止|Stop'));
    expect(stop, findsWidgets);
    await tester.tap(stop.last);
    await tester.pump();
    expect(stops, 1);
    expect(sends, 0);
    expect(input.text, 'keep my draft');
  });

  testWidgets('managed picker only offers its session catalog', (tester) async {
    const selection = ModelSelection(provider: 'codex', model: 'gpt-test');
    final catalog = ModelCatalog(
      defaultSelection: selection,
      routableProviders: const ['codex'],
      groups: const [
        ProviderGroup('codex', 'Codex', [ModelInfo(provider: 'codex', id: 'gpt-test', name: 'Only this Codex model')]),
      ],
      failures: const [],
    );
    ModelSelection? picked;
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showModelSheet(
                context,
                current: selection,
                managedSessionId: 'managed-S',
                onSelected: (value) => picked = value,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
        overrides: [
          modelSelectionScopeProvider.overrideWithValue(Object()),
          managedModelCatalogProvider('managed-S').overrideWith((ref) async => catalog),
          managedModelListViewProvider('managed-S').overrideWithValue(ReadListView(value: catalog)),
          modelCatalogProvider.overrideWith((ref) => throw StateError('must not read global catalog')),
        ],
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text(shortModelName('Only this Codex model')), findsOneWidget);
    expect(find.byType(ManageModelsLink), findsNothing);
    await tester.tap(find.text(shortModelName('Only this Codex model')));
    await tester.pumpAndSettle();
    expect(picked?.provider, 'codex');
    expect(picked?.model, 'gpt-test');
  });
}
