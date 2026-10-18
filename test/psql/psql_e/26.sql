SELECT n.nspname as "Schema",
  p.proname as "Name",
  pg_catalog.pg_get_function_result(p.oid) as "Result data type",
  pg_catalog.pg_get_function_arguments(p.oid) as "Argument data types",
 CASE p.prokind
  WHEN 'a' THEN 'agg'
  WHEN 'w' THEN 'window'
  WHEN 'p' THEN 'proc'
  ELSE 'func'
 END as "Type"
FROM pg_catalog.pg_proc p
     LEFT JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     LEFT JOIN pg_catalog.pg_type t0 ON t0.oid = p.proargtypes[0]
     LEFT JOIN pg_catalog.pg_namespace nt0 ON nt0.oid = t0.typnamespace
     LEFT JOIN pg_catalog.pg_type t1 ON t1.oid = p.proargtypes[1]
     LEFT JOIN pg_catalog.pg_namespace nt1 ON nt1.oid = t1.typnamespace
WHERE p.proname OPERATOR(pg_catalog.~) '^(foo)$' COLLATE pg_catalog.default
  AND pg_catalog.pg_function_is_visible(p.oid)
  AND (t0.typname OPERATOR(pg_catalog.~) '^(int4)$' COLLATE pg_catalog.default
        OR pg_catalog.format_type(t0.oid, NULL) OPERATOR(pg_catalog.~) '^(int4)$' COLLATE pg_catalog.default)
  AND pg_catalog.pg_type_is_visible(t0.oid)
  AND t1.typname IS NULL
ORDER BY 1, 2, 4;
