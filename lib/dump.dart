// File: dump.dart
// Purpose: Narrow entrypoint for plain-SQL dumps and restores: the dump
// planner (sections and dependency order), the writer, COPY text
// encoding, the dump runner over a DumpConnection, and a streaming reader
// for restoring plain-SQL files.

/// Write and read plain-SQL dumps in pure Dart: [SqlDumper] runs a
/// pg_dump-like export (one REPEATABLE READ snapshot, bulk catalog read,
/// pg_depend ordering, data through a cursor re-encoded as COPY text) over
/// any [DumpConnection]; [SqlScriptReader] streams a dump back as
/// statements and COPY data for a restore.
library;

import 'package:dabase_postgresql/src/dump/sql_dumper.dart';
import 'package:dabase_postgresql/src/dump/sql_script_reader.dart';

export 'src/dump/copy_text.dart'
    show CopyTextEncoder, decodeCopyTextRow, encodeCopyTextRow;
export 'src/dump/dependency_order.dart' show DependencyOrder, dependencyOrder;
export 'src/dump/dump_options.dart'
    show DumpContent, DumpOptions, DumpWarning, DumpWarningCode;
export 'src/dump/dump_planner.dart'
    show DumpItem, DumpPlan, DumpPlanner, DumpSection;
export 'src/dump/dump_writer.dart' show DumpHeader, DumpWriter, dumpPreamble;
export 'src/dump/sql_dumper.dart'
    show
        DumpBatchSizing,
        DumpCancelledException,
        DumpConnection,
        DumpPhase,
        DumpProgress,
        DumpResult,
        DumpRowTooLargeException,
        DumpTableFailure,
        DumpTableState,
        DumpTableStatus,
        FetchedRows,
        SqlDumper,
        declareDumpCursorSql,
        dumpBeginSql,
        dumpCursorName,
        dumpSettingsSql,
        fetchDumpCursorSql,
        lockTablesSql,
        moveBackDumpCursorSql;
export 'src/dump/sql_script_reader.dart'
    show
        ScriptCopyData,
        ScriptCopyEnd,
        ScriptCopyStart,
        ScriptItem,
        ScriptMetaCommand,
        ScriptStatement,
        ScriptTocEntry,
        SqlScriptReader;
