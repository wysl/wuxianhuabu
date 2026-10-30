import 'dart:io';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:wuxianhuabu/src/canvas/canvas_document.dart';
import 'package:wuxianhuabu/src/canvas/canvas_repository.dart';

/// The canvas is the product, so its persistence and its document model are the
/// things that must not break: a lost board is lost work.
void main() {
  group('document round trip', () {
    test('every node kind survives JSON, including its type-specific data', () {
      final document = CanvasDocument(
        id: 'c1',
        title: '我的画布',
        nodes: [
          CanvasNode(
            id: 'n-text',
            kind: CanvasNodeKind.text,
            position: const Offset(10, 20),
            size: const Size(340, 240),
            content: '一个古装帅哥，沈三殊',
          ),
          CanvasNode(
            id: 'n-image',
            kind: CanvasNodeKind.image,
            position: const Offset(400, 20),
            size: const Size(340, 240),
            status: NodeStatus.success,
            media: const [
              MediaRef(filename: 'out_0001.png', type: 'output'),
            ],
          ),
          CanvasNode(
            id: 'n-config',
            kind: CanvasNodeKind.config,
            position: const Offset(200, 300),
            size: const Size(340, 240),
            metadata: {
              'prompt': '生成一个古装帅哥',
              'mode': GenerationMode.image.name,
              'count': 3,
              'workflow_path': 'workflows/Qwen/a.json',
              'params': {'984.seed': 42},
            },
          ),
        ],
        edges: const [
          CanvasEdge(id: 'e1', fromNodeId: 'n-text', toNodeId: 'n-config'),
        ],
        scale: 1.75,
        offset: const Offset(-120, 64),
      );

      final restored = CanvasDocument.fromJson(document.toJson());

      expect(restored.title, '我的画布');
      expect(restored.nodes, hasLength(3));
      expect(restored.edges.single.fromNodeId, 'n-text');
      expect(restored.scale, 1.75);
      expect(restored.offset, const Offset(-120, 64));

      final text = restored.nodeById('n-text')!;
      expect(text.kind, CanvasNodeKind.text);
      expect(text.content, '一个古装帅哥，沈三殊');

      final image = restored.nodeById('n-image')!;
      expect(image.status, NodeStatus.success);
      expect(image.media.single.filename, 'out_0001.png');

      final config = restored.nodeById('n-config')!;
      expect(config.kind, CanvasNodeKind.config);
      expect(config.prompt, '生成一个古装帅哥');
      expect(config.mode, GenerationMode.image);
      expect(config.count, 3);
      expect(config.workflowPath, 'workflows/Qwen/a.json');
      expect(config.params['984.seed'], 42);
    });

    test('a node keeps its own geometry, not the kind default', () {
      final node = CanvasNode(
        id: 'n',
        kind: CanvasNodeKind.image,
        position: const Offset(999, -50),
        size: const Size(500, 400),
      );
      final restored = CanvasNode.fromJson(node.toJson());
      expect(restored.position, const Offset(999, -50));
      expect(restored.size, const Size(500, 400));
      expect(restored.rect, Rect.fromLTWH(999, -50, 500, 400));
    });

    test('an unknown kind degrades to text rather than throwing', () {
      // A canvas saved by a newer build must still open.
      final restored = CanvasNode.fromJson({
        'id': 'x',
        'kind': 'some-plugin-node',
        'x': 0,
        'y': 0,
        'width': 100,
        'height': 100,
      });
      expect(restored.kind, CanvasNodeKind.text);
    });

    test('count is clamped to a sane range', () {
      final node = CanvasNode(
        id: 'n',
        kind: CanvasNodeKind.config,
        position: Offset.zero,
        size: const Size(340, 240),
      );
      node.count = 99;
      expect(node.count, 8);
      node.count = 0;
      expect(node.count, 1);
    });
  });

  group('repository', () {
    late Directory temp;
    late CanvasRepository repository;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('wuxianhuabu_canvas_');
      repository = CanvasRepository(overridesDirectory: temp);
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    CanvasDocument sample(String id, {String title = '画布'}) => CanvasDocument(
          id: id,
          title: title,
          nodes: [
            CanvasNode(
              id: 'n1',
              kind: CanvasNodeKind.text,
              position: const Offset(5, 5),
              size: const Size(300, 200),
              content: '内容 $id',
            ),
          ],
          edges: const [],
        );

    test('saves and loads by id', () async {
      await repository.save(sample('c1', title: '第一个'));
      final loaded = await repository.load('c1');
      expect(loaded, isNotNull);
      expect(loaded!.title, '第一个');
      expect(loaded.nodes.single.content, '内容 c1');
    });

    test('writes atomically, leaving no temp file', () async {
      await repository.save(sample('c1'));
      final files = Directory('${temp.path}/canvases').listSync();
      for (final entity in files) {
        expect(entity.path.endsWith('.tmp'), isFalse);
      }
    });

    test('a missing document loads as null', () async {
      expect(await repository.load('nope'), isNull);
    });

    test('a corrupt document loads as null instead of throwing', () async {
      Directory('${temp.path}/canvases').createSync(recursive: true);
      File('${temp.path}/canvases/bad.json').writeAsStringSync('{not json');
      expect(await repository.load('bad'), isNull);
      // ...and the listing skips it rather than failing wholesale.
      expect(await repository.list(), isEmpty);
    });

    test('lists newest first', () async {
      await repository.save(sample('old'));
      await Future<void>.delayed(const Duration(milliseconds: 15));
      await repository.save(sample('new'));
      final listed = await repository.list();
      expect(listed.map((d) => d.id), ['new', 'old']);
    });

    test('delete removes the document', () async {
      await repository.save(sample('gone'));
      await repository.delete('gone');
      expect(await repository.load('gone'), isNull);
    });

    test('ids with path separators are sanitised, not escaped', () async {
      // A canvas id derived from a workflow path must not create subdirectories.
      await repository.save(sample('workflows/Qwen/a.json'));
      final listed = await repository.list();
      expect(listed, hasLength(1));
      expect(listed.single.id, 'workflows/Qwen/a.json');
    });
  });

  group('autosave', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('wuxianhuabu_autosave_'));
    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('coalesces rapid updates into one write', () async {
      final repository = CanvasRepository(overridesDirectory: temp);
      final autosave = CanvasAutosave(
        repository,
        delay: const Duration(milliseconds: 80),
      );
      for (var i = 0; i < 20; i++) {
        autosave.schedule(
          CanvasDocument(
            id: 'c1',
            nodes: [],
            edges: [],
            title: 'rev $i',
          ),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final loaded = await repository.load('c1');
      // The last scheduled value is the one that landed.
      expect(loaded?.title, 'rev 19');
      autosave.dispose();
    });

    test('flush writes immediately, without waiting for the delay', () async {
      final repository = CanvasRepository(overridesDirectory: temp);
      final autosave = CanvasAutosave(
        repository,
        delay: const Duration(seconds: 30),
      );
      autosave.schedule(
        CanvasDocument(id: 'c2', nodes: [], edges: [], title: 'flush me'),
      );
      await autosave.flush();
      final loaded = await repository.load('c2');
      expect(loaded?.title, 'flush me');
      autosave.dispose();
    });
  });
}
