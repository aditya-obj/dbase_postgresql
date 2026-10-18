SELECT n.nspname as "Schema",
  pg_catalog.format_type(t.oid, NULL) AS "Name",
  pg_catalog.obj_description(t.oid, 'pg_type') as "Description"
FROM pg_catalog.pg_type t
     LEFT JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
WHERE (t.typrelid = 0 OR (SELECT c.relkind = 'c' FROM pg_catalog.pg_class c WHERE c.oid = t.typrelid))
  AND (t.typname OPERATOR(pg_catalog.~) E'^(integer\\[])$' COLLATE pg_catalog.default
        OR pg_catalog.format_type(t.oid, NULL) OPERATOR(pg_catalog.~) E'^(integer\\[])$' COLLATE pg_catalog.default)
  AND pg_catalog.pg_type_is_visible(t.oid)
ORDER BY 1, 2;
