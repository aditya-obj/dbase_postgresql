// File: importers.dart
// Purpose: Narrow entrypoint for importing libpq password files, libpq
// connection service files and pgAdmin servers.json exports.

/// Import `.pgpass`, `pg_service.conf` and pgAdmin `servers.json` files
/// with libpq's (and pgAdmin's) own rules. Pure Dart: callers pass the file
/// text; nothing reads the file system or the environment.
library;

export 'src/importers/pg_import_diagnostic.dart'
    show PgImportException, PgImportSeverity, PgLineDiagnostic;
export 'src/importers/pg_service.dart' show PgService, PgServiceDiagnosticCode;
export 'src/importers/pg_service_file.dart' show PgServiceFile;
export 'src/importers/pgadmin_server.dart'
    show
        PgAdminErrorCode,
        PgAdminServer,
        PgAdminServerError,
        PgAdminSshTunnel,
        PgAdminTag,
        PgAdminTunnelAuthentication,
        PgAdminWarning,
        PgAdminWarningCode;
export 'src/importers/pgadmin_servers_file.dart' show PgAdminServersFile;
export 'src/importers/pgpass_file.dart'
    show PgPassDiagnosticCode, PgPassEntry, PgPassFile;
