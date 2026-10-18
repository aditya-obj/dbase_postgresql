// File: table_ddl_queries.dart
// Purpose: The table recipe queries Q-T1..Q-T8, version-gated by
// server_version_num. Each takes `$1` as one OID (OidFilter.one, the
// per-object DDL viewer) or an OID array (OidFilter.many, the bulk catalog
// reader) and returns a `relid` column naming the object each row belongs
// to. Each text is exactly one statement. Moved from the dbase app in
// 0.6.0.

/// How a recipe query matches its `$1` parameter.
enum OidFilter {
  /// `$1` is one OID (`$1::pg_catalog.oid`).
  one,

  /// `$1` is an OID array literal (`$1::pg_catalog.oid[]`), see
  /// `oidArrayLiteral`.
  many,
}

/// `<column> = $1` for [filter].
String oidMatch(String column, OidFilter filter) => switch (filter) {
  OidFilter.one => '$column = \$1::pg_catalog.oid',
  OidFilter.many => '$column = ANY (\$1::pg_catalog.oid[])',
};

/// The first statement of the per-object DDL transaction.
const ddlBeginSql = 'BEGIN READ ONLY';

/// Transaction-local settings of the per-object DDL transaction.
const ddlSettingsSql =
    "SELECT pg_catalog.set_config('search_path', '', true), "
    "pg_catalog.set_config('lock_timeout', '2000', true), "
    "pg_catalog.set_config('statement_timeout', '15000', true)";

/// Q-T1. Only `r`, `p` and `f` relations: another relkind under the OID
/// returns no row (the OID was dropped and reused). `rls_active` is
/// `row_security_active(oid)`: row-level security would filter (or, with
/// `row_security = off`, refuse) the current user's reads.
String tableHeaderQuery(OidFilter filter) =>
    '''
SELECT c.oid AS relid, n.nspname AS schema, c.relname AS name, c.relkind, c.relpersistence,
       c.relispartition,
       CASE WHEN c.reloftype <> 0 THEN pg_catalog.format_type(c.reloftype, NULL) END AS of_type,
       CASE WHEN c.relkind = 'p' THEN pg_catalog.pg_get_partkeydef(c.oid) END AS partition_key,
       CASE WHEN c.relispartition THEN pg_catalog.pg_get_expr(c.relpartbound, c.oid) END AS partition_bound,
       am.amname AS access_method,
       c.reloptions,
       tc.reloptions AS toast_reloptions,
       ts.spcname AS tablespace,
       c.relrowsecurity, c.relforcerowsecurity,
       pg_catalog.row_security_active(c.oid) AS rls_active,
       c.relreplident,
       pg_catalog.pg_get_userbyid(c.relowner) AS owner,
       c.relacl,
       d.description AS comment,
       fs.srvname AS foreign_server,
       ft.ftoptions AS foreign_options
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_class tc ON tc.oid = c.reltoastrelid
LEFT JOIN pg_catalog.pg_am am ON am.oid = c.relam
LEFT JOIN pg_catalog.pg_tablespace ts ON ts.oid = c.reltablespace
LEFT JOIN pg_catalog.pg_description d ON d.objoid = c.oid AND d.objsubid = 0
     AND d.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass
LEFT JOIN pg_catalog.pg_foreign_table ft ON ft.ftrelid = c.oid
LEFT JOIN pg_catalog.pg_foreign_server fs ON fs.oid = ft.ftserver
WHERE ${oidMatch('c.oid', filter)}
  AND c.relkind IN ('r', 'p', 'f')
ORDER BY n.nspname, c.relname''';

/// Q-T1 for one table.
final String tableHeaderSql = tableHeaderQuery(OidFilter.one);

/// Q-T2.
String tableParentsQuery(OidFilter filter) =>
    '''
SELECT i.inhrelid AS relid, pn.nspname AS schema, p.relname AS name, i.inhseqno
FROM pg_catalog.pg_inherits i
JOIN pg_catalog.pg_class p ON p.oid = i.inhparent
JOIN pg_catalog.pg_namespace pn ON pn.oid = p.relnamespace
WHERE ${oidMatch('i.inhrelid', filter)}
ORDER BY i.inhrelid, i.inhseqno''';

/// Q-T2 for one table.
final String tableParentsSql = tableParentsQuery(OidFilter.one);

/// Q-T3. `attcompression` exists from PG 14.
String tableColumnsSql(
  int serverVersionNum, {
  OidFilter filter = OidFilter.one,
}) =>
    '''
SELECT a.attrelid AS relid, a.attnum, a.attname,
       pg_catalog.format_type(a.atttypid, a.atttypmod) AS type,
       a.attnotnull,
       a.attidentity,
       a.attgenerated,
       CASE WHEN a.atthasdef THEN pg_catalog.pg_get_expr(ad.adbin, ad.adrelid) END AS default_or_generation_expr,
       CASE WHEN a.attcollation <> t.typcollation AND a.attcollation <> 0
            THEN pg_catalog.quote_ident(cn.nspname) || '.' || pg_catalog.quote_ident(co.collname) END AS collation,
       a.attislocal, a.attinhcount,
       ${serverVersionNum >= 140000 ? 'a.attcompression' : "''::\"char\" AS attcompression"},
       a.attfdwoptions,
       cd.description AS comment
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
LEFT JOIN pg_catalog.pg_collation co ON co.oid = a.attcollation
LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid = co.collnamespace
LEFT JOIN pg_catalog.pg_description cd ON cd.objoid = a.attrelid AND cd.objsubid = a.attnum
     AND cd.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass
WHERE ${oidMatch('a.attrelid', filter)}
  AND a.attnum > 0
  AND NOT a.attisdropped
ORDER BY a.attrelid, a.attnum''';

/// Q-T4.
String tableIdentitiesQuery(OidFilter filter) =>
    '''
SELECT dep.refobjid AS relid, dep.refobjsubid AS attnum, s.seqstart, s.seqincrement, s.seqmin, s.seqmax, s.seqcache, s.seqcycle
FROM pg_catalog.pg_depend dep
JOIN pg_catalog.pg_sequence s ON s.seqrelid = dep.objid
WHERE dep.classid = 'pg_catalog.pg_class'::pg_catalog.regclass
  AND dep.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass
  AND ${oidMatch('dep.refobjid', filter)}
  AND dep.deptype = 'i'
''';

/// Q-T4 for one table.
final String tableIdentitiesSql = tableIdentitiesQuery(OidFilter.one);

/// Q-T5. Table NOT NULL constraints (`contype = 'n'`) exist from PG 18;
/// `attnum` (`conkey[1]`) is their column. `confrelid` is the table a
/// foreign key references.
String tableConstraintsSql(
  int serverVersionNum, {
  OidFilter filter = OidFilter.one,
}) =>
    '''
SELECT con.conrelid AS relid, con.oid, con.conname, con.contype, con.conislocal, con.convalidated, con.connoinherit,
       con.conkey[1] AS attnum,
       con.confrelid,
       pg_catalog.pg_get_constraintdef(con.oid, true) AS def,
       d.description AS comment
FROM pg_catalog.pg_constraint con
LEFT JOIN pg_catalog.pg_description d ON d.objoid = con.oid AND d.objsubid = 0
     AND d.classoid = 'pg_catalog.pg_constraint'::pg_catalog.regclass
WHERE ${oidMatch('con.conrelid', filter)}
  AND con.contype IN ('p', 'u', 'x', 'c', 'f'${serverVersionNum >= 180000 ? ", 'n'" : ''})
ORDER BY con.conrelid,
         CASE con.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'x' THEN 2
                          WHEN 'c' THEN 3 WHEN 'n' THEN 4 ELSE 5 END,
         con.conname''';

/// Q-T6, widened: every index except auto-created partition children,
/// with `is_constraint` instead of filtering constraint-owned indexes out,
/// so one query also finds a constraint-backed CLUSTER ON / REPLICA
/// IDENTITY index. Also used for materialized views.
String relationIndexesQuery(OidFilter filter) =>
    '''
SELECT i.indrelid AS relid, ic.relname AS name,
       pg_catalog.pg_get_indexdef(i.indexrelid) AS def,
       i.indisclustered, i.indisvalid, i.indisreplident,
       EXISTS (SELECT 1 FROM pg_catalog.pg_constraint c
               WHERE c.conindid = i.indexrelid AND c.conrelid = i.indrelid
                 AND c.contype IN ('p', 'u', 'x')) AS is_constraint,
       d.description AS comment
FROM pg_catalog.pg_index i
JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
LEFT JOIN pg_catalog.pg_description d ON d.objoid = i.indexrelid AND d.objsubid = 0
     AND d.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass
WHERE ${oidMatch('i.indrelid', filter)}
  AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_inherits ih WHERE ih.inhrelid = i.indexrelid)
ORDER BY i.indrelid, ic.relname''';

/// Q-T6 for one relation.
final String relationIndexesSql = relationIndexesQuery(OidFilter.one);

/// Q-T7 triggers (`tgparentid` exists from PG 13, the oldest supported).
String relationTriggersQuery(OidFilter filter) =>
    '''
SELECT t.tgrelid AS relid, t.tgname, pg_catalog.pg_get_triggerdef(t.oid, true) AS def, t.tgenabled
FROM pg_catalog.pg_trigger t
WHERE ${oidMatch('t.tgrelid', filter)}
  AND NOT t.tgisinternal
  AND t.tgparentid = 0
ORDER BY t.tgrelid, t.tgname''';

/// Q-T7 triggers of one relation.
final String relationTriggersSql = relationTriggersQuery(OidFilter.one);

/// Q-T7 rules.
String relationRulesQuery(OidFilter filter) =>
    '''
SELECT r.ev_class AS relid, r.rulename, pg_catalog.pg_get_ruledef(r.oid, true) AS def
FROM pg_catalog.pg_rewrite r
WHERE ${oidMatch('r.ev_class', filter)} AND r.rulename <> '_RETURN'
ORDER BY r.ev_class, r.rulename''';

/// Q-T7 rules of one relation.
final String relationRulesSql = relationRulesQuery(OidFilter.one);

/// Q-T7 policies.
String tablePoliciesQuery(OidFilter filter) =>
    '''
SELECT pol.polrelid AS relid, pol.polname, pol.polpermissive, pol.polcmd,
       CASE WHEN pol.polroles = '{0}'::pg_catalog.oid[] THEN ARRAY['PUBLIC']
            ELSE ARRAY(SELECT pg_catalog.quote_ident(ro.rolname) FROM pg_catalog.pg_roles ro
                       WHERE ro.oid = ANY (pol.polroles) ORDER BY ro.rolname) END AS roles,
       pg_catalog.pg_get_expr(pol.polqual, pol.polrelid, true) AS using_expr,
       pg_catalog.pg_get_expr(pol.polwithcheck, pol.polrelid, true) AS check_expr
FROM pg_catalog.pg_policy pol
WHERE ${oidMatch('pol.polrelid', filter)}
ORDER BY pol.polrelid, pol.polname''';

/// Q-T7 policies of one table.
final String tablePoliciesSql = tablePoliciesQuery(OidFilter.one);

/// Q-T7 extended statistics.
String tableStatisticsQuery(OidFilter filter) =>
    '''
SELECT s.stxrelid AS relid, pg_catalog.pg_get_statisticsobjdef(s.oid) AS def
FROM pg_catalog.pg_statistic_ext s
WHERE ${oidMatch('s.stxrelid', filter)}
ORDER BY s.stxrelid, s.stxname''';

/// Q-T7 extended statistics of one table.
final String tableStatisticsSql = tableStatisticsQuery(OidFilter.one);

/// Q-T8, for any `pg_class` relation (tables, views, sequences).
String relationGrantsQuery(OidFilter filter) =>
    '''
SELECT c.oid AS relid,
       CASE WHEN a.grantee = 0 THEN 'PUBLIC'
            ELSE pg_catalog.quote_ident(pg_catalog.pg_get_userbyid(a.grantee)) END AS grantee,
       a.privilege_type,
       a.is_grantable,
       (a.grantee = c.relowner) AS is_owner
FROM pg_catalog.pg_class c
CROSS JOIN LATERAL pg_catalog.aclexplode(c.relacl) a
WHERE ${oidMatch('c.oid', filter)}
ORDER BY 1, 2, 3''';

/// Q-T8 for one relation.
final String relationGrantsSql = relationGrantsQuery(OidFilter.one);
