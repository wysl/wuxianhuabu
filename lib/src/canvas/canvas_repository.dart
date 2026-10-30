import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'canvas_document.dart';

/// Persists canvases as one JSON document each.
///
/// JSON rather than a database: a canvas is a single bounded document written on
/// a debounce, so an atomic rename gives crash safety for free while avoiding a
/// native SQLite dependency on two desktop platforms.
class CanvasRepository {
  CanvasRepository({this.overridesDirectory});

  final Directory? overridesDirectory;

  Future<Directory> _directory() async {
    final base = overridesDirectory ?? await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/canvases');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<File> _fileFor(String id) async {
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${(await _directory()).path}/$safe.json');
  }

  /// Writes atomically so a crash mid-write leaves the previous document intact.
  Future<void> save(CanvasDocument document) async {
    final file = await _fileFor(document.id);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(document.toJson()),
      flush: true,
    );
    if (file.existsSync()) await file.delete();
    await temp.rename(file.path);
  }

  Future<CanvasDocument?> load(String id) async {
    final file = await _fileFor(id);
    if (!file.existsSync()) return null;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return null;
      return CanvasDocument.fromJson(raw.cast<String, Object?>());
    } on Object {
      // A corrupt document must not prevent the app from opening.
      return null;
    }
  }

  /// Every stored canvas, newest first.
  Future<List<CanvasDocument>> list() async {
    final dir = await _directory();
    final documents = <CanvasDocument>[];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final raw = jsonDecode(await entity.readAsString());
        if (raw is Map) {
          documents.add(CanvasDocument.fromJson(raw.cast<String, Object?>()));
        }
      } on Object {
        continue;
      }
    }
    documents.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return documents;
  }

  Future<void> delete(String id) async {
    final file = await _fileFor(id);
    if (file.existsSync()) await file.delete();
  }
}

/// Debounced writer.
///
/// Dragging a node emits dozens of position updates per second; writing each
/// would make the disk the bottleneck of the drag. [flush] exists so a
/// deliberate action (switching canvas, closing the window) forces a write.
class CanvasAutosave {
  CanvasAutosave(this.repository, {this.delay = const Duration(milliseconds: 400)});

  final CanvasRepository repository;
  final Duration delay;
  Timer? _timer;
  CanvasDocument? _pending;

  void schedule(CanvasDocument document) {
    _pending = document;
    _timer?.cancel();
    _timer = Timer(delay, () => flush());
  }

  Future<void> flush() async {
    final document = _pending;
    if (document == null) return;
    _pending = null;
    _timer?.cancel();
    _timer = null;
    await repository.save(document);
  }

  void dispose() => _timer?.cancel();
}
