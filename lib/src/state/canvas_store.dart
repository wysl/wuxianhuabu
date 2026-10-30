import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset, Size;

import 'package:path_provider/path_provider.dart';

import '../ui/canvas_board.dart';

/// Persists canvas projects as JSON files.
///
/// JSON rather than SQLite on purpose: a canvas project is a few thousand small
/// objects written on a debounce, so a single document with an atomic rename
/// gives crash safety for free, while a database would add a native dependency
/// that has to build on both Windows and macOS.
class CanvasStore {
  CanvasStore({this.overridesDirectory});

  final Directory? overridesDirectory;

  Future<Directory> _directory() async {
    final base = overridesDirectory ?? await getApplicationSupportDirectory();
    // Same reasoning as `ProfileStore`: the support directory is already
    // app-scoped, so projects live in a named subfolder rather than a nested
    // copy of the app name.
    final dir = Directory('${base.path}/projects');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<File> _fileFor(String projectId) async {
    final safe = projectId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${(await _directory()).path}/$safe.json');
  }

  /// Writes atomically: a crash mid-write leaves the previous file intact
  /// rather than a truncated one.
  Future<void> save(CanvasProject project) async {
    final file = await _fileFor(project.id);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(project.toJson()),
      flush: true,
    );
    if (file.existsSync()) await file.delete();
    await temp.rename(file.path);
  }

  Future<CanvasProject?> load(String projectId) async {
    final file = await _fileFor(projectId);
    if (!file.existsSync()) return null;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return null;
      return CanvasProject.fromJson(raw.cast<String, Object?>());
    } on Object {
      return null;
    }
  }

  Future<List<CanvasProject>> list() async {
    final dir = await _directory();
    final projects = <CanvasProject>[];
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final raw = jsonDecode(await entity.readAsString());
        if (raw is Map) {
          projects.add(CanvasProject.fromJson(raw.cast<String, Object?>()));
        }
      } on Object {
        continue;
      }
    }
    projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return projects;
  }

  Future<void> delete(String projectId) async {
    final file = await _fileFor(projectId);
    if (file.existsSync()) await file.delete();
  }
}

/// A saved canvas.
class CanvasProject {
  CanvasProject({
    required this.id,
    required this.name,
    required this.cards,
    required this.workflowPath,
    this.serverUrl,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String name;
  final List<CanvasCard> cards;

  /// The workflow this canvas was seeded from, for provenance.
  final String workflowPath;

  /// Which instance the cards came from: the same workflow on a different
  /// server produces different results, so the association matters.
  final String? serverUrl;

  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'workflow_path': workflowPath,
        if (serverUrl != null) 'server_url': serverUrl,
        'updated_at': updatedAt.toIso8601String(),
        'cards': [
          for (final card in cards)
            {
              'id': card.id,
              'x': card.origin.dx,
              'y': card.origin.dy,
              'width': card.size.width,
              'height': card.size.height,
              'kind': card.kind.name,
              'text': card.text,
              'caption': card.caption,
              'media': card.media,
            },
        ],
      };

  static CanvasProject fromJson(Map<String, Object?> raw) => CanvasProject(
        id: '${raw['id']}',
        name: '${raw['name'] ?? raw['id']}',
        workflowPath: '${raw['workflow_path'] ?? ''}',
        serverUrl: raw['server_url'] as String?,
        updatedAt: DateTime.tryParse('${raw['updated_at']}') ?? DateTime.now(),
        cards: [
          for (final entry in (raw['cards'] as List?) ?? const [])
            if (entry is Map)
              CanvasCard(
                id: '${entry['id']}',
                origin: Offset(
                  (entry['x'] as num?)?.toDouble() ?? 0,
                  (entry['y'] as num?)?.toDouble() ?? 0,
                ),
                size: Size(
                  (entry['width'] as num?)?.toDouble() ?? 240,
                  (entry['height'] as num?)?.toDouble() ?? 120,
                ),
                kind: CardKind.values.firstWhere(
                  (kind) => kind.name == entry['kind'],
                  orElse: () => CardKind.text,
                ),
                text: '${entry['text'] ?? ''}',
                caption: '${entry['caption'] ?? ''}',
                media: [
                  for (final media in (entry['media'] as List?) ?? const [])
                    if (media is Map)
                      {
                        for (final field in media.entries)
                          '${field.key}': '${field.value}',
                      },
                ],
              ),
        ],
      );
}

/// Saves a canvas on a debounce.
///
/// Dragging a card fires dozens of updates per second; writing each would make
/// the disk the bottleneck of the drag. [flush] exists so a deliberate action
/// (closing the app) can force a write.
class CanvasAutosave {
  CanvasAutosave(this.store, {this.delay = const Duration(milliseconds: 400)});

  final CanvasStore store;
  final Duration delay;
  Timer? _timer;
  CanvasProject? _pending;

  void schedule(CanvasProject project) {
    _pending = project;
    _timer?.cancel();
    _timer = Timer(delay, () => flush());
  }

  Future<void> flush() async {
    final project = _pending;
    if (project == null) return;
    _pending = null;
    _timer?.cancel();
    _timer = null;
    await store.save(project);
  }

  void dispose() {
    _timer?.cancel();
  }
}
