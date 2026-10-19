// File: aggregate_ddl.dart
// Purpose: The full `pg_aggregate` row of a user aggregate and the
// `CREATE AGGREGATE` statement rebuilt from it (as pg_dump's
// dumpAgg does, without its pre-11 branches).

import 'package:dabase_postgresql/src/catalog/catalog_query.dart';
import 'package:dabase_postgresql/src/sql/sql_quoting.dart';

/// Every `pg_aggregate` field CREATE AGGREGATE can set. Function and type
/// names are server text (`regproc` / `format_type`), already quoted and
/// schema-qualified where the empty search_path needs it.
final class AggregateDefinition {
  /// Creates an aggregate definition.
  const AggregateDefinition({
    required this.transitionFunction,
    required this.stateType,
    this.kind = 'n',
    this.stateSpace = 0,
    this.finalFunction,
    this.finalExtra = false,
    this.finalModify = 'r',
    this.combineFunction,
    this.serialFunction,
    this.deserialFunction,
    this.initialValue,
    this.movingTransitionFunction,
    this.movingInverseFunction,
    this.movingStateType,
    this.movingStateSpace = 0,
    this.movingFinalFunction,
    this.movingFinalExtra = false,
    this.movingFinalModify = 'r',
    this.movingInitialValue,
    this.sortOperator,
    this.parallel = 'u',
  });

  /// Reads the `aggregatesQuery` columns.
  factory AggregateDefinition.fromRow(CatalogRow row) => AggregateDefinition(
    transitionFunction: requireText(row, 'sfunc'),
    stateType: requireText(row, 'stype'),
    kind: row['aggkind'] ?? 'n',
    stateSpace: pgInt(row['sspace']) ?? 0,
    finalFunction: row['finalfunc'],
    finalExtra: pgBool(row['aggfinalextra']) ?? false,
    finalModify: row['aggfinalmodify'] ?? 'r',
    combineFunction: row['combinefunc'],
    serialFunction: row['serialfunc'],
    deserialFunction: row['deserialfunc'],
    initialValue: row['agginitval'],
    movingTransitionFunction: row['msfunc'],
    movingInverseFunction: row['minvfunc'],
    movingStateType: row['mstype'],
    movingStateSpace: pgInt(row['msspace']) ?? 0,
    movingFinalFunction: row['mfinalfunc'],
    movingFinalExtra: pgBool(row['aggmfinalextra']) ?? false,
    movingFinalModify: row['aggmfinalmodify'] ?? 'r',
    movingInitialValue: row['aggminitval'],
    sortOperator: row['sortop'],
    parallel: row['proparallel'] ?? 'u',
  );

  /// SFUNC.
  final String transitionFunction;

  /// STYPE.
  final String stateType;

  /// `n` normal, `o` ordered-set, `h` hypothetical-set.
  final String kind;

  /// SSPACE (0: not set).
  final int stateSpace;

  /// FINALFUNC.
  final String? finalFunction;

  /// FINALFUNC_EXTRA.
  final bool finalExtra;

  /// FINALFUNC_MODIFY: `r` READ_ONLY, `s` SHAREABLE, `w` READ_WRITE.
  final String finalModify;

  /// COMBINEFUNC.
  final String? combineFunction;

  /// SERIALFUNC.
  final String? serialFunction;

  /// DESERIALFUNC.
  final String? deserialFunction;

  /// INITCOND.
  final String? initialValue;

  /// MSFUNC.
  final String? movingTransitionFunction;

  /// MINVFUNC.
  final String? movingInverseFunction;

  /// MSTYPE.
  final String? movingStateType;

  /// MSSPACE (0: not set).
  final int movingStateSpace;

  /// MFINALFUNC.
  final String? movingFinalFunction;

  /// MFINALFUNC_EXTRA.
  final bool movingFinalExtra;

  /// MFINALFUNC_MODIFY.
  final String movingFinalModify;

  /// MINITCOND.
  final String? movingInitialValue;

  /// SORTOP as `schema.operator`.
  final String? sortOperator;

  /// PARALLEL: `s` SAFE, `r` RESTRICTED, `u` UNSAFE (the default).
  final String parallel;
}

String _modify(String code) => switch (code) {
  's' => 'SHAREABLE',
  'w' => 'READ_WRITE',
  _ => 'READ_ONLY',
};

/// `CREATE AGGREGATE schema.name(identityArgs) (...);`.
///
/// [identityArgs] is `pg_get_function_identity_arguments`, which already
/// prints `ORDER BY` for ordered-set aggregates.
String createAggregateStatement(
  String schema,
  String name,
  String identityArgs,
  AggregateDefinition a,
) {
  final options = [
    'SFUNC = ${a.transitionFunction}',
    'STYPE = ${a.stateType}',
    if (a.stateSpace != 0) 'SSPACE = ${a.stateSpace}',
    if (a.finalFunction case final f?) ...[
      'FINALFUNC = $f',
      if (a.finalExtra) 'FINALFUNC_EXTRA',
      'FINALFUNC_MODIFY = ${_modify(a.finalModify)}',
    ],
    if (a.combineFunction case final f?) 'COMBINEFUNC = $f',
    if (a.serialFunction case final f?) 'SERIALFUNC = $f',
    if (a.deserialFunction case final f?) 'DESERIALFUNC = $f',
    if (a.initialValue case final v?) 'INITCOND = ${quoteLiteral(v)}',
    if (a.movingTransitionFunction case final f?) 'MSFUNC = $f',
    if (a.movingInverseFunction case final f?) 'MINVFUNC = $f',
    if (a.movingStateType case final t?) 'MSTYPE = $t',
    if (a.movingStateSpace != 0) 'MSSPACE = ${a.movingStateSpace}',
    if (a.movingFinalFunction case final f?) ...[
      'MFINALFUNC = $f',
      if (a.movingFinalExtra) 'MFINALFUNC_EXTRA',
      'MFINALFUNC_MODIFY = ${_modify(a.movingFinalModify)}',
    ],
    if (a.movingInitialValue case final v?) 'MINITCOND = ${quoteLiteral(v)}',
    if (a.sortOperator case final op?) 'SORTOP = OPERATOR($op)',
    if (a.parallel == 's') 'PARALLEL = SAFE',
    if (a.parallel == 'r') 'PARALLEL = RESTRICTED',
    if (a.kind == 'h') 'HYPOTHETICAL',
  ];
  return 'CREATE AGGREGATE ${qualifiedName(schema, name)}($identityArgs) (\n'
      '${options.map((o) => '    $o').join(',\n')}\n);';
}
