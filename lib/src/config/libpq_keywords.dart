// File: libpq_keywords.dart
// Purpose: libpq connection keywords, their PG* environment variables, and
// which ones hold secrets (internal, not exported).
//
// Source of truth: the PQconninfoOptions[] table in PostgreSQL's
// src/interfaces/libpq/fe-connect.c (columns `keyword` and `envvar`),
// checked on 2026-10-16 against
//   * master        @ f9fc9a78a36517122c0325fd31db5ba6066d82ea
//   * REL_18_STABLE @ 7eb8fcad860e9a0548191dab7a87a5bead5f8e91
// and the libpq documentation, sections 32.1.2 "Parameter Key Words" and
// 32.15 "Environment Variables". Entries are in PQconninfoOptions order so
// the table can be diffed against the C source line by line.
//
// Version notes: `servicefile` (PGSERVICEFILE) and `oauth_ca_file`
// (PGOAUTHCAFILE) are conninfo keywords on master only (PostgreSQL 19);
// PostgreSQL 18 reads PGSERVICEFILE directly when it loads the service
// file. `sslkeylogfile` is new in 18. Keeping newer keywords is harmless:
// older servers never see them, because libpq keywords are client-side.
//
// Not in this table, by design (they are not conninfo keyword fallbacks):
// PGREQUIRESSL (deprecated; handled in config_builder.dart the way
// conninfo_add_defaults() handles it), PGDATESTYLE / PGTZ / PGGEQO
// (fe-connect.c EnvironmentOptions[], sent as startup GUCs, not applied
// by resolveDefaults in v0.1), PGSYSCONFDIR, PGLOCALEDIR and PGOAUTHDEBUG.

/// Known libpq keywords mapped to the environment variable libpq reads as
/// their fallback (`null` when there is none). Used to decide whether a
/// keyword may be echoed in an error message and by `resolveDefaults`.
const libpqKeywordEnvironment = <String, String?>{
  'service': 'PGSERVICE',
  'servicefile': 'PGSERVICEFILE',
  'user': 'PGUSER',
  'password': 'PGPASSWORD',
  'passfile': 'PGPASSFILE',
  'channel_binding': 'PGCHANNELBINDING',
  'connect_timeout': 'PGCONNECT_TIMEOUT',
  'dbname': 'PGDATABASE',
  'host': 'PGHOST',
  'hostaddr': 'PGHOSTADDR',
  'port': 'PGPORT',
  'client_encoding': 'PGCLIENTENCODING',
  'options': 'PGOPTIONS',
  'application_name': 'PGAPPNAME',
  'fallback_application_name': null,
  'keepalives': null,
  'keepalives_idle': null,
  'keepalives_interval': null,
  'keepalives_count': null,
  'tcp_user_timeout': null,
  'sslmode': 'PGSSLMODE',
  'sslnegotiation': 'PGSSLNEGOTIATION',
  'sslcompression': 'PGSSLCOMPRESSION',
  'sslcert': 'PGSSLCERT',
  'sslkey': 'PGSSLKEY',
  'sslcertmode': 'PGSSLCERTMODE',
  'sslpassword': null,
  'sslrootcert': 'PGSSLROOTCERT',
  'sslcrl': 'PGSSLCRL',
  'sslcrldir': 'PGSSLCRLDIR',
  'sslsni': 'PGSSLSNI',
  'requirepeer': 'PGREQUIREPEER',
  'require_auth': 'PGREQUIREAUTH',
  'min_protocol_version': 'PGMINPROTOCOLVERSION',
  'max_protocol_version': 'PGMAXPROTOCOLVERSION',
  'ssl_min_protocol_version': 'PGSSLMINPROTOCOLVERSION',
  'ssl_max_protocol_version': 'PGSSLMAXPROTOCOLVERSION',
  'gssencmode': 'PGGSSENCMODE',
  'krbsrvname': 'PGKRBSRVNAME',
  'gsslib': 'PGGSSLIB',
  'gssdelegation': 'PGGSSDELEGATION',
  'replication': null,
  'target_session_attrs': 'PGTARGETSESSIONATTRS',
  'load_balance_hosts': 'PGLOADBALANCEHOSTS',
  'scram_client_key': null,
  'scram_server_key': null,
  'oauth_issuer': null,
  'oauth_client_id': null,
  'oauth_client_secret': null,
  'oauth_scope': null,
  'oauth_ca_file': 'PGOAUTHCAFILE',
  'sslkeylogfile': null,
};

/// Keywords whose values are secrets and must never be logged.
///
/// libpq marks `password`, `sslpassword` and `oauth_client_secret` with the
/// `"*"` (password) display flag. The SCRAM keys only carry `"D"` (debug)
/// there, but they are key material, so they are treated as secrets too.
const secretKeywords = {
  'password',
  'sslpassword',
  'oauth_client_secret',
  'scram_client_key',
  'scram_server_key',
};

/// Describes [key] for an error message without leaking secrets: known
/// libpq keywords are quoted, anything else (which may be a mistyped
/// password) is not echoed.
String describeKeyword(String key) =>
    libpqKeywordEnvironment.containsKey(key) ? '"$key"' : 'a keyword';

final _keywordSyntax = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Whether [key] has the shape of a libpq keyword. Anything else (such as
/// `postsql://u:pw@h/db?sslmode` from a mistyped URI scheme) is rejected
/// so that text which may hold a password never becomes a stored, printed
/// parameter name.
bool isKeywordSyntax(String key) => _keywordSyntax.hasMatch(key);
