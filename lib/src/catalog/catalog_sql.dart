// File: catalog_sql.dart
// Purpose: The bulk catalog queries of CatalogReader that the per-object
// DDL recipes don't already cover: listings, types, aggregates,
// extensions, schemas, grants, default privileges, pg_depend edges and
// counts of objects a dump skips. One statement each; `$n` parameters are
// OID array literals or `t`/`f`. Version-gated for PostgreSQL 13 to 18.
//
// User objects have OIDs >= 16384 (FirstNormalObjectId); the dependency
// query relies on that to skip the built-in catalog cheaply.

/// Server facts the reader and the dump header need.
const serverFactsSql = '''
SELECT pg_catalog.current_setting('server_version_num') AS version_num,
       pg_catalog.current_setting('server_version') AS version,
       pg_catalog.pg_is_in_recovery() AS in_recovery''';

/// `NOT EXISTS` filter: [column] (an OID of [catalog]) is not a member of
/// an extension (`pg_depend.deptype = 'e'`).
String notExtensionMember(String column, String catalog) =>
    '''
NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend x
                  WHERE x.classid = 'pg_catalog.$catalog'::pg_catalog.regclass
                    AND x.objid = $column AND x.deptype = 'e')''';

/// Schemas by OID (`$1` OID array), with comments.
const schemasSql = r'''
SELECT n.oid AS relid, n.nspname AS name, d.description AS comment, n.nspacl
FROM pg_catalog.pg_namespace n
LEFT JOIN pg_catalog.pg_description d ON d.objoid = n.oid AND d.objsubid = 0
     AND d.classoid = 'pg_catalog.pg_namespace'::pg_catalog.regclass
WHERE n.oid = ANY ($1::pg_catalog.oid[])
ORDER BY n.nspname''';

/// Grants on schemas (`$1` OID array).
const schemaGrantsSql = r'''
SELECT n.oid AS relid,
       CASE WHEN a.grantee = 0 THEN 'PUBLIC'
            ELSE pg_catalog.quote_ident(pg_catalog.pg_get_userbyid(a.grantee)) END AS grantee,
       a.privilege_type,
       a.is_grantable,
       (a.grantee = n.nspowner) AS is_owner
FROM pg_catalog.pg_namespace n
CROSS JOIN LATERAL pg_catalog.aclexplode(n.nspacl) a
WHERE n.oid = ANY ($1::pg_catalog.oid[])
ORDER BY 1, 2, 3''';

/// Relations to dump: tables, partitions, foreign tables, views,
/// materialized views and sequences in the `$1` schemas, or (when `$2` is
/// an OID array) only the `$2` tables with their partitions and the
/// sequences they own. Extension members are left out.
final relationListingSql =
    '''
WITH picked AS (
  SELECT t.relid::pg_catalog.oid AS oid
  FROM pg_catalog.unnest(\$2::pg_catalog.oid[]) AS r(oid),
       LATERAL pg_catalog.pg_partition_tree(r.oid) AS t
)
SELECT c.oid AS relid, n.nspname AS schema, c.relname AS name, c.relkind,
       c.relispartition, c.relnamespace AS schema_oid,
       CASE WHEN c.relkind IN ('r', 'm') THEN pg_catalog.pg_total_relation_size(c.oid) END AS total_bytes
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p', 'f', 'v', 'm', 'S')
  AND ${notExtensionMember('c.oid', 'pg_class')}
  AND CASE WHEN \$2::pg_catalog.oid[] IS NULL
           THEN c.relnamespace = ANY (\$1::pg_catalog.oid[])
           ELSE c.oid IN (SELECT oid FROM picked)
                OR (c.relkind = 'S' AND EXISTS (
                      SELECT 1 FROM pg_catalog.pg_depend own
                      WHERE own.classid = 'pg_catalog.pg_class'::pg_catalog.regclass
                        AND own.objid = c.oid
                        AND own.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass
                        AND own.refobjid IN (SELECT oid FROM picked)
                        AND own.deptype IN ('a', 'i')))
      END
ORDER BY n.nspname, c.relname''';

/// Routines (functions, procedures, aggregates) in the `$1` schemas,
/// extension members left out.
final routineListingSql = '''
SELECT p.oid AS relid
FROM pg_catalog.pg_proc p
WHERE p.pronamespace = ANY (\$1::pg_catalog.oid[])
  AND ${notExtensionMember('p.oid', 'pg_proc')}''';

/// Enum, composite, range and domain types in the `$1` schemas.
/// Relation row types, arrays, multiranges and extension members are left
/// out; base and shell types are counted by [skippedCountsSql] instead.
String typesSql(int serverVersionNum) =>
    '''
SELECT t.oid AS relid, n.nspname AS schema, t.typname AS name, t.typtype,
       CASE WHEN t.typtype = 'd' THEN pg_catalog.format_type(t.typbasetype, t.typtypmod) END AS base_type,
       t.typnotnull, t.typdefault,
       CASE WHEN t.typtype = 'd' AND t.typcollation <> 0 AND t.typcollation <> bt.typcollation
            THEN pg_catalog.quote_ident(cn.nspname) || '.' || pg_catalog.quote_ident(co.collname) END AS collation,
       CASE WHEN t.typtype = 'r' THEN pg_catalog.format_type(r.rngsubtype, NULL) END AS range_subtype,
       CASE WHEN t.typtype = 'r' AND NOT opc.opcdefault
            THEN pg_catalog.quote_ident(opn.nspname) || '.' || pg_catalog.quote_ident(opc.opcname) END AS range_opclass,
       CASE WHEN t.typtype = 'r' AND r.rngcollation <> 0 AND r.rngcollation <> st.typcollation
            THEN pg_catalog.quote_ident(rcn.nspname) || '.' || pg_catalog.quote_ident(rco.collname) END AS range_collation,
       CASE WHEN r.rngcanonical <> 0 THEN r.rngcanonical::pg_catalog.regproc::pg_catalog.text END AS range_canonical,
       CASE WHEN r.rngsubdiff <> 0 THEN r.rngsubdiff::pg_catalog.regproc::pg_catalog.text END AS range_subdiff,
       ${serverVersionNum >= 140000 ? "CASE WHEN t.typtype = 'r' THEN pg_catalog.quote_ident(mn.nspname) || '.' || pg_catalog.quote_ident(mt.typname) END" : 'NULL::pg_catalog.text'} AS range_multirange,
       CASE WHEN t.typtype = 'e' THEN ARRAY(SELECT e.enumlabel FROM pg_catalog.pg_enum e
                                            WHERE e.enumtypid = t.oid ORDER BY e.enumsortorder) END AS enum_labels,
       d.description AS comment
FROM pg_catalog.pg_type t
JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
LEFT JOIN pg_catalog.pg_class tc ON tc.oid = t.typrelid
LEFT JOIN pg_catalog.pg_type bt ON bt.oid = t.typbasetype
LEFT JOIN pg_catalog.pg_collation co ON co.oid = t.typcollation
LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid = co.collnamespace
LEFT JOIN pg_catalog.pg_range r ON r.rngtypid = t.oid
LEFT JOIN pg_catalog.pg_type st ON st.oid = r.rngsubtype
LEFT JOIN pg_catalog.pg_opclass opc ON opc.oid = r.rngsubopc
LEFT JOIN pg_catalog.pg_namespace opn ON opn.oid = opc.opcnamespace
LEFT JOIN pg_catalog.pg_collation rco ON rco.oid = r.rngcollation
LEFT JOIN pg_catalog.pg_namespace rcn ON rcn.oid = rco.collnamespace
${serverVersionNum >= 140000 ? _multirangeJoins : ''}LEFT JOIN pg_catalog.pg_description d ON d.objoid = t.oid AND d.objsubid = 0
     AND d.classoid = 'pg_catalog.pg_type'::pg_catalog.regclass
WHERE t.typnamespace = ANY (\$1::pg_catalog.oid[])
  AND (t.typtype IN ('e', 'r', 'd') OR (t.typtype = 'c' AND tc.relkind = 'c'))
  AND ${notExtensionMember('t.oid', 'pg_type')}
ORDER BY n.nspname, t.typname''';

const _multirangeJoins = '''
LEFT JOIN pg_catalog.pg_type mt ON mt.oid = r.rngmultitypid
LEFT JOIN pg_catalog.pg_namespace mn ON mn.oid = mt.typnamespace
''';

/// Attributes of composite types (`$1` type OID array).
const typeAttributesSql = r'''
SELECT t.oid AS relid, a.attname,
       pg_catalog.format_type(a.atttypid, a.atttypmod) AS type,
       CASE WHEN a.attcollation <> at.typcollation AND a.attcollation <> 0
            THEN pg_catalog.quote_ident(cn.nspname) || '.' || pg_catalog.quote_ident(co.collname) END AS collation
FROM pg_catalog.pg_type t
JOIN pg_catalog.pg_attribute a ON a.attrelid = t.typrelid
JOIN pg_catalog.pg_type at ON at.oid = a.atttypid
LEFT JOIN pg_catalog.pg_collation co ON co.oid = a.attcollation
LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid = co.collnamespace
WHERE t.oid = ANY ($1::pg_catalog.oid[])
  AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY t.oid, a.attnum''';

/// CHECK constraints of domains (`$1` type OID array).
const domainConstraintsSql = r'''
SELECT con.contypid AS relid, con.conname, con.convalidated,
       pg_catalog.pg_get_constraintdef(con.oid, true) AS def
FROM pg_catalog.pg_constraint con
WHERE con.contypid = ANY ($1::pg_catalog.oid[])
  AND con.contype = 'c'
ORDER BY con.contypid, con.conname''';

/// Full `pg_aggregate` rows (`$1` routine OID array).
const aggregatesSql = r'''
SELECT a.aggfnoid::pg_catalog.oid AS relid, a.aggkind,
       a.aggtransfn::pg_catalog.regproc::pg_catalog.text AS sfunc,
       pg_catalog.format_type(a.aggtranstype, NULL) AS stype,
       a.aggtransspace AS sspace,
       CASE WHEN a.aggfinalfn <> 0 THEN a.aggfinalfn::pg_catalog.regproc::pg_catalog.text END AS finalfunc,
       a.aggfinalextra, a.aggfinalmodify,
       CASE WHEN a.aggcombinefn <> 0 THEN a.aggcombinefn::pg_catalog.regproc::pg_catalog.text END AS combinefunc,
       CASE WHEN a.aggserialfn <> 0 THEN a.aggserialfn::pg_catalog.regproc::pg_catalog.text END AS serialfunc,
       CASE WHEN a.aggdeserialfn <> 0 THEN a.aggdeserialfn::pg_catalog.regproc::pg_catalog.text END AS deserialfunc,
       a.agginitval,
       CASE WHEN a.aggmtransfn <> 0 THEN a.aggmtransfn::pg_catalog.regproc::pg_catalog.text END AS msfunc,
       CASE WHEN a.aggminvtransfn <> 0 THEN a.aggminvtransfn::pg_catalog.regproc::pg_catalog.text END AS minvfunc,
       CASE WHEN a.aggmtranstype <> 0 THEN pg_catalog.format_type(a.aggmtranstype, NULL) END AS mstype,
       a.aggmtransspace AS msspace,
       CASE WHEN a.aggmfinalfn <> 0 THEN a.aggmfinalfn::pg_catalog.regproc::pg_catalog.text END AS mfinalfunc,
       a.aggmfinalextra, a.aggmfinalmodify,
       a.aggminitval,
       CASE WHEN a.aggsortop <> 0
            THEN pg_catalog.quote_ident(opn.nspname) || '.' || op.oprname END AS sortop,
       p.proparallel
FROM pg_catalog.pg_aggregate a
JOIN pg_catalog.pg_proc p ON p.oid = a.aggfnoid
LEFT JOIN pg_catalog.pg_operator op ON op.oid = a.aggsortop
LEFT JOIN pg_catalog.pg_namespace opn ON opn.oid = op.oprnamespace
WHERE a.aggfnoid = ANY ($1::pg_catalog.oid[])''';

/// Extensions installed in the `$1` schemas, plus (with `$2 = 't'`, a
/// whole-database dump) those in `pg_catalog` other than plpgsql.
/// `has_config` marks extensions with configuration tables, whose data a
/// v1 dump doesn't include.
const extensionsSql = r'''
SELECT e.oid AS relid, e.extname AS name, n.nspname AS schema,
       d.description AS comment,
       (e.extconfig IS NOT NULL) AS has_config
FROM pg_catalog.pg_extension e
JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
LEFT JOIN pg_catalog.pg_description d ON d.objoid = e.oid AND d.objsubid = 0
     AND d.classoid = 'pg_catalog.pg_extension'::pg_catalog.regclass
WHERE e.extnamespace = ANY ($1::pg_catalog.oid[])
   OR ($2::pg_catalog.bool AND n.nspname = 'pg_catalog' AND e.extname <> 'plpgsql')
ORDER BY e.extname''';

/// `pg_default_acl` entries for the `$1` schemas, plus (with `$2 = 't'`)
/// the database-wide ones.
const defaultPrivilegesSql = r'''
SELECT pg_catalog.pg_get_userbyid(d.defaclrole) AS role,
       n.nspname AS schema,
       d.defaclobjtype AS objtype,
       CASE WHEN a.grantee = 0 THEN 'PUBLIC'
            ELSE pg_catalog.quote_ident(pg_catalog.pg_get_userbyid(a.grantee)) END AS grantee,
       a.privilege_type,
       a.is_grantable
FROM pg_catalog.pg_default_acl d
LEFT JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace
CROSS JOIN LATERAL pg_catalog.aclexplode(d.defaclacl) a
WHERE d.defaclnamespace = ANY ($1::pg_catalog.oid[])
   OR ($2::pg_catalog.bool AND d.defaclnamespace = 0)
ORDER BY 1, 2, 3, 4, 5''';

/// Dependency edges between user objects, each end normalized to the
/// object a dump creates: a view's `_RETURN` rule, a column default and a
/// CHECK constraint stand for their table; a relation's row type and an
/// array (or, PG 14+, multirange) type stand for the relation or element
/// type; a composite type's `pg_class` row stands for the type.
///
/// `kind`/`key` is the dependent object (`rel` pg_class OID, `type`
/// pg_type OID, `proc` pg_proc OID), `ref_kind`/`ref_key` what it needs.
/// `via` is `default` (with `attnum`) when a column default made the edge.
/// Sequences OWNED BY a column (`a` edges from a sequence) are left out:
/// OWNED BY is written after the table, not before the sequence.
String dependenciesSql(int serverVersionNum) =>
    '''
WITH obj AS (
  SELECT 'pg_catalog.pg_class'::pg_catalog.regclass AS classid, c.oid AS objid,
         CASE WHEN c.relkind = 'c' THEN 'type' ELSE 'rel' END AS kind,
         CASE WHEN c.relkind = 'c' THEN c.reltype ELSE c.oid END AS key,
         0 AS attnum, 'class' AS via, c.relkind::pg_catalog.text AS relkind
  FROM pg_catalog.pg_class c WHERE c.oid >= 16384
  UNION ALL
  SELECT 'pg_catalog.pg_rewrite'::pg_catalog.regclass, r.oid, 'rel', r.ev_class, 0, 'rule', ''
  FROM pg_catalog.pg_rewrite r WHERE r.oid >= 16384 AND r.rulename = '_RETURN'
  UNION ALL
  SELECT 'pg_catalog.pg_attrdef'::pg_catalog.regclass, ad.oid, 'rel', ad.adrelid, ad.adnum, 'default', ''
  FROM pg_catalog.pg_attrdef ad WHERE ad.oid >= 16384
  UNION ALL
  SELECT 'pg_catalog.pg_constraint'::pg_catalog.regclass, con.oid,
         CASE WHEN con.conrelid <> 0 THEN 'rel' ELSE 'type' END,
         CASE WHEN con.conrelid <> 0 THEN con.conrelid ELSE con.contypid END, 0, 'constraint', ''
  FROM pg_catalog.pg_constraint con WHERE con.oid >= 16384 AND con.contype = 'c'
  UNION ALL
  SELECT 'pg_catalog.pg_type'::pg_catalog.regclass, t.oid,
         CASE WHEN rc.relkind IS NOT NULL AND rc.relkind <> 'c' THEN 'rel' ELSE 'type' END,
         CASE WHEN rc.relkind IS NOT NULL AND rc.relkind <> 'c' THEN rc.oid ELSE bt.oid END,
         0, 'type', ''
  FROM pg_catalog.pg_type t
  LEFT JOIN pg_catalog.pg_type e ON e.typarray = t.oid
  ${serverVersionNum >= 140000 ? 'LEFT JOIN pg_catalog.pg_range mr ON mr.rngmultitypid = t.oid' : ''}
  JOIN pg_catalog.pg_type bt ON bt.oid = COALESCE(${serverVersionNum >= 140000 ? 'mr.rngtypid, ' : ''}e.oid, t.oid)
  LEFT JOIN pg_catalog.pg_class rc ON rc.oid = bt.typrelid
  WHERE t.oid >= 16384
  UNION ALL
  SELECT 'pg_catalog.pg_proc'::pg_catalog.regclass, p.oid, 'proc', p.oid, 0, 'proc', ''
  FROM pg_catalog.pg_proc p WHERE p.oid >= 16384
)
SELECT DISTINCT o.kind, o.key, o.via, o.attnum, r.kind AS ref_kind, r.key AS ref_key
FROM pg_catalog.pg_depend d
JOIN obj o ON o.classid = d.classid AND o.objid = d.objid
JOIN obj r ON r.classid = d.refclassid AND r.objid = d.refobjid
WHERE d.deptype IN ('n', 'a')
  AND d.objid >= 16384 AND d.refobjid >= 16384
  AND NOT (d.deptype = 'a' AND o.relkind = 'S')
  AND NOT (o.kind = r.kind AND o.key = r.key)''';

/// Counts of objects a v1 dump does not write, for the file header and
/// the result screen. `$1` is the dumped schemas (OID array).
const skippedCountsSql = r'''
SELECT
  (SELECT pg_catalog.count(*) FROM pg_catalog.pg_largeobject_metadata) AS large_objects,
  (SELECT pg_catalog.count(*) FROM pg_catalog.pg_publication) AS publications,
  (SELECT pg_catalog.count(*) FROM pg_catalog.pg_subscription s
     WHERE s.subdbid = (SELECT oid FROM pg_catalog.pg_database
                        WHERE datname = pg_catalog.current_database())) AS subscriptions,
  (SELECT pg_catalog.count(*) FROM pg_catalog.pg_event_trigger) AS event_triggers,
  (SELECT pg_catalog.count(*) FROM pg_catalog.pg_foreign_server) AS foreign_servers,
  (SELECT pg_catalog.count(*) FROM pg_catalog.pg_class c
     WHERE c.relkind = 'f' AND c.relnamespace = ANY ($1::pg_catalog.oid[])) AS foreign_tables,
  (SELECT pg_catalog.count(*) FROM pg_catalog.pg_type t
     WHERE t.typtype IN ('b', 'p') AND t.typnamespace = ANY ($1::pg_catalog.oid[])
       AND t.oid >= 16384
       AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend x
                       WHERE x.classid = 'pg_catalog.pg_type'::pg_catalog.regclass
                         AND x.objid = t.oid AND x.deptype IN ('e', 'i'))) AS base_types,
  (SELECT pg_catalog.count(*) FROM pg_catalog.pg_collation co
     WHERE co.collnamespace = ANY ($1::pg_catalog.oid[]) AND co.oid >= 16384) AS collations,
  (SELECT pg_catalog.count(*) FROM pg_catalog.pg_operator o
     WHERE o.oprnamespace = ANY ($1::pg_catalog.oid[]) AND o.oid >= 16384
       AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend x
                       WHERE x.classid = 'pg_catalog.pg_operator'::pg_catalog.regclass
                         AND x.objid = o.oid AND x.deptype = 'e')) AS operators,
  (SELECT pg_catalog.count(*) FROM pg_catalog.pg_ts_config t
     WHERE t.cfgnamespace = ANY ($1::pg_catalog.oid[]) AND t.oid >= 16384) AS text_search_configs''';
