// File: function_rules.dart
// Purpose: Finds calls to built-in functions with side effects, pg_cron
// job changes (which count as writes) and set_config() calls that can make
// the session read-write (internal).

import 'package:dbase_postgresql/src/sql/analysis/safety_finding.dart';
import 'package:dbase_postgresql/src/sql/analysis/token_scan.dart';
import 'package:dbase_postgresql/src/sql/sql_token.dart';

/// Settings that control whether transactions are read-only.
const readOnlySettings = {
  'default_transaction_read_only',
  'transaction_read_only',
};

/// Values that keep a boolean setting on (compared lower case).
const truthyValues = {'on', 'true', 'yes', '1'};

/// Functions with side effects, matched by exact (server-form) name.
const _sideEffectFunctions = {
  'pg_terminate_backend',
  'pg_cancel_backend',
  'pg_reload_conf',
  'pg_rotate_logfile',
  'pg_switch_wal',
  'pg_promote',
  'pg_create_restore_point',
  'pg_notify',
  'dblink',
  'dblink_exec',
  'dblink_connect',
  'set_config',
  // Large objects. An explicit list rather than `lo_*`, so tables or
  // columns such as `lo_files (...)` are not mistaken for calls.
  'lo_import',
  'lo_export',
  'lo_unlink',
  'lo_create',
  'lo_creat',
  'lo_open',
  'lo_put',
  'lo_from_bytea',
  'lo_truncate',
  'lo_truncate64',
  'lowrite',
  'nextval',
  'setval',
};

/// Function families matched by name prefix.
const _sideEffectPrefixes = [
  'pg_advisory_lock',
  'pg_advisory_xact_lock',
  'pg_try_advisory_lock',
  'pg_try_advisory_xact_lock',
  'pg_stat_reset',
];

/// pg_cron functions that create, change or remove scheduled jobs, matched
/// only when qualified with the `cron` schema (`cron.schedule(...)`), so a
/// user function named `schedule` is not mistaken for one.
const _cronWritingFunctions = {
  'schedule',
  'schedule_in_database',
  'unschedule',
  'alter_job',
};

/// Whether the name at [i] (followed by `(`) is a [_cronWritingFunctions]
/// call qualified with `cron.`.
bool _isCronWrite(TokenScan scan, int i) =>
    _cronWritingFunctions.contains(scan.tokens[i].normalized) &&
    scan.isPunctuation(i - 1, '.') &&
    scan.isName(i - 2) &&
    scan.tokens[i - 2].normalized == 'cron';

/// Whether [scan] calls a function that writes persistent state the
/// analyzer knows of: pg_cron's `cron.schedule`, `cron.schedule_in_database`,
/// `cron.unschedule` and `cron.alter_job`. Statements that do are counted as
/// writing.
bool callsWritingFunction(TokenScan scan) {
  for (var i = 2; i < scan.length - 1; i++) {
    if (scan.isName(i) &&
        scan.isPunctuation(i + 1, '(') &&
        _isCronWrite(scan, i)) {
      return true;
    }
  }
  return false;
}

/// Findings for function calls anywhere in [scan] (at any paren depth):
/// [SafetyFindingCode.readOnlyEscape] for a `set_config` call that can
/// make the session read-write, else [SafetyFindingCode.sideEffectFunction]
/// for a listed function or a pg_cron job change ([callsWritingFunction]).
/// A call is a name (optionally schema-qualified) followed by `(`; strings,
/// dollar bodies and comments are single tokens or trivia, so nothing
/// inside them matches.
List<SafetyFinding> functionCallFindings(TokenScan scan) {
  final findings = <SafetyFinding>[];
  for (var i = 0; i < scan.length - 1; i++) {
    if (!scan.isName(i) || !scan.isPunctuation(i + 1, '(')) continue;
    final name = scan.tokens[i].normalized;
    if (_isCronWrite(scan, i)) {
      findings.add(
        SafetyFinding(
          SafetyFindingCode.sideEffectFunction,
          'cron.$name() changes pg_cron scheduled jobs, which run later '
          'with their own privileges.',
          offset: scan.offsetAt(i - 2),
        ),
      );
      continue;
    }
    final label = _sideEffectLabel(name);
    if (label == null) continue;
    if (name == 'set_config' && _setConfigEscapes(scan, i + 1)) {
      findings.add(
        SafetyFinding(
          SafetyFindingCode.readOnlyEscape,
          'set_config() can change default_transaction_read_only or '
          'transaction_read_only and make the session read-write.',
          offset: scan.offsetAt(i),
        ),
      );
      continue;
    }
    findings.add(
      SafetyFinding(
        SafetyFindingCode.sideEffectFunction,
        '$label() has side effects (on sessions, server state, locks, '
        'sequences or large objects) that a read-only transaction may not '
        'prevent.',
        offset: scan.offsetAt(i),
      ),
    );
  }
  return findings;
}

/// The name to show for a side-effect function, or `null` if [name] is
/// not one. Prefix families are shown as `prefix*` so the message only
/// contains fixed text.
String? _sideEffectLabel(String name) {
  if (_sideEffectFunctions.contains(name)) return name;
  for (final prefix in _sideEffectPrefixes) {
    if (name.startsWith(prefix)) return '$prefix*';
  }
  if (name.startsWith('pg_') && name.contains('replication_slot')) {
    return 'pg_*replication_slot*';
  }
  return null;
}

/// Whether `set_config(` at [open] may turn read-only off: the setting
/// name is one of [readOnlySettings] or not a plain string literal, and
/// the value is not a plain literal from [truthyValues].
bool _setConfigEscapes(TokenScan scan, int open) {
  final nameIndex = open + 1;
  if (!isPlainString(scan, nameIndex) ||
      !scan.isPunctuation(nameIndex + 1, ',')) {
    return true;
  }
  if (!readOnlySettings.contains(scan.literalValue(nameIndex))) return false;
  final valueIndex = nameIndex + 2;
  final keepsOn =
      isPlainString(scan, valueIndex) &&
      scan.isPunctuation(valueIndex + 1, ',') &&
      truthyValues.contains(scan.literalValue(valueIndex));
  return !keepsOn;
}

/// Whether the token at [index] is a `'...'` string whose value is its
/// text without quotes (no `N` prefix, no backslash that a
/// non-standard-conforming server could read as an escape).
bool isPlainString(TokenScan scan, int index) {
  if (index < 0 || index >= scan.length) return false;
  final token = scan.tokens[index];
  return token.kind == SqlTokenKind.string &&
      token.text.startsWith("'") &&
      !token.text.contains(r'\');
}
