// File: pgpass_file.dart
// Purpose: Parses libpq password files (.pgpass / pgpass.conf) and looks up
// passwords with libpq's exact matching rules.
//
// Source of truth: passwordFromFile() and pwdfMatchesString() in
// PostgreSQL's src/interfaces/libpq/fe-connect.c (REL_18_STABLE, lines
// 7869-8030, fetched 2026-10-17) and the libpq documentation, section
// 32.16 "The Password File".

import 'package:dabase_postgresql/src/config/pg_connection_config.dart';
import 'package:dabase_postgresql/src/config/pg_host.dart';
import 'package:dabase_postgresql/src/importers/pg_import_diagnostic.dart';
import 'package:dabase_postgresql/src/importers/pgpass_line_parser.dart';
import 'package:dabase_postgresql/src/importers/text_lines.dart';

/// Stable identifiers for `.pgpass` [PgLineDiagnostic]s.
enum PgPassDiagnosticCode {
  /// The file starts with a byte order mark. It was skipped; libpq would
  /// read it as part of the first host name, so that line never matches.
  byteOrderMark,

  /// The line has fewer than five `:`-separated fields. libpq never matches
  /// it, so it was skipped.
  tooFewFields,

  /// The line has more than five fields. libpq ignores everything after the
  /// password, and so does this parser.
  extraFields,

  /// `#` appears after leading whitespace. libpq treats only a `#` in the
  /// first column as a comment, so this is a data line.
  indentedComment,

  /// The line starts with whitespace, which libpq keeps as part of the host
  /// name, so the line is unlikely to match.
  leadingWhitespace,

  /// The line ends with spaces or tabs, which libpq keeps as part of the
  /// password.
  trailingWhitespace,

  /// The line contains a NUL character. It was skipped.
  nulCharacter,
}

final _digits = RegExp(r'^[0-9]+$');

/// One usable line of a password file:
/// `hostname:port:database:username:password`.
///
/// A field that was exactly `*` is a wildcard and is `null` here; `\*` is a
/// literal asterisk. All values are de-escaped (`\:` is `:`, `\\` is `\`).
final class PgPassEntry {
  /// Creates an entry. A `null` [host], [port], [database] or [user] is the
  /// `*` wildcard.
  const PgPassEntry({
    required this.line,
    required this.host,
    required this.port,
    required this.database,
    required this.user,
    required this.password,
  });

  /// One-based line number in the source file, for diagnostics such as
  /// "password came from imported .pgpass line 3".
  final int line;

  /// Host name, compared exactly (no DNS, no case folding), or `null` for
  /// `*`.
  final String? host;

  /// Port as written (compared as text), or `null` for `*`.
  final String? port;

  /// Database name, or `null` for `*`.
  final String? database;

  /// User name, or `null` for `*`.
  final String? user;

  /// The password. Never shown by [toString]. May be empty.
  final String password;

  /// Whether any of the four match fields is the `*` wildcard. Only
  /// entries without wildcards describe one concrete server.
  bool get hasWildcard =>
      host == null || port == null || database == null || user == null;

  /// A connection draft for this entry, or `null` when it has a wildcard or
  /// its port is not a number from 1 to 65535. An empty password becomes
  /// `null`.
  PgConnectionConfig? toConfig() {
    final (host, portText, database, user) = (
      this.host,
      this.port,
      this.database,
      this.user,
    );
    if (host == null || portText == null || database == null || user == null) {
      return null;
    }
    final port = _digits.hasMatch(portText) ? int.tryParse(portText) : null;
    if (port == null || port < 1 || port > 65535) return null;
    return PgConnectionConfig(
      hosts: [PgHost(host, port: port)],
      user: user,
      password: password.isEmpty ? null : password,
      database: database,
    );
  }

  @override
  String toString() {
    String show(String? field) => field ?? '*';
    return 'PgPassEntry(line $line: ${show(host)}:${show(port)}:'
        '${show(database)}:${show(user)}:****)';
  }
}

/// A parsed libpq password file.
///
/// Parsing never throws: malformed lines are skipped and reported in
/// [diagnostics]. File permissions are not checked (libpq ignores a file
/// with group or world access on Unix); the caller decides how to treat a
/// file picked from shared storage.
final class PgPassFile {
  PgPassFile._(this.entries, this._sources, this.diagnostics);

  /// Parses the text of a `.pgpass` file. Lines end at `\n`; trailing `\r`
  /// and `\n` characters are stripped like libpq's `pg_strip_crlf()`.
  /// Lines can be any length.
  factory PgPassFile.parse(String text) {
    final (:lines, :bomStripped) = splitTextLines(text);
    final entries = <PgPassEntry>[];
    final sources = <String>[];
    final diagnostics = <PgLineDiagnostic<PgPassDiagnosticCode>>[
      if (bomStripped)
        const PgLineDiagnostic(
          line: 1,
          code: PgPassDiagnosticCode.byteOrderMark,
          severity: PgImportSeverity.warning,
          message:
              'The file starts with a byte order mark, which was ignored. '
              'libpq would not match the first line.',
        ),
    ];
    for (final line in lines) {
      final result = parsePgPassLine(line.number, line.text);
      diagnostics.addAll(result.diagnostics);
      if (result.entry case final entry?) {
        entries.add(entry);
        sources.add(result.source);
      }
    }
    return PgPassFile._(
      List.unmodifiable(entries),
      sources,
      List.unmodifiable(diagnostics),
    );
  }

  /// libpq's default Unix-socket directory (`DEFAULT_PGSOCKET_DIR` in
  /// `pg_config_manual.h`). Some distributions build libpq with
  /// `/var/run/postgresql` instead; pass that to [lookup] to match them.
  static const defaultSocketDirectory = '/tmp';

  /// Usable lines, in file order, split into fields the way the libpq
  /// documentation describes. Use these to list or create connections;
  /// use [lookup] to find a password, since libpq's matcher can also match
  /// a line with unescaped colons (such as an IPv6 host).
  final List<PgPassEntry> entries;

  /// The text of each entry's line without trailing CR/LF, for [lookup].
  final List<String> _sources;

  /// Problems found while parsing, in line order. Never contains passwords.
  final List<PgLineDiagnostic<PgPassDiagnosticCode>> diagnostics;

  /// Returns the first line matching the target, or `null`, with libpq's
  /// rules:
  ///
  /// - the host is [host] if non-empty, else [hostaddr]; an empty host or
  ///   one equal to [socketDirectory] is `localhost`. There is no DNS and
  ///   no case folding, so `127.0.0.1` does not match `localhost`;
  /// - a `null` [port] is `5432`;
  /// - an empty or `null` [database] or [user] never matches (resolve
  ///   libpq's defaults, such as `dbname = user`, before calling);
  /// - fields are compared exactly, `*` matches anything, and the first
  ///   matching line wins. Like libpq, an unescaped `:` in the file also
  ///   matches a `:` in a value, so `::1:5432:db:user:pw` matches host
  ///   `::1`.
  ///
  /// The result describes how libpq read the line: a field matched by `*`
  /// is `null`, every other field equals the value looked up, and
  /// [PgPassEntry.password] is the password libpq would use. libpq only
  /// consults the file when no password was given.
  PgPassEntry? lookup({
    String? host,
    String? hostaddr,
    int? port,
    String? database,
    String? user,
    String socketDirectory = defaultSocketDirectory,
  }) {
    if (database == null || database.isEmpty) return null;
    if (user == null || user.isEmpty) return null;
    var target = host == null || host.isEmpty ? (hostaddr ?? '') : host;
    if (target.isEmpty || target == socketDirectory) target = 'localhost';
    final portText = '${port ?? PgHost.defaultPort}';
    for (var i = 0; i < entries.length; i++) {
      final match = matchPgPassLine(
        entries[i].line,
        _sources[i],
        host: target,
        port: portText,
        database: database,
        user: user,
      );
      if (match != null) return match;
    }
    return null;
  }

  /// Looks up every target host of [config] the way libpq does for a
  /// multi-host string: one result per host (by `host`, else the matching
  /// `hostaddr` item), with [PgConnectionConfig.effectiveDatabase] and
  /// [PgConnectionConfig.user]. Apply `resolveDefaults` first so the user
  /// is known.
  List<PgPassEntry?> lookupForConfig(
    PgConnectionConfig config, {
    String socketDirectory = defaultSocketDirectory,
  }) {
    final hosts = config.hosts;
    final addresses = config.parameters['hostaddr']?.split(',') ?? const [];
    final count = hosts.isNotEmpty
        ? hosts.length
        : (addresses.isNotEmpty ? addresses.length : 1);
    return [
      for (var i = 0; i < count; i++)
        lookup(
          host: i < hosts.length ? hosts[i].host : null,
          hostaddr: i < addresses.length ? addresses[i] : null,
          port: i < hosts.length ? hosts[i].port : null,
          database: config.effectiveDatabase,
          user: config.user,
          socketDirectory: socketDirectory,
        ),
    ];
  }

  @override
  String toString() =>
      'PgPassFile(${entries.length} entries, '
      '${diagnostics.length} diagnostics)';
}
