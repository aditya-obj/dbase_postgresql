// File: libpq_keywords.dart
// Purpose: libpq connection keywords, their PG* environment variables, and
// which ones hold secrets (internal, not exported).
//
// Keyword and environment-variable names follow the libpq documentation
// ("Parameter Key Words" and "Environment Variables", PostgreSQL 18).

/// Known libpq keywords mapped to the environment variable libpq reads as
/// their fallback (`null` when there is none). Used to decide whether a
/// keyword may be echoed in an error message and by `resolveDefaults`.
const libpqKeywordEnvironment = <String, String?>{
  'host': 'PGHOST',
  'hostaddr': 'PGHOSTADDR',
  'port': 'PGPORT',
  'dbname': 'PGDATABASE',
  'user': 'PGUSER',
  'password': 'PGPASSWORD',
  'passfile': 'PGPASSFILE',
  'require_auth': 'PGREQUIREAUTH',
  'channel_binding': 'PGCHANNELBINDING',
  'connect_timeout': 'PGCONNECT_TIMEOUT',
  'client_encoding': 'PGCLIENTENCODING',
  'options': 'PGOPTIONS',
  'application_name': 'PGAPPNAME',
  'fallback_application_name': null,
  'keepalives': null,
  'keepalives_idle': null,
  'keepalives_interval': null,
  'keepalives_count': null,
  'tcp_user_timeout': null,
  'replication': null,
  'gssencmode': 'PGGSSENCMODE',
  'sslmode': 'PGSSLMODE',
  'sslnegotiation': 'PGSSLNEGOTIATION',
  'sslcompression': 'PGSSLCOMPRESSION',
  'sslcert': 'PGSSLCERT',
  'sslkey': 'PGSSLKEY',
  'sslpassword': null,
  'sslcertmode': 'PGSSLCERTMODE',
  'sslrootcert': 'PGSSLROOTCERT',
  'sslcrl': 'PGSSLCRL',
  'sslcrldir': 'PGSSLCRLDIR',
  'sslsni': 'PGSSLSNI',
  'requirepeer': 'PGREQUIREPEER',
  'ssl_min_protocol_version': 'PGSSLMINPROTOCOLVERSION',
  'ssl_max_protocol_version': 'PGSSLMAXPROTOCOLVERSION',
  'min_protocol_version': 'PGMINPROTOCOLVERSION',
  'max_protocol_version': 'PGMAXPROTOCOLVERSION',
  'krbsrvname': 'PGKRBSRVNAME',
  'gsslib': 'PGGSSLIB',
  'gssdelegation': 'PGGSSDELEGATION',
  'service': 'PGSERVICE',
  'servicefile': 'PGSERVICEFILE',
  'target_session_attrs': 'PGTARGETSESSIONATTRS',
  'load_balance_hosts': 'PGLOADBALANCEHOSTS',
  'oauth_issuer': null,
  'oauth_client_id': null,
  'oauth_client_secret': null,
  'oauth_scope': null,
  'scram_client_key': null,
  'scram_server_key': null,
};

/// Keywords whose values are secrets and must never be logged.
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
