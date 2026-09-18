import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/pairing_host/mobile_grid_reader.dart';

/// What a paired phone is told about one grid.
///
/// The fields left *out* are the point: `credentials.toml` holds a bearer token
/// for every grid, and an engine record holds a process id and the address the
/// engine listens on. None of the three may reach a phone.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('grid-engines'));
  tearDown(() => root.deleteSync(recursive: true));

  void writeEngine(String name, Map<String, Object?> record) =>
      File('${root.path}/$name.json').writeAsStringSync(jsonEncode(record));

  test('lists an engine by what it serves, never by where it listens — the '
      'endpoint is this machine network layout', () {
    writeEngine('llama', {
      'engine_id': 'llama',
      'grid_id': 'g1',
      'models': ['qwen3-8b'],
      'endpoint_url': 'http://192.168.1.44:8080',
      'pid': 999999999,
    });

    final engines = readGridEngines('g1', runDir: root);

    expect(engines.single.models, ['qwen3-8b']);
    expect(engines.single.toString(), isNot(contains('192.168')));
    expect(engines.single.toString(), isNot(contains('999999999')));
  });

  test('keeps a stopped engine in the list rather than hiding it, because a '
      'record outliving its process is how `grid join` ordinarily ends and a '
      'silent drop reads as "nothing here"', () {
    // A pid that cannot be alive: the probe must come back false without the
    // record vanishing.
    writeEngine('gone', {
      'engine_id': 'gone',
      'grid_id': 'g1',
      'models': ['qwen3-8b'],
      'pid': 999999999,
    });

    final engines = readGridEngines('g1', runDir: root);

    expect(engines, hasLength(1));
    expect(engines.single.running, isFalse);
  });

  test('reads a record with no pid as stopped rather than guessing it is live, '
      'since telling somebody their computer is sharing when it is not is the '
      'lie that matters here', () {
    writeEngine('old', {
      'engine_id': 'old',
      'grid_id': 'g1',
      'models': ['qwen3-8b'],
    });

    expect(readGridEngines('g1', runDir: root).single.running, isFalse);
  });

  test('gathers the models from every engine in a record, not just the flat '
      'field, so a machine serving two shows both', () {
    writeEngine('two', {
      'engine_id': 'two',
      'grid_id': 'g1',
      'models': ['flat-model'],
      'engines': [
        {
          'models': ['first'],
        },
        {
          'models': ['second'],
        },
      ],
    });

    expect(readGridEngines('g1', runDir: root).single.models, [
      'first',
      'flat-model',
      'second',
    ]);
  });

  test('is empty rather than throwing for a grid this computer never served, '
      'which is every grid it only reads from', () {
    expect(
      readGridEngines('never', runDir: Directory('${root.path}/no')),
      isEmpty,
    );
  });

  test('skips a corrupt record instead of losing the whole list to it', () {
    File('${root.path}/bad.json').writeAsStringSync('{ not json');
    writeEngine('good', {
      'engine_id': 'good',
      'grid_id': 'g1',
      'models': ['m'],
    });

    expect(readGridEngines('g1', runDir: root).single.id, 'good');
  });

  test('refuses a grid id that is a path, the same guard every other read here '
      'carries', () {
    expect(readGridEngines('../../etc', runDir: root), isEmpty);
  });
}
