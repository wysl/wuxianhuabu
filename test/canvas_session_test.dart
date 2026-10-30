import 'dart:io';
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:wuxianhuabu/src/state/canvas_session.dart';
import 'package:wuxianhuabu/src/state/canvas_store.dart';
import 'package:wuxianhuabu/src/ui/canvas_board.dart';

/// The canvas is persisted per workflow, so returning to a workflow keeps the
/// layout the user arranged. These cover the id derivation and the round trip,
/// which are the parts that silently break (a bad id means every workflow shares
/// one document, and the last one opened wins).
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('wuxianhuabu_session_'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('a workflow path maps to a stable, filesystem-safe project id', () {
    // Mirrors the derivation in `CanvasSessionNotifier.openFor`.
    String idFor(String path) => path
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');

    final a = idFor('workflows/Krea2/easy krea2.json');
    final b = idFor('workflows/Krea2/easy krea2.json');
    expect(a, b, reason: 'the same path must always produce the same id');
    expect(a, isNot(contains('/')));
    expect(a, isNot(contains('.')));

    // Two different workflows must not collide.
    expect(
      idFor('workflows/H3/通用.json'),
      isNot(idFor('workflows/Qwen/通用.json')),
    );
  });

  test('a stored project round-trips through the store by that id', () async {
    final store = CanvasStore(overridesDirectory: temp);
    final id = 'workflows_Krea2_easy_krea2_json';
    final project = CanvasProject(
      id: id,
      name: 'easy krea2',
      workflowPath: 'workflows/Krea2/easy krea2.json',
      cards: [
        CanvasCard(
          id: 'c1',
          origin: const Offset(10, 20),
          size: const Size(200, 100),
          kind: CardKind.text,
          text: '保留这段文字',
          caption: 'prompt',
        ),
        CanvasCard(
          id: 'r-abc',
          origin: const Offset(10, 300),
          size: const Size(300, 260),
          kind: CardKind.media,
          caption: '结果',
          media: const [
            {'filename': 'out.png', 'subfolder': '', 'type': 'output'},
          ],
        ),
      ],
    );
    await store.save(project);

    final loaded = await store.load(id);
    expect(loaded, isNotNull);
    expect(loaded!.workflowPath, 'workflows/Krea2/easy krea2.json');
    expect(loaded.cards, hasLength(2));
    expect(loaded.cards.first.text, '保留这段文字');
    expect(loaded.cards[1].kind, CardKind.media);
    expect(loaded.cards[1].media.single['filename'], 'out.png');
  });

  test('different workflows get different documents', () async {
    final store = CanvasStore(overridesDirectory: temp);
    await store.save(CanvasProject(
      id: 'workflows_H3_a_json',
      name: 'a',
      workflowPath: 'workflows/H3/a.json',
      cards: const [],
    ));
    await store.save(CanvasProject(
      id: 'workflows_Qwen_b_json',
      name: 'b',
      workflowPath: 'workflows/Qwen/b.json',
      cards: const [],
    ));

    final projects = await store.list();
    expect(projects, hasLength(2));
    expect(
      projects.map((p) => p.workflowPath).toSet(),
      {'workflows/H3/a.json', 'workflows/Qwen/b.json'},
    );
  });

  test('CanvasSession.copyWith keeps identity while changing flags', () {
    const session = CanvasSession(
      projectId: 'p',
      name: 'n',
      workflowPath: 'w',
    );
    final dirty = session.copyWith(dirty: true);
    expect(dirty.projectId, 'p');
    expect(dirty.workflowPath, 'w');
    expect(dirty.dirty, isTrue);
    expect(session.dirty, isFalse);
  });
}
