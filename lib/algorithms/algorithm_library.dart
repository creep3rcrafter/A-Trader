import 'dart:convert';
import 'dart:io';

import '../strategy_api.dart';
import 'imported_definition.dart';
import 'json_algorithm.dart';
import 'native_algorithm.dart';
import 'registry.dart';

/// Each backend/isolate owns its workers; only serializable definitions cross
/// isolate boundaries. IDs are immutable so saved runs retain their algorithm.
class AlgorithmLibrary {
  AlgorithmLibrary(this.directory);
  final Directory directory;
  final List<Map<String, dynamic>> definitions = [];
  final List<TradingStrategy> _algorithms = [];
  bool _importing = false;

  List<Map<String, Object?>> get catalogue => [
    for (var i = 0; i < _algorithms.length; i++)
      {
        'metadata': (_algorithms[i] as ImportedAlgorithmDefinition).toJson(),
        'filename': definitions[i]['filename'],
        'kind': definitions[i]['kind'],
      },
  ];

  Future<void> restore(List<Map<String, dynamic>> saved) async {
    if (_algorithms.isNotEmpty) {
      throw StateError('Algorithm library is already loaded.');
    }
    try {
      for (final item in saved) {
        final definition = Map<String, dynamic>.from(item);
        if (definition['kind'] == 'dart' &&
            !await File(definition['executable'] as String? ?? '').exists()) {
          final workspace = Directory(
            '${directory.path}/restored-${DateTime.now().microsecondsSinceEpoch}',
          );
          definition['executable'] = await compileDartAlgorithm(
            definition['source'] as String,
            workspace,
          );
        }
        final algorithm = await _open(definition);
        definitions.add(definition);
        _algorithms.add(algorithm);
      }
      StrategyRegistry.replaceImported(_algorithms);
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<Map<String, Object?>> importFile(
    String filename,
    String source,
  ) async {
    if (_importing) throw StateError('Another algorithm is being imported.');
    if (utf8.encode(source).length > 1024 * 1024) {
      throw const FormatException('Algorithm files must be smaller than 1 MB.');
    }
    if (source.trim().isEmpty) {
      throw const FormatException('The selected file is empty.');
    }
    final extension = filename.split('.').last.toLowerCase();
    if (!const {'json', 'dart'}.contains(extension)) {
      throw const FormatException('Choose a .json or .dart algorithm file.');
    }
    _importing = true;
    TradingStrategy? algorithm;
    try {
      final definition = <String, dynamic>{
        'filename': filename.split(RegExp(r'[/\\]')).last,
        'source': source,
        'kind': extension,
      };
      if (extension == 'dart') {
        final workspace = Directory(
          '${directory.path}/import-${DateTime.now().microsecondsSinceEpoch}',
        );
        definition['executable'] = await compileDartAlgorithm(
          source,
          workspace,
        );
      }
      algorithm = await _open(definition);
      if (StrategyRegistry.all.any(
        (existing) => existing.id == algorithm!.id,
      )) {
        throw FormatException(
          'Algorithm id "${algorithm.id}" already exists. Give your file a new id before importing it.',
        );
      }
      definition['metadata'] = (algorithm as ImportedAlgorithmDefinition)
          .toJson();
      definitions.add(definition);
      _algorithms.add(algorithm);
      StrategyRegistry.replaceImported(_algorithms);
      return catalogue.last;
    } catch (_) {
      if (algorithm is NativeAlgorithm) await algorithm.close();
      rethrow;
    } finally {
      _importing = false;
    }
  }

  /// Used when a save fails: never report an import that was not persisted.
  Future<void> rollbackLastImport() async {
    final algorithm = _algorithms.removeLast();
    definitions.removeLast();
    if (algorithm is NativeAlgorithm) await algorithm.close();
    StrategyRegistry.replaceImported(_algorithms);
  }

  static Future<TradingStrategy> _open(Map<String, dynamic> definition) async {
    if (definition['kind'] == 'dart') return NativeAlgorithm.open(definition);
    if (definition['kind'] != 'json') {
      throw const FormatException('Unknown saved algorithm type.');
    }
    final decoded = jsonDecode(definition['source'] as String);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('The algorithm JSON must be an object.');
    }
    return JsonAlgorithm(decoded);
  }

  Future<void> close() async {
    for (final algorithm in _algorithms) {
      if (algorithm is NativeAlgorithm) await algorithm.close();
    }
    _algorithms.clear();
    definitions.clear();
  }
}
