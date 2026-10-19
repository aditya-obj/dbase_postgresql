// File: ddl_statements.dart
// Purpose: Statement emitters shared by the assemblers: grants, owner,
// comments, indexes, triggers and rules, plus the script builder that
// joins them into the viewer text. Moved from the dabase app in 0.6.0.

import 'package:dabase_postgresql/src/ddl/ddl_rows.dart';
import 'package:dabase_postgresql/src/sql/sql_quoting.dart';

/// Collects statement groups; groups are separated by a blank line.
final class DdlScript {
  /// Creates an empty script.
  DdlScript();

  final List<List<String>> _groups = [];

  /// Adds a group; empty groups are dropped.
  void add(Iterable<String> statements) {
    final group = statements.toList();
    if (group.isNotEmpty) _groups.add(group);
  }

  @override
  String toString() => _groups.isEmpty
      ? ''
      : '${_groups.map((g) => g.join('\n')).join('\n\n')}\n';
}

/// [def] with trailing whitespace removed and exactly one trailing `;`.
String terminate(String def) {
  var text = def.trimRight();
  while (text.endsWith(';')) {
    text = text.substring(0, text.length - 1).trimRight();
  }
  return '$text;';
}

/// [def] with its trailing `;` (and whitespace) removed.
String unterminate(String def) {
  final text = terminate(def);
  return text.substring(0, text.length - 1);
}

/// `ALTER <kind> <target> OWNER TO <owner>;`, or nothing without an owner.
List<String> ownerStatement(String kind, String target, String? owner) => [
  if (owner != null) 'ALTER $kind $target OWNER TO ${quoteIdent(owner)};',
];

/// `COMMENT ON <kind> <target> IS '...';`, or nothing without a comment.
List<String> commentStatement(String kind, String target, String? comment) => [
  if (comment != null) 'COMMENT ON $kind $target IS ${quoteLiteral(comment)};',
];

/// GRANT statements for [rows] on [target] (e.g. `TABLE s.t`).
///
/// The owner's rows are skipped: they are implicit. Privileges are grouped
/// per grantee, with a separate statement for those held WITH GRANT
/// OPTION. Exact REVOKE parity with pg_dump (diffing against `acldefault`)
/// is a v2 item.
List<String> grantStatements(List<GrantRow> rows, String target) {
  final groups = <(String, bool), List<String>>{};
  for (final row in rows) {
    if (row.isOwner) continue;
    (groups[(row.grantee, row.isGrantable)] ??= []).add(row.privilege);
  }
  return [
    for (final MapEntry(key: (grantee, grantable), value: privileges)
        in groups.entries)
      [
        'GRANT ${privileges.join(', ')} ON $target TO $grantee',
        if (grantable) ' WITH GRANT OPTION',
        ';',
      ].join(),
  ];
}

/// CREATE INDEX statements for indexes no constraint owns. An invalid
/// index (a failed CREATE INDEX CONCURRENTLY) is marked with a comment.
List<String> createIndexStatements(List<IndexRow> indexes) => [
  for (final index in indexes)
    if (!index.isConstraintIndex) ...[
      if (!index.isValid) '-- INVALID (failed CREATE INDEX CONCURRENTLY)',
      terminate(index.def),
    ],
];

/// `ALTER ... CLUSTER ON` for the clustered index, if any.
List<String> clusterStatements(List<IndexRow> indexes, String alterTarget) => [
  for (final index in indexes)
    if (index.isClustered)
      'ALTER $alterTarget CLUSTER ON ${quoteIdent(index.name)};',
];

/// COMMENT ON INDEX for indexes no constraint owns.
List<String> indexCommentStatements(List<IndexRow> indexes, String schema) => [
  for (final index in indexes)
    if (!index.isConstraintIndex)
      ...commentStatement(
        'INDEX',
        qualifiedName(schema, index.name),
        index.comment,
      ),
];

/// CREATE TRIGGER statements, each followed by the ALTER that restores a
/// non-default firing state.
List<String> triggerStatements(List<TriggerRow> triggers, String alterTarget) {
  String? state(TriggerRow t) => switch (t.enabled) {
    'D' => 'DISABLE TRIGGER',
    'R' => 'ENABLE REPLICA TRIGGER',
    'A' => 'ENABLE ALWAYS TRIGGER',
    _ => null,
  };
  return [
    for (final trigger in triggers) ...[
      terminate(trigger.def),
      if (state(trigger) case final s?)
        'ALTER $alterTarget $s ${quoteIdent(trigger.name)};',
    ],
  ];
}

/// CREATE RULE statements.
List<String> ruleStatements(List<RuleRow> rules) => [
  for (final rule in rules) terminate(rule.def),
];
