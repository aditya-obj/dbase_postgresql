// File: psql_console_test.dart
// Purpose: The console's backslash commands: \x, \timing, \pset, \a, \t,
// \echo, \?, \q, \conninfo, describe hand-off, refused and unknown
// commands, and psql's "extra argument ignored" warnings.

import 'package:dabase_postgresql/psql.dart';
import 'package:test/test.dart';

MetaCommand _cmd(String text) => parseMetaCommand(text, 0);

List<String> _texts(PsqlCommandResult result) => [
  if (result is PsqlCommandDone)
    for (final output in result.outputs)
      if (output is PsqlMessageOutput) output.text,
];

void main() {
  late PsqlConsole console;
  setUp(() => console = PsqlConsole());

  group(r'\x', () {
    test('toggles, and takes on / off / auto', () {
      expect(_texts(console.run(_cmd(r'\x'))), ['Expanded display is on.']);
      expect(console.options.expanded, ExpandedMode.on);
      expect(_texts(console.run(_cmd(r'\x'))), ['Expanded display is off.']);
      expect(_texts(console.run(_cmd(r'\x auto'))), [
        'Expanded display is used automatically.',
      ]);
      expect(console.options.expanded, ExpandedMode.auto);
      console.run(_cmd(r'\x on'));
      expect(console.options.expanded, ExpandedMode.on);
      console.run(_cmd(r'\x OFF'));
      expect(console.options.expanded, ExpandedMode.off);
    });

    test('rejects other values', () {
      final result = console.run(_cmd(r'\x maybe')) as PsqlCommandDone;
      expect(result.failed, isTrue);
      expect(_texts(result).single, contains('unrecognized value "maybe"'));
    });

    test('warns about extra arguments, like psql', () {
      final result = console.run(_cmd(r'\x on off'));
      expect(result.warnings, [r'\x: extra argument "off" ignored']);
    });
  });

  test(r'\timing toggles and reports', () {
    expect(_texts(console.run(_cmd(r'\timing'))), ['Timing is on.']);
    expect(console.timing, isTrue);
    expect(_texts(console.run(_cmd(r'\timing off'))), ['Timing is off.']);
    expect(console.timing, isFalse);
  });

  group(r'\pset', () {
    test('null, border, footer, title, tuples_only, columns', () {
      expect(_texts(console.run(_cmd(r"\pset null '(null)'"))), [
        'Null display is "(null)".',
      ]);
      expect(console.options.nullDisplay, '(null)');
      expect(_texts(console.run(_cmd(r'\pset border 2'))), [
        'Border style is 2.',
      ]);
      expect(_texts(console.run(_cmd(r'\pset footer'))), [
        'Default footer is off.',
      ]);
      expect(_texts(console.run(_cmd(r'\pset title Report'))), [
        'Title is "Report".',
      ]);
      expect(_texts(console.run(_cmd(r'\pset title'))), ['Title is unset.']);
      expect(_texts(console.run(_cmd(r'\pset tuples_only on'))), [
        'Tuples only is on.',
      ]);
      expect(_texts(console.run(_cmd(r'\pset columns 60'))), [
        'Target width is 60.',
      ]);
    });

    test('format accepts unique prefixes', () {
      expect(_texts(console.run(_cmd(r'\pset format wr'))), [
        'Output format is wrapped.',
      ]);
      expect(console.options.format, PrintFormat.wrapped);
      console.run(_cmd(r'\pset format csv'));
      expect(console.options.format, PrintFormat.csv);
      final bad = console.run(_cmd(r'\pset format html')) as PsqlCommandDone;
      expect(bad.failed, isTrue);
    });

    test('unknown and unsupported options are errors', () {
      expect(_texts(console.run(_cmd(r'\pset bogus 1'))), [
        r'\pset: unknown option: bogus',
      ]);
      final pager = console.run(_cmd(r'\pset pager off')) as PsqlCommandDone;
      expect(pager.failed, isTrue);
    });

    test('without arguments lists the settings', () {
      final text = _texts(console.run(_cmd(r'\pset'))).single;
      expect(text, contains('border                   1'));
      expect(text, contains('format                   aligned'));
    });
  });

  test(r'\a switches between aligned and unaligned', () {
    console.run(_cmd(r'\a'));
    expect(console.options.format, PrintFormat.unaligned);
    console.run(_cmd(r'\a'));
    expect(console.options.format, PrintFormat.aligned);
  });

  test(r'\t toggles tuples only', () {
    console.run(_cmd(r'\t'));
    expect(console.options.tuplesOnly, isTrue);
  });

  test(r'\echo joins its arguments', () {
    expect(_texts(console.run(_cmd(r"\echo hello 'big world'"))), [
      'hello big world',
    ]);
    expect(_texts(console.run(_cmd(r'\echo -n x'))), ['x']);
  });

  test(r'\? shows help; \q, \conninfo and describes go to the caller', () {
    expect(_texts(console.run(_cmd(r'\?'))).single, contains(r'\dt[Sx+]'));
    expect(console.run(_cmd(r'\q')), isA<PsqlQuitRequest>());
    expect(console.run(_cmd(r'\conninfo')), isA<PsqlConnInfoRequest>());
    final describe = console.run(_cmd(r'\dtx public.*'));
    expect(describe, isA<PsqlDescribeRequest>());
    expect((describe as PsqlDescribeRequest).expanded, isTrue);
    final extra = console.run(_cmd(r'\dt a b'));
    expect(extra.warnings, [r'\dt: extra argument "b" ignored']);
    expect(console.run(_cmd(r'\df f int4 text')).warnings, isEmpty);
  });

  test('left-out commands are refused with a reason', () {
    for (final name in ['copy', '!', 'gexec', 'i', 'o', 'e', 'set', 'c']) {
      final result = console.run(_cmd('\\$name x')) as PsqlCommandDone;
      expect(result.failed, isTrue, reason: name);
      expect(_texts(result).single, unsupportedCommands[name]);
    }
  });

  test("unknown commands get psql's message", () {
    expect(_texts(console.run(_cmd(r'\bogus'))), [
      r'invalid command \bogus',
      r'Try \? for help.',
    ]);
  });

  test('parseBool follows psql', () {
    expect(parseBool('on'), isTrue);
    expect(parseBool('of'), isFalse);
    expect(parseBool('o'), isNull);
    expect(parseBool('Y'), isTrue);
    expect(parseBool('fa'), isFalse);
    expect(parseBool('1'), isTrue);
    expect(parseBool('0'), isFalse);
    expect(parseBool('2'), isNull);
  });

  test('formatConnInfo never needs a password', () {
    expect(
      formatConnInfo(
        database: 'app',
        user: 'me',
        host: 'db.example.com',
        port: 5432,
        tls: 'sslmode verify-full',
        sshHop: 'bastion:22',
      ),
      'You are connected to database "app" as user "me" on host '
      '"db.example.com" at port "5432".\n'
      'SSL connection (sslmode verify-full)\n'
      'Through an SSH tunnel via "bastion:22".',
    );
  });
}
