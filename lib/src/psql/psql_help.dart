// File: psql_help.dart
// Purpose: The `\?` text for the commands this console supports, in
// psql's layout and wording.
//
// Wording from src/bin/psql/help.c (slashUsage) - PostgreSQL License,
// (c) 1996-2026 PostgreSQL Global Development Group. See
// THIRD_PARTY_NOTICES.

/// `\?` output: the supported subset of psql's backslash commands.
const String psqlHelpText = r'''
General
  \q                     quit the console
  \? [commands]          show help on backslash commands
  \h                     SQL command help (not included; see
                         https://www.postgresql.org/docs/current/sql-commands.html)

Query Buffer
  \g                     execute query (and send result to the console)
  \gx                    as \g, but forces expanded output mode
  \p                     show the contents of the query buffer
  \r                     reset (clear) the query buffer

Input/Output
  \echo [-n] [STRING]    write string to the console (-n for no newline)

Informational
  (options: S = show system objects, + = additional detail,
   x = expanded output)
  \d[Sx+]                list tables, views, and sequences
  \d[S+]  NAME           describe table, view, sequence, or index
  \dD[Sx+] [PATTERN]     list domains
  \df[anptwSx+] [FUNCPTRN [TYPEPTRN ...]]
                         list [only agg/normal/procedure/trigger/window] functions
  \dg[Sx+] [PATTERN]     list roles
  \di[Sx+] [PATTERN]     list indexes
  \dm[Sx+] [PATTERN]     list materialized views
  \dn[Sx+] [PATTERN]     list schemas
  \dp[Sx]  [PATTERN]     list table, view, and sequence access privileges
  \ds[Sx+] [PATTERN]     list sequences
  \dt[Sx+] [PATTERN]     list tables
  \dT[Sx+] [PATTERN]     list data types
  \du[Sx+] [PATTERN]     list roles
  \dv[Sx+] [PATTERN]     list views
  \dE[Sx+] [PATTERN]     list foreign tables
  \dx[x]   [PATTERN]     list extensions
  \l[x+]   [PATTERN]     list databases
  \z[Sx]   [PATTERN]     same as \dp

Formatting
  \a                     toggle between unaligned and aligned output mode
  \pset [NAME [VALUE]]   set table output option
                         (border|columns|csv_fieldsep|expanded|fieldsep|
                         footer|format|null|title|tuples_only)
  \t [on|off]            show only rows
  \x [on|off|auto]       toggle expanded output

Connection
  \conninfo              display information about current connection

Operating System
  \timing [on|off]       toggle timing of commands

Not available here: \copy, \!, \i, \o, \e, \gexec, \set and variables,
\c, \watch. Describe commands run inside your open transaction, as in
psql: if one fails there, the transaction is aborted.
''';
