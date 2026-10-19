// File: object_ddl_assembler.dart
// Purpose: Builds function/procedure, sequence and index DDL from parsed
// rows. Pure: no I/O. Moved from the dabase app in 0.6.0.

import 'package:dabase_postgresql/src/ddl/ddl_rows.dart';
import 'package:dabase_postgresql/src/ddl/ddl_statements.dart';
import 'package:dabase_postgresql/src/ddl/object_ddl_rows.dart';
import 'package:dabase_postgresql/src/sql/sql_quoting.dart';

/// Functions, procedures, window functions and (as a note) aggregates.
final class RoutineDdlAssembler {
  /// Creates an assembler.
  const RoutineDdlAssembler();

  /// The viewer text of [header]. [aggregate] is the `pg_aggregate` row
  /// when [header] is an aggregate.
  String assemble(
    RoutineHeader header, {
    AggregateRow? aggregate,
    List<GrantRow> grants = const [],
  }) {
    final h = header;
    final signature = '${qualifiedName(h.schema, h.name)}(${h.identityArgs})';
    final kind = switch (h.kind) {
      'p' => 'PROCEDURE',
      'a' => 'AGGREGATE',
      _ => 'FUNCTION',
    };
    final def = h.def;
    final script = DdlScript()
      ..add(
        h.kind == 'a' || def == null
            ? _aggregateNote(signature, aggregate)
            : [terminate(def)],
      )
      ..add(ownerStatement(kind, signature, h.owner))
      // GRANT ... ON FUNCTION also covers aggregates.
      ..add(
        grantStatements(
          grants,
          '${kind == 'PROCEDURE' ? 'PROCEDURE' : 'FUNCTION'} $signature',
        ),
      )
      ..add(commentStatement(kind, signature, h.comment));
    return script.toString();
  }

  /// CREATE AGGREGATE is not rebuilt in v1: show its parts as comments.
  static List<String> _aggregateNote(String signature, AggregateRow? a) => [
    '-- aggregate $signature',
    '-- CREATE AGGREGATE is not generated; its definition:',
    if (a != null) ...[
      if (a.kind == 'o') '--   kind: ordered-set',
      if (a.kind == 'h') '--   kind: hypothetical-set',
      '--   sfunc: ${a.transitionFunction}',
      '--   stype: ${a.stateType}',
      if (a.finalFunction case final f?) '--   finalfunc: $f',
      if (a.combineFunction case final f?) '--   combinefunc: $f',
      if (a.initialValue case final v?) '--   initcond: ${quoteLiteral(v)}',
    ],
  ];
}

/// Sequences (free, serial-owned and, as a note, identity sequences).
final class SequenceDdlAssembler {
  /// Creates an assembler.
  const SequenceDdlAssembler();

  /// `schema.table.column` owning [s], or `null`.
  static String? owningColumn(SequenceRow s) =>
      switch ((s.ownedByTable, s.ownedByColumn)) {
        (final table?, final column?) =>
          '${qualifiedName(s.ownedBySchema ?? s.schema, table)}'
              '.${quoteIdent(column)}',
        _ => null,
      };

  /// `CREATE [UNLOGGED] SEQUENCE ...;` with every option spelled out.
  String createStatement(SequenceRow s) => [
    'CREATE ${s.isUnlogged ? 'UNLOGGED ' : ''}SEQUENCE ${_name(s)}',
    '    AS ${s.dataType}',
    '    START WITH ${s.start}',
    '    INCREMENT BY ${s.increment}',
    '    MINVALUE ${s.minValue}',
    '    MAXVALUE ${s.maxValue}',
    '    CACHE ${s.cache}',
    '    ${s.cycle ? 'CYCLE' : 'NO CYCLE'};',
  ].join('\n');

  static String _name(SequenceRow s) => qualifiedName(s.schema, s.name);

  /// `ALTER SEQUENCE ... OWNED BY ...;` for a serial-owned sequence.
  List<String> ownedByStatement(SequenceRow s) => [
    if (s.ownedKind == 'a')
      if (owningColumn(s) case final column?)
        'ALTER SEQUENCE ${qualifiedName(s.schema, s.name)} OWNED BY $column;',
  ];

  /// The viewer text of [s].
  String assemble(SequenceRow s, {List<GrantRow> grants = const []}) {
    final sequence = qualifiedName(s.schema, s.name);
    final owningColumn = SequenceDdlAssembler.owningColumn(s);
    if (s.ownedKind == 'i') {
      // Identity sequences are part of their column's definition.
      final column = owningColumn ?? '(unknown)';
      return [
        '-- $sequence is the identity sequence of column $column.',
        "-- It is created by the column's GENERATED ... AS IDENTITY clause;",
        "-- see that table's DDL.",
        '',
      ].join('\n');
    }
    final script = DdlScript()
      ..add([createStatement(s)])
      ..add(ownedByStatement(s))
      ..add(ownerStatement('SEQUENCE', sequence, s.owner))
      ..add(grantStatements(grants, 'SEQUENCE $sequence'))
      ..add(commentStatement('SEQUENCE', sequence, s.comment));
    return script.toString();
  }
}

/// A standalone index.
final class IndexDdlAssembler {
  /// Creates an assembler.
  const IndexDdlAssembler();

  /// The viewer text of [index].
  String assemble(IndexHeader index) {
    final script = DdlScript()
      ..add([
        if (!index.isValid) '-- INVALID (failed CREATE INDEX CONCURRENTLY)',
        terminate(index.def),
      ])
      ..add(
        commentStatement(
          'INDEX',
          qualifiedName(index.schema, index.name),
          index.comment,
        ),
      );
    return script.toString();
  }
}
