# psql printer goldens

Each `.txt` file here is the exact output of real `psql` (17.11, `-X -q`)
for one query and a set of `\pset` options; `table_printer_golden_test.dart`
builds the same rows and checks `printTable` reproduces it byte for byte.

They were generated against a local test server (any PostgreSQL 13+; the
values don't depend on the server version) with this script. Pass the
output directory and set `URL` to your server:

```sh
#!/bin/bash
# Generates printer golden files with real psql (psql 17) against a server.
OUT=$1
URL="${URL:?set URL to a test server}"
Q_BASIC="select * from (values (1,'alpha'::text,1.5::numeric),(22,'b',NULL),(333,'gamma ray',-2.25)) t(id,name,amount);"
Q_UNI="select 'héllo'::text as name, '日本語'::text as cjk, '👍x'::text as emoji, E'é'::text as combining;"
Q_ML="select E'line1\nline two\nl3'::text as multi, 'x'::text as b, 7 as n;"
Q_WIDE="select 1 as id, 'The quick brown fox jumps over the lazy dog and keeps running far away'::text as description, 'short'::text as tag;"
Q_CTRL="select E'a\tb'::text as tab, E'cr\rhere'::text as cr, chr(1) || 'z' as ctl;"
Q_EMPTY="select 1 as a, 'x'::text as b where false;"
Q_ONE="select 42 as answer;"
run() { # name, pset commands, query
  printf '%s\n%s\n' "$2" "$3" | psql -X -q "$URL" -f - > "$OUT/$1.txt" 2>&1
}
run aligned_basic "" "$Q_BASIC"
run aligned_one_row "" "$Q_ONE"
run aligned_null "\pset null '(null)'" "$Q_BASIC"
run aligned_border0 "\pset border 0" "$Q_BASIC"
run aligned_border2 "\pset border 2" "$Q_BASIC"
run aligned_unicode "" "$Q_UNI"
run aligned_multiline "" "$Q_ML"
run aligned_multiline_border2 "\pset border 2" "$Q_ML"
run aligned_multiline_border0 "\pset border 0" "$Q_ML"
run aligned_control "" "$Q_CTRL"
run aligned_empty "" "$Q_EMPTY"
run aligned_title "\pset title 'My report'" "$Q_BASIC"
run aligned_no_footer "\pset footer off" "$Q_BASIC"
run tuples_only "\t on" "$Q_BASIC"
run wrapped_40 "\pset format wrapped
\pset columns 40" "$Q_WIDE"
run wrapped_40_border2 "\pset format wrapped
\pset columns 40
\pset border 2" "$Q_WIDE"
run expanded_basic "\x on" "$Q_BASIC"
run expanded_null "\x on
\pset null '(null)'" "$Q_BASIC"
run expanded_border0 "\x on
\pset border 0" "$Q_BASIC"
run expanded_border2 "\x on
\pset border 2" "$Q_BASIC"
run expanded_multiline "\x on" "$Q_ML"
run expanded_unicode "\x on" "$Q_UNI"
run expanded_empty "\x on" "$Q_EMPTY"
run expanded_wrapped_30 "\x on
\pset format wrapped
\pset columns 30" "$Q_WIDE"
run expanded_auto_narrow "\x auto
\pset columns 30" "$Q_WIDE"
run expanded_auto_wide "\x auto
\pset columns 200" "$Q_WIDE"
run unaligned_basic "\pset format unaligned" "$Q_BASIC"
run unaligned_expanded "\pset format unaligned
\x on" "$Q_BASIC"
run csv_basic "\pset format csv" "$Q_ML"
run csv_expanded "\pset format csv
\x on" "$Q_BASIC"
```
