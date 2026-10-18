// File: ddl.dart
// Purpose: Narrow entrypoint for DDL generation from catalog rows: the
// per-object recipe queries and row parsers, and the assemblers for
// tables, views, routines, sequences, indexes, types, aggregates,
// schemas, extensions and default privileges.

/// Generate pg_dump-like DDL from PostgreSQL catalog rows. The recipe
/// queries take one OID or an OID array (see [OidFilter]); the assemblers
/// are pure and print the same text as the dbase app's object viewer.
library;

import 'package:dbase_postgresql/src/ddl/table_ddl_queries.dart';

export 'src/ddl/aggregate_ddl.dart'
    show AggregateDefinition, createAggregateStatement;
export 'src/ddl/ddl_rows.dart'
    show ColumnCommentRow, GrantRow, IndexRow, RuleRow, TriggerRow, rowRelid;
export 'src/ddl/ddl_statements.dart'
    show
        DdlScript,
        clusterStatements,
        commentStatement,
        createIndexStatements,
        grantStatements,
        indexCommentStatements,
        ownerStatement,
        ruleStatements,
        terminate,
        triggerStatements,
        unterminate;
export 'src/ddl/namespace_ddl.dart'
    show
        DefaultPrivilegeRow,
        createExtensionStatement,
        createSchemaStatement,
        defaultPrivilegeStatements,
        schemaGrantStatements;
export 'src/ddl/object_ddl_assembler.dart'
    show IndexDdlAssembler, RoutineDdlAssembler, SequenceDdlAssembler;
export 'src/ddl/object_ddl_queries.dart'
    show
        aggregateSql,
        indexSql,
        relationColumnCommentsQuery,
        relationColumnCommentsSql,
        routineGrantsQuery,
        routineGrantsSql,
        routineHeaderQuery,
        routineHeaderSql,
        sequenceQuery,
        sequenceSql,
        viewHeaderQuery,
        viewHeaderSql;
export 'src/ddl/object_ddl_rows.dart'
    show AggregateRow, IndexHeader, RoutineHeader, SequenceRow, ViewHeader;
export 'src/ddl/table_ddl_assembler.dart'
    show TableDdlAssembler, TableDdlParts, TableDdlSource;
export 'src/ddl/table_ddl_queries.dart'
    show
        OidFilter,
        ddlBeginSql,
        ddlSettingsSql,
        oidMatch,
        relationGrantsQuery,
        relationGrantsSql,
        relationIndexesQuery,
        relationIndexesSql,
        relationRulesQuery,
        relationRulesSql,
        relationTriggersQuery,
        relationTriggersSql,
        tableColumnsSql,
        tableConstraintsSql,
        tableHeaderQuery,
        tableHeaderSql,
        tableIdentitiesQuery,
        tableIdentitiesSql,
        tableParentsQuery,
        tableParentsSql,
        tablePoliciesQuery,
        tablePoliciesSql,
        tableStatisticsQuery,
        tableStatisticsSql;
export 'src/ddl/table_ddl_rows.dart'
    show
        ColumnRow,
        ConstraintRow,
        IdentityRow,
        ParentRow,
        PolicyRow,
        TableHeader;
export 'src/ddl/type_ddl.dart'
    show DomainConstraintRow, TypeAttributeRow, TypeDdlAssembler, TypeRow;
export 'src/ddl/view_ddl_assembler.dart'
    show ViewDdlAssembler, ViewDdlParts, ViewDdlSource;
