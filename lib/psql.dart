// File: psql.dart
// Purpose: Narrow entrypoint for the psql-style console pieces: the
// backslash-command parser, the input scanner, name patterns, the
// describe (\d family) queries, the table printer and message formatting.

/// psql's console logic in pure Dart: parse backslash commands and their
/// arguments as `psqlscanslash.l` does, feed input lines like psql's main
/// loop, turn `\d`-style name patterns into SQL like
/// `processSQLNamePattern`, build and run the `describe.c` catalog
/// queries (PostgreSQL 13–18), and print results in psql's aligned,
/// wrapped, expanded, unaligned and CSV formats. No server and no
/// `dart:io`: catalog queries run through a [PsqlQuery] callback.
library;

import 'package:dabase_postgresql/src/psql/describe/psql_query.dart'
    show PsqlQuery;

export 'src/psql/describe/describe_context.dart' show DescribeContext;
export 'src/psql/describe/describer.dart'
    show describeArgumentCount, isDescribeCommand, runDescribe;
export 'src/psql/describe/function_role_sql.dart'
    show listFunctionsSql, listRolesSql, rolesTable;
export 'src/psql/describe/list_sql.dart'
    show
        ListContext,
        RelationKinds,
        listDatabasesSql,
        listExtensionsSql,
        listSchemasSql,
        listTablesSql;
export 'src/psql/describe/psql_query.dart'
    show
        PsqlMessageOutput,
        PsqlOutput,
        PsqlQuery,
        PsqlResult,
        PsqlTableOutput,
        queryTable,
        serverVersionNumber;
export 'src/psql/describe/table_details.dart'
    show describeOneTable, describeTableDetails, findRelationsSql;
export 'src/psql/describe/type_privilege_sql.dart'
    show listDomainsSql, listTypesSql, mapTypenamePattern, permissionsSql;
export 'src/psql/meta_command.dart'
    show
        MetaArg,
        MetaCommand,
        MetaCommandFormatException,
        dequoteDowncaseIdentifier,
        parseMetaCommand;
export 'src/psql/name_pattern.dart'
    show
        NamePatternClause,
        NamePatternException,
        PatternRegex,
        patternToRegex,
        processNamePattern;
export 'src/psql/print/display_width.dart'
    show CellLine, CellSize, displayWidth, formatCell, measureCell, runeWidth;
export 'src/psql/print/print_table.dart'
    show
        ExpandedMode,
        PrintAlign,
        PrintFormat,
        PrintOptions,
        PrintTable,
        alignmentForType,
        rightAlignedTypeOids;
export 'src/psql/print/table_printer.dart' show printTable;
export 'src/psql/psql_conninfo.dart' show formatConnInfo;
export 'src/psql/psql_console.dart'
    show
        PsqlCommandDone,
        PsqlCommandResult,
        PsqlConnInfoRequest,
        PsqlConsole,
        PsqlDescribeRequest,
        PsqlQuitRequest,
        parseBool,
        unsupportedCommands;
export 'src/psql/psql_help.dart' show psqlHelpText;
export 'src/psql/psql_input.dart'
    show
        PsqlInputItem,
        PsqlInputScanner,
        PsqlMetaItem,
        PsqlPromptState,
        PsqlQueryItem,
        PsqlTextItem;
export 'src/psql/psql_messages.dart' show formatServerMessage, formatTiming;
export 'src/psql/sql_literal.dart' show sqlStringLiteral;
