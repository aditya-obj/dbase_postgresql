# psql -E queries

Each `.sql` file is the first catalog query real `psql` 17.11 printed with
`-E` (ECHO_HIDDEN) for the command in `index.tsv`, against a PostgreSQL
18.6 server. `describe_sql_test.dart` checks the library builds the same
text for server version 18.

Two commands are left out because psql 18 (which the library follows)
changed them: `\df+` gained the `Leakproof?` column and `\dx` the
`Default version` column.

To regenerate one: `psql -X -E -q "$URL" -c '\dt'` and copy the text
between `/******** QUERY *********/` and the closing comment.
