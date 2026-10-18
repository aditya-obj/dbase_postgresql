// File: psql_console.dart
// Purpose: The client side of a psql session: the query buffer, the
// `\pset` / `\x` / `\timing` settings and what each backslash command
// does. Queries and catalog lookups are left to the caller, which runs
// them on its own connection and prints the results with [printTable].
//
// Behaviour of src/bin/psql/command.c (HandleSlashCmds, exec_command_*,
// do_pset, printPsetInfo, ParseVariableBool) - PostgreSQL License,
// (c) 1996-2026 PostgreSQL Global Development Group. See
// THIRD_PARTY_NOTICES.

import 'package:dbase_postgresql/src/psql/describe/describer.dart';
import 'package:dbase_postgresql/src/psql/describe/psql_query.dart';
import 'package:dbase_postgresql/src/psql/meta_command.dart';
import 'package:dbase_postgresql/src/psql/print/print_table.dart';
import 'package:dbase_postgresql/src/psql/psql_help.dart';
import 'package:dbase_postgresql/src/psql/psql_input.dart';

/// What a backslash command needs from the caller.
sealed class PsqlCommandResult {
  const PsqlCommandResult({this.warnings = const []});

  /// psql's `extra argument "…" ignored` warnings, printed after the
  /// command's own output.
  final List<String> warnings;
}

/// Done; print [outputs] (messages, may be empty).
final class PsqlCommandDone extends PsqlCommandResult {
  /// Creates the result.
  const PsqlCommandDone(this.outputs, {super.warnings});

  /// Messages to print.
  final List<PsqlOutput> outputs;

  /// Whether the command failed (the rest of the line is dropped).
  bool get failed => outputs.any((o) => o is PsqlMessageOutput && o.fails);
}

/// Run the describe command (`runDescribe`) and print its outputs, with
/// expanded display when [expanded].
final class PsqlDescribeRequest extends PsqlCommandResult {
  /// Creates the request.
  const PsqlDescribeRequest(
    this.command, {
    required this.expanded,
    super.warnings,
  });

  /// The `\d…` / `\l` / `\z` command.
  final MetaCommand command;

  /// The `x` modifier was given.
  final bool expanded;
}

/// Print the connection details (`\conninfo`).
final class PsqlConnInfoRequest extends PsqlCommandResult {
  /// Creates the request.
  const PsqlConnInfoRequest({super.warnings});
}

/// Close the console (`\q`).
final class PsqlQuitRequest extends PsqlCommandResult {
  /// Creates the request.
  const PsqlQuitRequest();
}

/// Commands psql has that this console leaves out on purpose, with the
/// reason shown to the user.
const Map<String, String> unsupportedCommands = {
  'copy': r'\copy is not supported here; use Import CSV or SQL export',
  '!': r'\! (shell commands) is not available',
  'gexec':
      r'\gexec is not supported: generated statements would skip '
      'the safety review',
  'i': r'\i (run a file) is not supported here',
  'include': r'\i (run a file) is not supported here',
  'ir': r'\ir (run a file) is not supported here',
  'include_relative': r'\ir (run a file) is not supported here',
  'o': r'\o (output to a file) is not supported here',
  'out': r'\o (output to a file) is not supported here',
  'w': r'\w (write to a file) is not supported here',
  'write': r'\w (write to a file) is not supported here',
  'e': r'\e (external editor) is not supported; use the Query tab',
  'edit': r'\e (external editor) is not supported; use the Query tab',
  'ef': r'\ef is not supported; use the Query tab',
  'ev': r'\ev is not supported; use the Query tab',
  'set': r'\set and variables are not supported here',
  'unset': r'\unset and variables are not supported here',
  'gset': r'\gset and variables are not supported here',
  'c': r'\c (reconnect) is not supported; open another connection',
  'connect': r'\c (reconnect) is not supported; open another connection',
  'watch': r'\watch is not supported here',
  'cd': r'\cd is not available',
  'setenv': r'\setenv is not available',
  'getenv': r'\getenv is not available',
  'prompt': r'\prompt is not supported here',
  'password': r'\password is not supported here; use Manage > Roles',
  'lo_import': 'large objects are not supported',
  'lo_export': 'large objects are not supported',
  'lo_list': 'large objects are not supported',
  'lo_unlink': 'large objects are not supported',
  'if': r'\if is not supported here',
  'elif': r'\elif is not supported here',
  'else': r'\else is not supported here',
  'endif': r'\endif is not supported here',
  's': r'\s is not supported here; use the history buttons',
  'errverbose': r'\errverbose is not supported here',
  'sf': r'\sf is not supported here; use Browse',
  'sv': r'\sv is not supported here; use Browse',
  'bind': r'\bind is not supported here',
  'crosstabview': r'\crosstabview is not supported here',
  'gdesc': r'\gdesc is not supported here',
  'h':
      r'\h (SQL help) is not included; see '
      'https://www.postgresql.org/docs/current/sql-commands.html',
  'help':
      r'\h (SQL help) is not included; see '
      'https://www.postgresql.org/docs/current/sql-commands.html',
};

/// A psql session's client state: input scanner and print settings.
final class PsqlConsole {
  /// Creates a console with psql's defaults (or [options]).
  PsqlConsole({this.options = const PrintOptions(), this.timing = false});

  /// The query buffer and line handling.
  final PsqlInputScanner input = PsqlInputScanner();

  /// `\pset` settings.
  PrintOptions options;

  /// `\timing`.
  bool timing;

  /// Feeds one input line; see [PsqlInputScanner.feedLine].
  List<PsqlInputItem> feedLine(String line) => input.feedLine(line);

  /// Runs [command]: settings change right away; describe, `\conninfo`
  /// and `\q` are handed back to the caller.
  PsqlCommandResult run(MetaCommand command) {
    final name = command.name;
    if (isDescribeCommand(name)) {
      final count = describeArgumentCount(name);
      return PsqlDescribeRequest(
        command,
        expanded: describeForcesExpanded(name),
        warnings: count == null ? const [] : _extra(command, count),
      );
    }
    switch (name) {
      case 'q' || 'quit':
        return const PsqlQuitRequest();
      case 'conninfo':
        return PsqlConnInfoRequest(warnings: _extra(command, 0));
      case '?':
        return PsqlCommandDone([PsqlMessageOutput(psqlHelpText.trim())]);
      case 'echo' || 'qecho' || 'warn':
        return PsqlCommandDone([PsqlMessageOutput(_echo(command))]);
      case 'x':
        return _pset(command, 'expanded', command.arg(0, semicolon: true), 1);
      case 'timing':
        return _timing(command);
      case 't':
        return _pset(
          command,
          'tuples_only',
          command.arg(0, semicolon: true),
          1,
        );
      case 'a':
        final next = options.format != PrintFormat.aligned
            ? 'aligned'
            : 'unaligned';
        return _pset(command, 'format', next, 0);
      case 'pset':
        final param = command.arg(0);
        if (param == null) {
          return PsqlCommandDone([PsqlMessageOutput(_psetSummary())]);
        }
        return _pset(command, param, command.arg(1), 2);
    }
    if (unsupportedCommands[name] case final reason?) {
      return PsqlCommandDone([PsqlMessageOutput(reason, isError: true)]);
    }
    return PsqlCommandDone([
      PsqlMessageOutput('invalid command \\$name', isError: true),
      const PsqlMessageOutput(r'Try \? for help.', isError: true),
    ]);
  }

  List<String> _extra(MetaCommand command, int used) => [
    for (final arg in command.args.skip(used))
      '\\${command.name}: extra argument "${arg.value()}" ignored',
  ];

  String _echo(MetaCommand command) {
    // `-n` (no newline) is accepted; console messages always end a line.
    return [
      for (final (i, arg) in command.args.indexed)
        if (i != 0 || arg.isQuoted || arg.normal != '-n') arg.normal,
    ].join(' ');
  }

  PsqlCommandResult _timing(MetaCommand command) {
    final value = command.arg(0);
    if (value != null) {
      final parsed = parseBool(value);
      if (parsed == null) {
        return PsqlCommandDone([
          PsqlMessageOutput(
            'unrecognized value "$value" for "\\timing": Boolean expected',
            isError: true,
          ),
        ]);
      }
      timing = parsed;
    } else {
      timing = !timing;
    }
    return PsqlCommandDone([
      PsqlMessageOutput(timing ? 'Timing is on.' : 'Timing is off.'),
    ], warnings: _extra(command, 1));
  }

  PsqlCommandResult _pset(
    MetaCommand command,
    String param,
    String? value,
    int used,
  ) {
    final error = _applyPset(param, value);
    if (error != null) {
      return PsqlCommandDone([PsqlMessageOutput(error, isError: true)]);
    }
    return PsqlCommandDone([
      PsqlMessageOutput(psetInfo(param)),
    ], warnings: _extra(command, used));
  }

  /// do_pset: changes [param]; returns psql's error text, or `null`.
  String? _applyPset(String param, String? value) {
    final o = options;
    switch (param) {
      case 'format':
        if (value == null) return null;
        const formats = {
          'aligned': PrintFormat.aligned,
          'csv': PrintFormat.csv,
          'unaligned': PrintFormat.unaligned,
          'wrapped': PrintFormat.wrapped,
        };
        final matches = [
          for (final name in formats.keys)
            if (value.isNotEmpty && name.startsWith(value.toLowerCase())) name,
        ];
        if (matches.length > 1) {
          return '\\pset: ambiguous abbreviation "$value" matches both '
              '"${matches[0]}" and "${matches[1]}"';
        }
        if (matches.isEmpty) {
          return r'\pset: allowed formats here are aligned, csv, unaligned, '
              'wrapped';
        }
        options = o.copyWith(format: formats[matches.single]);
      case 'border':
        if (value != null) {
          options = o.copyWith(border: _atoi(value));
        }
      case 'x' || 'expanded' || 'vertical':
        if (value != null && value.toLowerCase() == 'auto') {
          options = o.copyWith(expanded: ExpandedMode.auto);
        } else if (value != null) {
          final on = parseBool(value);
          if (on == null) {
            return 'unrecognized value "$value" for "$param"\n'
                'Available values are: on, off, auto.';
          }
          options = o.copyWith(
            expanded: on ? ExpandedMode.on : ExpandedMode.off,
          );
        } else {
          options = o.copyWith(
            expanded: o.expanded == ExpandedMode.off
                ? ExpandedMode.on
                : ExpandedMode.off,
          );
        }
      case 'null':
        if (value != null) options = o.copyWith(nullDisplay: value);
      case 'footer':
        final next = _toggle(value, o.defaultFooter, param);
        if (next is String) return next;
        options = o.copyWith(defaultFooter: next! as bool);
      case 't' || 'tuples_only':
        final next = _toggle(value, o.tuplesOnly, param);
        if (next is String) return next;
        options = o.copyWith(tuplesOnly: next! as bool);
      case 'C' || 'title':
        options = value == null
            ? o.copyWith(clearTitle: true)
            : o.copyWith(title: value);
      case 'columns':
        if (value != null) options = o.copyWith(columns: _atoi(value));
      case 'fieldsep':
        if (value != null) options = o.copyWith(fieldSeparator: value);
      case 'csv_fieldsep':
        if (value != null) {
          if (value.length != 1) {
            return r'\pset: csv_fieldsep must be a single one-byte character';
          }
          if (value == '"' || value == '\n' || value == '\r') {
            return r'\pset: csv_fieldsep cannot be a double quote, a '
                'newline, or a carriage return';
          }
          options = o.copyWith(csvFieldSeparator: value);
        }
      case 'linestyle' ||
          'pager' ||
          'pager_min_lines' ||
          'numericlocale' ||
          'recordsep' ||
          'recordsep_zero' ||
          'fieldsep_zero' ||
          'tableattr' ||
          'T' ||
          'xheader_width' ||
          'unicode_border_linestyle' ||
          'unicode_column_linestyle' ||
          'unicode_header_linestyle':
        return '\\pset: option $param is not supported here';
      default:
        return '\\pset: unknown option: $param';
    }
    return null;
  }

  /// A toggled or parsed boolean, or psql's error text.
  Object? _toggle(String? value, bool current, String param) {
    if (value == null) return !current;
    return parseBool(value) ??
        'unrecognized value "$value" for "$param": Boolean expected';
  }

  /// printPsetInfo: the line psql prints after changing [param].
  String psetInfo(String param) {
    final o = options;
    return switch (param) {
      'border' => 'Border style is ${o.border}.',
      'columns' =>
        o.columns == 0
            ? 'Target width is unset.'
            : 'Target width is ${o.columns}.',
      'x' || 'expanded' || 'vertical' => switch (o.expanded) {
        ExpandedMode.on => 'Expanded display is on.',
        ExpandedMode.auto => 'Expanded display is used automatically.',
        ExpandedMode.off => 'Expanded display is off.',
      },
      'csv_fieldsep' => 'Field separator for CSV is "${o.csvFieldSeparator}".',
      'fieldsep' => 'Field separator is "${o.fieldSeparator}".',
      'footer' =>
        o.defaultFooter ? 'Default footer is on.' : 'Default footer is off.',
      'format' => 'Output format is ${o.format.name}.',
      'null' => 'Null display is "${o.nullDisplay}".',
      't' || 'tuples_only' =>
        o.tuplesOnly ? 'Tuples only is on.' : 'Tuples only is off.',
      'C' ||
      'title' => o.title == null ? 'Title is unset.' : 'Title is "${o.title}".',
      _ => '',
    };
  }

  String _psetSummary() {
    final o = options;
    String row(String name, String value) => '${name.padRight(24)} $value';
    return [
      row('border', '${o.border}'),
      row('columns', '${o.columns}'),
      row('csv_fieldsep', "'${o.csvFieldSeparator}'"),
      row('expanded', o.expanded.name),
      row('fieldsep', "'${o.fieldSeparator}'"),
      row('footer', o.defaultFooter ? 'on' : 'off'),
      row('format', o.format.name),
      row('null', "'${o.nullDisplay}'"),
      row('title', o.title == null ? '' : "'${o.title}'"),
      row('tuples_only', o.tuplesOnly ? 'on' : 'off'),
    ].join('\n');
  }
}

/// psql's ParseVariableBool: `on`, `off` (at least two letters), any
/// prefix of `true`, `false`, `yes`, `no`, and `1` / `0`; case-insensitive.
/// `null` when it is none of them.
bool? parseBool(String value) {
  final v = value.toLowerCase();
  if (v.isEmpty) return null;
  bool prefixOf(String word) => word.startsWith(v);
  if (prefixOf('true') || prefixOf('yes')) return true;
  if (prefixOf('false') || prefixOf('no')) return false;
  if (v.length >= 2 && 'on'.startsWith(v)) return true;
  if (v.length >= 2 && 'off'.startsWith(v)) return false;
  if (v == '1') return true;
  if (v == '0') return false;
  return null;
}

/// C's atoi: leading digits (with sign), 0 when none.
int _atoi(String value) {
  final match = RegExp(r'^\s*([+-]?\d+)').firstMatch(value);
  return match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
}
