// File: importer_corpus.dart
// Purpose: Random .pgpass inputs and lookup targets for comparing
// PgPassFile with the libpq reference, plus seed files for the importer
// mutation fuzzer.

import 'dart:math';

/// Field texts that exercise libpq's escaping and wildcard rules.
const _fieldPool = <String>[
  'a',
  'b',
  '*',
  r'\*',
  '**',
  r'a\:b',
  r'a\\',
  r'\a',
  'localhost',
  '127.0.0.1',
  '/tmp',
  '5432',
  '12',
  '',
  'a b',
  r'\',
  '#a',
  ' a',
  'a ',
];

/// Raw characters spliced into lines to break their structure.
const _noise = <String>[':', r'\', '*', '#', ' ', '\r', '\t', 'a', '\n'];

/// One random `.pgpass` text of up to eight lines.
String randomPgPassText(Random random) {
  final lines = <String>[];
  for (var i = random.nextInt(8); i >= 0; i--) {
    final fields = [
      for (var f = 3 + random.nextInt(4); f > 0; f--)
        _fieldPool[random.nextInt(_fieldPool.length)],
    ];
    var line = fields.join(':');
    if (random.nextInt(4) == 0) {
      final at = random.nextInt(line.length + 1);
      line =
          line.substring(0, at) +
          _noise[random.nextInt(_noise.length)] +
          line.substring(at);
    }
    lines.add(line);
  }
  final ending = ['\n', '\r\n', '\r\r\n'][random.nextInt(3)];
  return lines.join(ending) + (random.nextBool() ? ending : '');
}

/// Lookup tokens; ports are numeric strings without leading zeros so they
/// can be passed to `PgPassFile.lookup` as an `int`.
const hostTokens = <String>[
  'a',
  'b',
  '*',
  'a:b',
  r'a\',
  'localhost',
  '127.0.0.1',
  '/tmp',
  '',
  'a b',
  ' a',
];

/// Port tokens; empty means "not given".
const portTokens = <String>['5432', '12', ''];

/// Database and user tokens.
const nameTokens = <String>['a', 'b', '*', 'a:b', r'a\', '', '#a', 'a '];

const _serviceProd =
    '[prod]\nhost=db.example.com\nport=5432\ndbname=shop\nuser=alice\n'
    'sslmode=verify-full\n';

const _pgAdminModern =
    '{"Servers":{"1":{"Name":"a","Group":"g","Host":"h","Port":5432,'
    '"MaintenanceDB":"postgres","Username":"u","ConnectionParameters":'
    '{"sslmode":"prefer","connect_timeout":10,"password":"secret"}}}}';

const _pgAdminLegacy =
    '{"Servers":{"1":{"Name":"a","Group":"g","Host":"h","Port":5432,'
    '"MaintenanceDB":"d","Username":"u","SSLMode":"require","Timeout":5,'
    '"UseSSHTunnel":1,"TunnelHost":"j","TunnelPort":22}}}';

const _pgAdminService =
    '{"Servers":{"1":{"Name":"s","Group":"g","Service":"svc",'
    '"MaintenanceDB":"d","Tags":[{"text":"t","color":"#fff"}]}}}';

/// Seed texts for mutation fuzzing of the service file parser.
const serviceCorpus = <String>[
  _serviceProd,
  '# comment\n[a]\nhost=h\n\n[b]\nhost = x\nservice=a\n[a]\nport=1\n',
  '\uFEFF[x]\r\nhost=h1,h2\r\nport=5432,5433\r\npassword=secret\r\n',
  'host=outside\n[y\n[]\n[z]extra\nldap://example\nport=99999\n',
];

/// Seed texts for mutation fuzzing of the servers.json parser.
const pgAdminCorpus = <String>[_pgAdminModern, _pgAdminLegacy, _pgAdminService];

/// Fragments spliced into importer inputs by the fuzzer.
final importerFragments = <String>[
  '\n',
  '\r\n',
  ':',
  r'\',
  '*',
  '#',
  '[',
  ']',
  '=',
  ' ',
  '"',
  '{',
  '}',
  ',',
  '\u0000',
  '\uFEFF',
  'password=secret',
  '"Port":"x"',
  'x' * 1100,
];
