import 'dart:io';
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:wuxianhuabu/src/state/canvas_store.dart';
import 'package:wuxianhuabu/src/ui/canvas_board.dart';

void main() {
  late Directory temp;
  late CanvasStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('wuxianhuabu_canvas_');
    store = CanvasStore(overridesDirectory: temp);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  CanvasProject sample({String id = 'p1'}) => CanvasProject(
        id: id,
        name: '示例画布',
        workflowPath: 'workflows/Krea2/easy krea2.json',
        serverUrl: 'http://127.0.0.1:8188',
        cards: [
          CanvasCard(
            id: 'c1',
            origin: const Offset(12, 34),
            size: const Size(240, 160),
            kind: CardKind.text,
            text: '一只在雨夜行走的猫',
            caption: '提示词',
          ),
          CanvasCard(
            id: 'c2',
            origin: const Offset(-5.5, 90.25),
            size: const Size(320, 200),
            kind: CardKind.media,
            media: const [
              {'filename': 'a.png', 'subfolder': '', 'type': 'output'},
            ],
            caption: '结果',
          ),
        ],
      );

  test('saves and reloads a project', () async {
    await store.save(sample());
    final loaded = await store.load('p1');
    expect(loaded, isNotNull);
    expect(loaded!.name, '示例画布');
    expect(loaded.cards, hasLength(2));
    expect(loaded.cards.first.text, '一只在雨夜行走的猫');
    // Geometry round-trips exactly, including negative and fractional values.
    expect(loaded.cards[1].origin, const Offset(-5.5, 90.25));
    expect(loaded.cards[1].size, const Size(320, 200));
    expect(loaded.cards[1].kind, CardKind.media);
    expect(loaded.cards[1].media.single['filename'], 'a.png');
  });

  test('writes atomically, leaving no temp file behind', () async {
    await store.save(sample());
    final files = temp
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path)
        .toList();
    expect(files.where((p) => p.endsWith('.tmp')), isEmpty);
    expect(files.where((p) => p.endsWith('p1.json')), hasLength(1));
  });

  test('a corrupt file loads as null instead of throwing', () async {
    await store.save(sample());
    final file = File('${temp.path}/projects/p1.json');
    file.writeAsStringSync('{ not json');
    expect(await store.load('p1'), isNull);
  });

  test('lists projects newest first', () async {
    await store.save(sample(id: 'old'));
    await Future<void>.delayed(const Duration(milliseconds: 15));
    await store.save(sample(id: 'new'));
    final projects = await store.list();
    expect(projects.map((p) => p.id), containsAll(['old', 'new']));
    expect(projects.first.id, 'new');
  });

  test('deletes a project', () async {
    await store.save(sample());
    await store.delete('p1');
    expect(await store.load('p1'), isNull);
  });

  test('autosave coalesces rapid updates into one write', () async {
    final autosave = CanvasAutosave(
      store,
      delay: const Duration(milliseconds: 60),
    );
    for (var i = 0; i < 20; i += 1) {
      autosave.schedule(sample());
    }
    // Nothing written yet: the debounce has not elapsed.
    expect(await store.load('p1'), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(await store.load('p1'), isNotNull);
    autosave.dispose();
  });

  test('flush writes immediately', () async {
    final autosave = CanvasAutosave(
      store,
      delay: const Duration(seconds: 30),
    );
    autosave.schedule(sample());
    await autosave.flush();
    expect(await store.load('p1'), isNotNull);
    autosave.dispose();
  });
}
