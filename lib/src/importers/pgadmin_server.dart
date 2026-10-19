// File: pgadmin_server.dart
// Purpose: One server imported from a pgAdmin 4 servers.json export, its
// SSH tunnel, tags, warnings and rejection errors.

import 'package:dabase_postgresql/src/config/pg_connection_config.dart';

/// Why a pgAdmin field needs the user's attention. Stable, for
/// localisation and UI logic.
enum PgAdminWarningCode {
  /// A parameter holds a path on the computer that exported the file
  /// (`passfile`, `sslcert`, `sslkey`, `sslrootcert`, `sslcrl`,
  /// `sslcrldir`, `sslkeylogfile`, `oauth_ca_file`, `TunnelIdentityFile`).
  /// The file has to be selected again on this device. The value is kept.
  filePath,

  /// The server uses a connection service (`Service`, or `service` in
  /// `ConnectionParameters`). Resolve it against an imported service file.
  service,

  /// Kerberos/GSSAPI settings (`KerberosAuthentication`,
  /// `gssencmode=require`, `krbsrvname`, `gsslib`, `gssdelegation`), which
  /// are not supported.
  kerberos,

  /// `PasswordExecCommand` was present. It is never run, and the command
  /// text is not kept.
  passwordExecCommand,

  /// `PostConnectionSQL` was present. It is kept in
  /// [PgAdminServer.postConnectionSql] but must not run without the user's
  /// consent.
  postConnectionSql,

  /// `hostaddr` is set. With verify-full the host name is still needed for
  /// certificate checks.
  hostAddress,

  /// `sslnegotiation=direct` (PostgreSQL 17 direct TLS) is set.
  directSslNegotiation,

  /// A secret (`password`, `sslpassword`, ...) is stored in the file in
  /// plain text. Move it to secure storage.
  secretInFile,

  /// An optional field has the wrong JSON type or an unknown value and was
  /// ignored.
  invalidField,

  /// A `ConnectionParameters` entry was ignored: its name is not a keyword
  /// or its value is not a string or number.
  ignoredParameter,
}

/// A field of one pgAdmin server that needs the user's attention.
final class PgAdminWarning {
  /// Creates a warning.
  const PgAdminWarning(this.code, this.field, this.message);

  /// Stable identifier.
  final PgAdminWarningCode code;

  /// The pgAdmin field (`TunnelIdentityFile`) or libpq keyword (`sslcert`)
  /// concerned, or `null` when the name itself was not safe to repeat.
  /// Never a value.
  final String? field;

  /// Human-readable English explanation. Never contains values.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is PgAdminWarning &&
      other.code == code &&
      other.field == field &&
      other.message == message;

  @override
  int get hashCode => Object.hash(code, field, message);

  @override
  String toString() => 'PgAdminWarning(${code.name}, $field: $message)';
}

/// Why a server entry was rejected.
enum PgAdminErrorCode {
  /// The entry under `Servers` is not a JSON object.
  notAnObject,

  /// A field pgAdmin requires is missing or empty (`Name`, `Group`,
  /// `MaintenanceDB`, and without `Service`: `Host`, `Port`, `Username`).
  missingField,

  /// A required field has the wrong JSON type (e.g. `Port` is not an
  /// integer).
  invalidFieldType,

  /// A value is invalid, e.g. a port out of range or an unknown sslmode.
  invalidValue,
}

/// A server entry that could not be imported.
final class PgAdminServerError {
  /// Creates an error for the entry whose key under `Servers` is
  /// [serverId].
  const PgAdminServerError(this.serverId, this.code, this.field, this.message);

  /// The entry's key under `Servers` (pgAdmin exports `"1"`, `"2"`, ...).
  final String serverId;

  /// Stable identifier.
  final PgAdminErrorCode code;

  /// The pgAdmin field concerned, or `null`. Never a value.
  final String? field;

  /// Human-readable English explanation. Never contains values.
  final String message;

  @override
  String toString() =>
      'PgAdminServerError($serverId, ${code.name}, $field: $message)';
}

/// How pgAdmin authenticates to the SSH tunnel host
/// (`TunnelAuthentication`).
enum PgAdminTunnelAuthentication {
  /// `0`: a password.
  password,

  /// `1`: a private key file ([PgAdminSshTunnel.identityFile]).
  identityFile,
}

/// The SSH tunnel of a pgAdmin server (`UseSSHTunnel` = 1).
final class PgAdminSshTunnel {
  /// Creates tunnel settings.
  const PgAdminSshTunnel({
    required this.host,
    required this.port,
    required this.username,
    required this.authentication,
    required this.identityFile,
    required this.promptPassword,
    required this.keepAlive,
  });

  /// `TunnelHost`, or `null` when missing.
  final String? host;

  /// `TunnelPort`; 22 when missing.
  final int port;

  /// `TunnelUsername`, or `null`.
  final String? username;

  /// `TunnelAuthentication`.
  final PgAdminTunnelAuthentication authentication;

  /// `TunnelIdentityFile`: a path on the exporting computer. Ask the user
  /// to select the key file again.
  final String? identityFile;

  /// `TunnelPromptPassword`: ask for the password on every connect.
  final bool promptPassword;

  /// `TunnelKeepAlive` (seconds), or `null` when missing or 0.
  final Duration? keepAlive;

  @override
  String toString() =>
      'PgAdminSshTunnel($username@$host:$port, ${authentication.name})';
}

/// A coloured server tag (`Tags`).
final class PgAdminTag {
  /// Creates a tag.
  const PgAdminTag(this.text, {this.color});

  /// The tag text.
  final String text;

  /// The colour as pgAdmin stored it (e.g. `#FF0000`), or `null`.
  final String? color;

  @override
  bool operator ==(Object other) =>
      other is PgAdminTag && other.text == text && other.color == color;

  @override
  int get hashCode => Object.hash(text, color);

  @override
  String toString() => 'PgAdminTag($text, $color)';
}

/// One server from a pgAdmin `servers.json` export. Passwords are never
/// exported by pgAdmin, so [config] has no password unless the file was
/// edited by hand.
final class PgAdminServer {
  /// Creates a server. Normally produced by `PgAdminServersFile.parse`.
  PgAdminServer({
    required this.id,
    required this.name,
    required this.group,
    required this.config,
    required this.usesLegacyLayout,
    required List<PgAdminWarning> warnings,
    this.role,
    this.comment,
    this.service,
    this.backgroundColor,
    this.foregroundColor,
    this.databaseRestriction,
    this.databaseRestrictionType,
    this.sshTunnel,
    this.postConnectionSql,
    this.shared = false,
    List<PgAdminTag> tags = const [],
  }) : warnings = List.unmodifiable(warnings),
       tags = List.unmodifiable(tags);

  /// The entry's key under `Servers`.
  final String id;

  /// `Name`: the display name.
  final String name;

  /// `Group`: the server group (a folder in pgAdmin).
  final String group;

  /// `Host`, `Port`, `Username`, `MaintenanceDB` and the libpq parameters
  /// from `ConnectionParameters` (or the legacy flat keys). File-path
  /// parameters are kept; see [warnings].
  final PgConnectionConfig config;

  /// Whether the entry uses the pre-6.20 flat keys (`SSLMode`, `HostAddr`,
  /// `Timeout`, ...) instead of `ConnectionParameters`.
  final bool usesLegacyLayout;

  /// Fields that need the user's attention.
  final List<PgAdminWarning> warnings;

  /// `Role`: pgAdmin runs `SET ROLE` with it after connecting.
  final String? role;

  /// `Comment`: free text.
  final String? comment;

  /// `Service`: a connection service name.
  final String? service;

  /// `BGColor`, e.g. `#FF0000`.
  final String? backgroundColor;

  /// `FGColor`.
  final String? foregroundColor;

  /// `DBRestriction`, exactly as stored by pgAdmin.
  final String? databaseRestriction;

  /// `DBRestrictionType` (`databases` or `schemas`).
  final String? databaseRestrictionType;

  /// The SSH tunnel, or `null` when `UseSSHTunnel` is not set.
  final PgAdminSshTunnel? sshTunnel;

  /// `PostConnectionSQL`. Never run it without asking the user.
  final String? postConnectionSql;

  /// `Shared`: a server shared by a pgAdmin administrator.
  final bool shared;

  /// `Tags`.
  final List<PgAdminTag> tags;

  @override
  String toString() => 'PgAdminServer($id, $name, ${config.redacted()})';
}
