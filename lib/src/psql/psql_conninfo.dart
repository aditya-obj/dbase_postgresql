// File: psql_conninfo.dart
// Purpose: The text of `\conninfo`: where the console is connected. The
// password is never part of it.
//
// Wording of src/bin/psql/command.c (exec_command_conninfo, psql 17) -
// PostgreSQL License, (c) 1996-2026 PostgreSQL Global Development Group.
// See THIRD_PARTY_NOTICES.

/// `\conninfo` output: psql's sentence, then a line for TLS and one for
/// an SSH tunnel when there is one. [tls] is a short description (for
/// example the sslmode); [sshHop] is `host:port` of the SSH server.
String formatConnInfo({
  required String database,
  required String user,
  required String host,
  required int port,
  String? tls,
  String? sshHop,
}) {
  final where = 'on host "$host" at port "$port"';
  final lines = [
    'You are connected to database "$database" as user "$user" $where.',
    if (tls != null) 'SSL connection ($tls)',
    if (sshHop != null) 'Through an SSH tunnel via "$sshHop".',
  ];
  return lines.join('\n');
}
