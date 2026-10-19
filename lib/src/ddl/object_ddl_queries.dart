// File: object_ddl_queries.dart
// Purpose: Queries for view, materialized view, routine, sequence and
// index DDL. `$1` is one OID or an OID array (see OidFilter); each row has
// a `relid` column naming its object. Each text is exactly one statement.
// Moved from the dabase app in 0.6.0.

import 'package:dabase_postgresql/src/ddl/table_ddl_queries.dart';

/// A view or materialized view. `pg_get_viewdef` is NULL once the view
/// is dropped; any other relkind returns no row.
String viewHeaderQuery(OidFilter filter) =>
    '''
SELECT c.oid AS relid, n.nspname AS schema, c.relname AS name, c.relkind, c.reloptions,
       am.amname AS access_method,
       ts.spcname AS tablespace,
       c.relispopulated,
       pg_catalog.pg_get_viewdef(c.oid, true) AS def,
       pg_catalog.pg_get_userbyid(c.relowner) AS owner,
       c.relacl,
       d.description AS comment
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_am am ON am.oid = c.relam
LEFT JOIN pg_catalog.pg_tablespace ts ON ts.oid = c.reltablespace
LEFT JOIN pg_catalog.pg_description d ON d.objoid = c.oid AND d.objsubid = 0
     AND d.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass
WHERE ${oidMatch('c.oid', filter)}
  AND c.relkind IN ('v', 'm')
ORDER BY n.nspname, c.relname''';

/// One view or materialized view.
final String viewHeaderSql = viewHeaderQuery(OidFilter.one);

/// Column comments of any relation.
String relationColumnCommentsQuery(OidFilter filter) =>
    '''
SELECT a.attrelid AS relid, a.attname, d.description AS comment
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_description d ON d.objoid = a.attrelid AND d.objsubid = a.attnum
     AND d.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass
WHERE ${oidMatch('a.attrelid', filter)}
  AND a.attnum > 0
  AND NOT a.attisdropped
ORDER BY a.attrelid, a.attnum''';

/// Column comments of one relation.
final String relationColumnCommentsSql = relationColumnCommentsQuery(
  OidFilter.one,
);

/// A routine. `pg_get_functiondef` raises an error for aggregates, so it
/// is only called for other kinds.
String routineHeaderQuery(OidFilter filter) =>
    '''
SELECT p.oid AS relid, n.nspname AS schema, p.proname AS name, p.prokind,
       pg_catalog.pg_get_function_identity_arguments(p.oid) AS identity_args,
       CASE WHEN p.prokind <> 'a' THEN pg_catalog.pg_get_functiondef(p.oid) END AS def,
       pg_catalog.pg_get_userbyid(p.proowner) AS owner,
       p.proacl,
       d.description AS comment
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
LEFT JOIN pg_catalog.pg_description d ON d.objoid = p.oid AND d.objsubid = 0
     AND d.classoid = 'pg_catalog.pg_proc'::pg_catalog.regclass
WHERE ${oidMatch('p.oid', filter)}
ORDER BY n.nspname, p.proname, 5''';

/// One routine.
final String routineHeaderSql = routineHeaderQuery(OidFilter.one);

/// The `pg_aggregate` fields shown for an aggregate.
const aggregateSql = r'''
SELECT a.aggkind,
       a.aggtransfn::pg_catalog.regproc::pg_catalog.text AS sfunc,
       pg_catalog.format_type(a.aggtranstype, NULL) AS stype,
       CASE WHEN a.aggfinalfn <> 0 THEN a.aggfinalfn::pg_catalog.regproc::pg_catalog.text END AS finalfunc,
       CASE WHEN a.aggcombinefn <> 0 THEN a.aggcombinefn::pg_catalog.regproc::pg_catalog.text END AS combinefunc,
       a.agginitval AS initcond
FROM pg_catalog.pg_aggregate a
WHERE a.aggfnoid = $1::pg_catalog.oid''';

/// Grants on a routine (`proacl`).
String routineGrantsQuery(OidFilter filter) =>
    '''
SELECT p.oid AS relid,
       CASE WHEN a.grantee = 0 THEN 'PUBLIC'
            ELSE pg_catalog.quote_ident(pg_catalog.pg_get_userbyid(a.grantee)) END AS grantee,
       a.privilege_type,
       a.is_grantable,
       (a.grantee = p.proowner) AS is_owner
FROM pg_catalog.pg_proc p
CROSS JOIN LATERAL pg_catalog.aclexplode(p.proacl) a
WHERE ${oidMatch('p.oid', filter)}
ORDER BY 1, 2, 3''';

/// Grants on one routine.
final String routineGrantsSql = routineGrantsQuery(OidFilter.one);

/// A sequence with its owning column. The bulk form ([OidFilter.many])
/// also reads `readable` and `last_value`: NULL when the sequence was
/// never used (`is_called` false) or the current user may not read it
/// (`readable` false).
String sequenceQuery(OidFilter filter) =>
    '''
SELECT c.oid AS relid, n.nspname AS schema, c.relname AS name, c.relpersistence,
       pg_catalog.format_type(s.seqtypid, NULL) AS data_type,
       s.seqstart, s.seqincrement, s.seqmin, s.seqmax, s.seqcache, s.seqcycle,
       own.deptype AS owned_kind,
       own_n.nspname AS owned_by_schema,
       own_t.relname AS owned_by_table,
       own_a.attname AS owned_by_column,
       own.refobjid AS owned_by_relid,
       pg_catalog.pg_get_userbyid(c.relowner) AS owner,
       c.relacl,
       d.description AS comment${filter == OidFilter.many ? _sequenceValueColumns : ''}
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
JOIN pg_catalog.pg_sequence s ON s.seqrelid = c.oid
LEFT JOIN pg_catalog.pg_description d ON d.objoid = c.oid AND d.objsubid = 0
     AND d.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass
LEFT JOIN pg_catalog.pg_depend own
       ON own.classid = 'pg_catalog.pg_class'::pg_catalog.regclass
      AND own.objid = c.oid
      AND own.objsubid = 0
      AND own.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass
      AND own.deptype IN ('a', 'i')
LEFT JOIN pg_catalog.pg_class own_t ON own_t.oid = own.refobjid
LEFT JOIN pg_catalog.pg_namespace own_n ON own_n.oid = own_t.relnamespace
LEFT JOIN pg_catalog.pg_attribute own_a ON own_a.attrelid = own.refobjid AND own_a.attnum = own.refobjsubid
WHERE ${oidMatch('c.oid', filter)}
  AND c.relkind = 'S'
ORDER BY n.nspname, c.relname''';

const _sequenceValueColumns = '''
,
       pg_catalog.has_sequence_privilege(c.oid, 'SELECT, USAGE') AS readable,
       CASE WHEN pg_catalog.has_sequence_privilege(c.oid, 'SELECT, USAGE')
            THEN pg_catalog.pg_sequence_last_value(c.oid) END AS last_value''';

/// One sequence.
final String sequenceSql = '${sequenceQuery(OidFilter.one)}\nLIMIT 1';

/// One index.
const indexSql = r'''
SELECT n.nspname AS schema, ic.relname AS name,
       pg_catalog.pg_get_indexdef(i.indexrelid) AS def,
       i.indisvalid,
       d.description AS comment
FROM pg_catalog.pg_index i
JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
JOIN pg_catalog.pg_namespace n ON n.oid = ic.relnamespace
LEFT JOIN pg_catalog.pg_description d ON d.objoid = i.indexrelid AND d.objsubid = 0
     AND d.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass
WHERE i.indexrelid = $1::pg_catalog.oid''';
