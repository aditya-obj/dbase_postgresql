// File: service_file_parser.dart
// Purpose: Parses every section of a libpq connection service file with
// parseServiceFile()'s rules (internal, not exported).
//
// Source of truth: parseServiceFile() and parseServiceInfo() in
// PostgreSQL's src/interfaces/libpq/fe-connect.c (REL_18_STABLE, lines
// 5929-6155, fetched 2026-10-17); `servicefile` handling from master
// (PostgreSQL 19, lines 6176-6179). libpq parses only the section it is
// looking for; this parser reports, per section, what that lookup would do.

import 'package:dabase_postgresql/src/config/config_builder.dart';
import 'package:dabase_postgresql/src/config/libpq_keywords.dart';
import 'package:dabase_postgresql/src/config/pg_config_parse_exception.dart';
import 'package:dabase_postgresql/src/config/pg_connection_config.dart';
import 'package:dabase_postgresql/src/config/raw_setting.dart';
import 'package:dabase_postgresql/src/importers/pg_import_diagnostic.dart';
import 'package:dabase_postgresql/src/importers/pg_service.dart';
import 'package:dabase_postgresql/src/importers/text_lines.dart';

typedef _Code = PgServiceDiagnosticCode;
typedef _Diagnostic = PgLineDiagnostic<PgServiceDiagnosticCode>;

/// `fgets(buf, 1024, f)` plus `strlen(line) >= sizeof(buf) - 1`.
const _maxLineBytes = 1023;

/// The parsed sections and all diagnostics of one file.
typedef ParsedServiceFile = ({
  List<PgService> services,
  List<_Diagnostic> diagnostics,
  _Diagnostic? lineTooLong,
});

/// Parses [text] into services. Never throws.
ParsedServiceFile parseServiceFileText(String text) {
  final (:lines, :bomStripped) = splitTextLines(text);
  final diagnostics = <_Diagnostic>[
    if (bomStripped)
      const PgLineDiagnostic(
        line: 1,
        code: _Code.byteOrderMark,
        severity: PgImportSeverity.warning,
        message:
            'The file starts with a byte order mark, which was ignored. '
            'libpq would not recognise the first line.',
      ),
  ];
  final sections = <_Section>[];
  final names = <String>{};
  _Section? current;
  // True under a malformed, empty or duplicate header: its lines are
  // ignored without an outsideSection diagnostic.
  var ignoring = false;
  _Diagnostic? tooLong;

  void report(
    _Section? section,
    int line,
    _Code code,
    PgImportSeverity severity,
    String message,
  ) {
    final d = PgLineDiagnostic(
      line: line,
      code: code,
      severity: severity,
      message: message,
    );
    diagnostics.add(d);
    section?.diagnostics.add(d);
  }

  for (final line in lines) {
    final n = line.number;
    final bytes = utf8Length(line.text) + (line.hasNewline ? 1 : 0);
    if (bytes >= _maxLineBytes && tooLong == null) {
      tooLong = PgLineDiagnostic(
        line: n,
        code: _Code.lineTooLong,
        severity: PgImportSeverity.error,
        message:
            'Line $n is $bytes bytes; libpq allows at most '
            '${_maxLineBytes - 1} and stops reading the file there.',
      );
      diagnostics.add(tooLong);
      // libpq checks the length before anything else, so the section that
      // is open here (even if this line starts a new one) fails too.
      current?.diagnostics.add(tooLong);
    }
    final content = _trimC(line.text);
    if (content.isEmpty || content.startsWith('#')) continue;

    if (content.startsWith('[')) {
      current = null;
      ignoring = true;
      final close = content.indexOf(']');
      if (close < 0) {
        report(
          null,
          n,
          _Code.malformedSectionHeader,
          PgImportSeverity.warning,
          'The section header has no "]"; its lines are ignored.',
        );
      } else if (close == 1) {
        report(
          null,
          n,
          _Code.emptyServiceName,
          PgImportSeverity.warning,
          'The section has no name; its lines are ignored.',
        );
      } else if (!names.add(content.substring(1, close))) {
        report(
          null,
          n,
          _Code.duplicateService,
          PgImportSeverity.info,
          'A service with this name appears earlier in the file; libpq '
          'reads only the first, so this section is ignored.',
        );
      } else {
        current = _Section(content.substring(1, close), n);
        if (tooLong != null) current.diagnostics.add(tooLong);
        sections.add(current);
        ignoring = false;
      }
      continue;
    }

    if (current == null) {
      if (!ignoring) {
        report(
          null,
          n,
          _Code.outsideSection,
          PgImportSeverity.info,
          'The line is not inside a [service] section; libpq ignores it.',
        );
      }
      continue;
    }
    if (content.contains('\u0000')) {
      report(
        current,
        n,
        _Code.nulCharacter,
        PgImportSeverity.error,
        'The line contains a NUL character.',
      );
      continue;
    }
    if (content.startsWith('ldap')) {
      report(
        current,
        n,
        _Code.ldapNotSupported,
        PgImportSeverity.warning,
        'LDAP service lookups are not supported; the line was skipped.',
      );
      continue;
    }
    final equals = content.indexOf('=');
    if (equals < 0) {
      report(
        current,
        n,
        _Code.missingEquals,
        PgImportSeverity.error,
        'Syntax error: expected keyword=value.',
      );
      continue;
    }
    final key = content.substring(0, equals);
    final value = content.substring(equals + 1);
    final trimmedKey = _trimC(key);
    if (key == 'service' || key == 'servicefile') {
      report(
        current,
        n,
        _Code.nestedService,
        PgImportSeverity.error,
        'Nested service specifications ("$key") are not supported.',
      );
      continue;
    }
    if (!libpqKeywordEnvironment.containsKey(key)) {
      final spaced =
          trimmedKey != key && libpqKeywordEnvironment.containsKey(trimmedKey);
      report(
        current,
        n,
        spaced ? _Code.spaceAroundEquals : _Code.unknownKeyword,
        PgImportSeverity.error,
        spaced
            ? 'Syntax error: remove the whitespace before "=" after '
                  '"$trimmedKey"; libpq does not allow it.'
            : 'Syntax error: unknown connection keyword.',
      );
      continue;
    }
    if (current.settings.containsKey(key)) {
      report(
        current,
        n,
        _Code.duplicateKeyword,
        PgImportSeverity.info,
        '"$key" is already set in this service; libpq keeps the first '
        'value.',
      );
      continue;
    }
    if (value.isNotEmpty && isCSpace(value.codeUnitAt(0))) {
      report(
        current,
        n,
        _Code.valueHasLeadingWhitespace,
        PgImportSeverity.warning,
        'The value of "$key" starts with whitespace, which libpq keeps.',
      );
    }
    final offset = line.offset + line.text.indexOf(content) + equals + 1;
    current.settings[key] = RawSetting(value, offset);
    current.valueLines[offset] = n;
  }

  // Building validates values and may add invalidValue diagnostics, so it
  // must run before the diagnostics are sorted.
  final services = [for (final s in sections) s.build(report)];
  return (
    services: services,
    diagnostics: diagnostics..sort((a, b) => a.line.compareTo(b.line)),
    lineTooLong: tooLong,
  );
}

/// [text] without leading and trailing C `isspace()` characters.
String _trimC(String text) {
  var start = 0;
  var end = text.length;
  while (start < end && isCSpace(text.codeUnitAt(start))) {
    start++;
  }
  while (end > start && isCSpace(text.codeUnitAt(end - 1))) {
    end--;
  }
  return text.substring(start, end);
}

final class _Section {
  _Section(this.name, this.line);

  final String name;
  final int line;
  final RawSettings settings = {};
  final Map<int, int> valueLines = {};
  final List<_Diagnostic> diagnostics = [];

  PgService build(
    void Function(_Section?, int, _Code, PgImportSeverity, String) report,
  ) {
    PgConnectionConfig? config;
    if (!diagnostics.any((d) => d.severity == PgImportSeverity.error)) {
      try {
        final v = validateSettings(settings);
        config = PgConnectionConfig(
          hosts: v.hosts,
          user: v.user,
          password: v.password,
          database: v.database,
          sslMode: v.sslMode,
          parameters: v.parameters,
        );
      } on PgConfigParseException catch (e) {
        report(
          this,
          valueLines[e.offset] ?? line,
          _Code.invalidValue,
          PgImportSeverity.error,
          e.message,
        );
      }
    }
    diagnostics.sort((a, b) => a.line.compareTo(b.line));
    return PgService(
      name: name,
      line: line,
      settings: {
        for (final MapEntry(:key, :value) in settings.entries) key: value.value,
      },
      config: config,
      diagnostics: diagnostics,
    );
  }
}
