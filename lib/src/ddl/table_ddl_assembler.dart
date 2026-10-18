// File: table_ddl_assembler.dart
// Purpose: Builds table DDL from the parsed recipe rows: the CREATE TABLE
// viewer text (emission rules and assembly order of the dbase Browse
// screen), and the same statements as separate parts for a dump, which
// moves keys, foreign keys, indexes and triggers after the data. Pure: no
// I/O, so it is unit-tested with hand-written rows. Moved from the dbase
// app in 0.6.0.

import 'package:dbase_postgresql/src/ddl/ddl_rows.dart';
import 'package:dbase_postgresql/src/ddl/ddl_statements.dart';
import 'package:dbase_postgresql/src/ddl/table_ddl_rows.dart';
import 'package:dbase_postgresql/src/sql/sql_quoting.dart';

/// Everything the table recipe fetched for one table.
final class TableDdlSource {
  /// Creates a table source.
  const TableDdlSource({
    required this.header,
    this.parents = const [],
    this.columns = const [],
    this.identities = const [],
    this.constraints = const [],
    this.indexes = const [],
    this.triggers = const [],
    this.rules = const [],
    this.statistics = const [],
    this.policies = const [],
    this.grants = const [],
  });

  /// Q-T1.
  final TableHeader header;

  /// Q-T2, in `inhseqno` order.
  final List<ParentRow> parents;

  /// Q-T3, in `attnum` order.
  final List<ColumnRow> columns;

  /// Q-T4.
  final List<IdentityRow> identities;

  /// Q-T5.
  final List<ConstraintRow> constraints;

  /// Every index of the table except partition children, constraint-owned
  /// ones included (they carry CLUSTER ON / REPLICA IDENTITY flags).
  final List<IndexRow> indexes;

  /// User triggers.
  final List<TriggerRow> triggers;

  /// Rules other than `_RETURN`.
  final List<RuleRow> rules;

  /// `pg_get_statisticsobjdef` texts.
  final List<String> statistics;

  /// Row-level security policies.
  final List<PolicyRow> policies;

  /// Q-T8 rows (only fetched when the table has an ACL).
  final List<GrantRow> grants;
}

/// The statements of one table, grouped by where a dump writes them.
final class TableDdlParts {
  /// Creates the parts.
  const TableDdlParts({
    required this.create,
    this.deferredDefaults = const [],
    this.keyConstraints = const [],
    this.trailingConstraints = const [],
    this.foreignKeys = const [],
    this.indexes = const [],
    this.clusterAndReplicaIdentity = const [],
    this.triggers = const [],
    this.rules = const [],
    this.statistics = const [],
    this.rowSecurity = const [],
    this.owner = const [],
    this.grants = const [],
    this.comments = const [],
  });

  /// `CREATE TABLE ...;`.
  final String create;

  /// `ALTER TABLE ... ALTER COLUMN ... SET DEFAULT ...;` for the columns
  /// whose default was moved out of CREATE TABLE.
  final List<String> deferredDefaults;

  /// PRIMARY KEY / UNIQUE / EXCLUDE as `ALTER TABLE ... ADD CONSTRAINT`
  /// (empty when they are written inline).
  final List<String> keyConstraints;

  /// Constraints that can't be inline: `NOT VALID` CHECKs and, on PG 18,
  /// NOT NULL constraints of columns not written in CREATE TABLE.
  final List<String> trailingConstraints;

  /// FOREIGN KEY constraints.
  final List<String> foreignKeys;

  /// CREATE INDEX for indexes no constraint owns.
  final List<String> indexes;

  /// CLUSTER ON and REPLICA IDENTITY.
  final List<String> clusterAndReplicaIdentity;

  /// CREATE TRIGGER (and the firing-state ALTERs).
  final List<String> triggers;

  /// CREATE RULE.
  final List<String> rules;

  /// CREATE STATISTICS.
  final List<String> statistics;

  /// ENABLE / FORCE ROW LEVEL SECURITY and CREATE POLICY.
  final List<String> rowSecurity;

  /// ALTER ... OWNER TO.
  final List<String> owner;

  /// GRANT statements.
  final List<String> grants;

  /// COMMENT ON the table, its columns, constraints and indexes.
  final List<String> comments;
}

/// Assembles table DDL. [serverVersionNum] decides where NOT NULL comes
/// from: `attnotnull` up to 17, `pg_constraint` `contype = 'n'` on 18+.
final class TableDdlAssembler {
  /// Creates an assembler for a server of [serverVersionNum].
  const TableDdlAssembler({required this.serverVersionNum});

  /// The server's `server_version_num`, e.g. `170004`.
  final int serverVersionNum;

  bool get _notNullIsConstraint => serverVersionNum >= 180000;

  /// The viewer text: every part, keys inline, one blank line between
  /// groups.
  String assemble(TableDdlSource source) {
    final p = parts(source);
    final script = DdlScript()
      ..add([p.create])
      ..add([...p.trailingConstraints, ...p.foreignKeys])
      ..add(p.indexes)
      ..add(p.clusterAndReplicaIdentity)
      ..add([...p.triggers, ...p.rules, ...p.statistics])
      ..add(p.rowSecurity)
      ..add(p.owner)
      ..add(p.grants)
      ..add(p.comments);
    return script.toString();
  }

  /// The statements of [source] by kind.
  ///
  /// With [keysInline] `false`, PRIMARY KEY, UNIQUE and EXCLUDE become
  /// [TableDdlParts.keyConstraints] instead of CREATE TABLE elements.
  /// Columns in [deferredDefaults] (attnums) get their DEFAULT from an
  /// ALTER TABLE in [TableDdlParts.deferredDefaults], which breaks a
  /// dependency cycle when the default calls a function that needs the
  /// table. Generated and identity columns are never deferred.
  TableDdlParts parts(
    TableDdlSource source, {
    bool keysInline = true,
    Set<int> deferredDefaults = const {},
  }) {
    final h = source.header;
    final table = qualifiedName(h.schema, h.name);
    final isForeign = h.relkind == 'f';
    final relationKind = isForeign ? 'FOREIGN TABLE' : 'TABLE';
    final alterTarget = '$relationKind $table';
    final local = source.constraints.where((c) => c.isLocal).toList();

    // Columns written into the CREATE statement (none for partitions; only
    // local ones for inheritance children).
    final emitted = h.isPartition
        ? const <ColumnRow>[]
        : source.columns.where((c) => c.isLocal).toList();
    final emittedAttnums = {for (final c in emitted) c.attnum};

    // PG18: validated NOT NULL constraints on emitted columns go inline.
    final inlineNotNull = <int, ConstraintRow>{
      if (_notNullIsConstraint)
        for (final c in local)
          if (c.type == 'n' && c.isValidated)
            if (c.attnum case final attnum?)
              if (emittedAttnums.contains(attnum)) attnum: c,
    };
    bool isKey(ConstraintRow c) => const {'p', 'u', 'x'}.contains(c.type);
    final inline = [
      for (final c in local)
        if ((keysInline && isKey(c)) || (c.type == 'c' && c.isValidated)) c,
    ];
    final keys = [
      if (!keysInline)
        for (final c in local)
          if (isKey(c)) c,
    ];
    final trailing = [
      for (final c in local)
        if ((c.type == 'n' && !inlineNotNull.containsValue(c)) ||
            (c.type != 'n' && c.type != 'f' && !c.isValidated))
          c,
    ];
    final foreignKeys = [
      for (final c in local)
        if (c.type == 'f') c,
    ];
    String addConstraint(ConstraintRow c) =>
        'ALTER $alterTarget ADD CONSTRAINT ${quoteIdent(c.name)} ${c.def};';

    final deferred = [
      for (final column in emitted)
        if (deferredDefaults.contains(column.attnum) &&
            column.generated.isEmpty &&
            column.identity.isEmpty)
          column,
    ];
    final deferredAttnums = {for (final c in deferred) c.attnum};

    final identities = {for (final i in source.identities) i.attnum: i};
    final elements = [
      for (final column in emitted)
        ?_column(
          column,
          h,
          identities[column.attnum],
          inlineNotNull,
          withDefault: !deferredAttnums.contains(column.attnum),
        ),
      for (final c in inline) 'CONSTRAINT ${quoteIdent(c.name)} ${c.def}',
    ];

    return TableDdlParts(
      create: _create(h, table, source.parents, elements),
      deferredDefaults: [
        for (final c in deferred)
          if (c.defaultExpr case final expr?)
            '$alterTarget ALTER COLUMN ${quoteIdent(c.name)}'.withSetDefault(
              expr,
            ),
      ],
      keyConstraints: [for (final c in keys) addConstraint(c)],
      trailingConstraints: [for (final c in trailing) addConstraint(c)],
      foreignKeys: [for (final c in foreignKeys) addConstraint(c)],
      indexes: createIndexStatements(source.indexes),
      clusterAndReplicaIdentity: [
        ...clusterStatements(source.indexes, alterTarget),
        ?_replicaIdentity(h, source.indexes, alterTarget),
      ],
      triggers: triggerStatements(source.triggers, alterTarget),
      rules: ruleStatements(source.rules),
      statistics: [for (final s in source.statistics) terminate(s)],
      rowSecurity: [
        if (h.rowSecurity) 'ALTER $alterTarget ENABLE ROW LEVEL SECURITY;',
        if (h.forceRowSecurity) 'ALTER $alterTarget FORCE ROW LEVEL SECURITY;',
        for (final p in source.policies) _policy(p, table),
      ],
      owner: ownerStatement(relationKind, table, h.owner),
      grants: grantStatements(source.grants, 'TABLE $table'),
      comments: [
        ...commentStatement(relationKind, table, h.comment),
        for (final column in source.columns)
          ...commentStatement(
            'COLUMN',
            '$table.${quoteIdent(column.name)}',
            column.comment,
          ),
        for (final c in local)
          ...commentStatement(
            'CONSTRAINT',
            '${quoteIdent(c.name)} ON $table',
            c.comment,
          ),
        ...indexCommentStatements(source.indexes, h.schema),
      ],
    );
  }

  String _create(
    TableHeader h,
    String table,
    List<ParentRow> parents,
    List<String> elements,
  ) {
    final isForeign = h.relkind == 'f';
    final out = StringBuffer('CREATE ')
      ..write(h.persistence == 'u' ? 'UNLOGGED ' : '')
      ..write(isForeign ? 'FOREIGN TABLE ' : 'TABLE ')
      ..write(table);
    final body = elements.isEmpty
        ? ''
        : ' (\n${elements.map((e) => '    $e').join(',\n')}\n)';
    final parentNames = [
      for (final p in parents) qualifiedName(p.schema, p.name),
    ];
    if (h.isPartition && parentNames.isNotEmpty) {
      out
        ..write(' PARTITION OF ${parentNames.first}')
        ..write(body)
        ..write('\n${h.partitionBound ?? 'DEFAULT'}');
    } else if (h.ofType != null) {
      out.write(' OF ${h.ofType}$body');
    } else {
      out.write(elements.isEmpty ? ' (\n)' : body);
      if (parentNames.isNotEmpty) {
        out.write('\nINHERITS (${parentNames.join(', ')})');
      }
    }
    final options = [
      for (final o in h.options) reloptionEntry(o),
      for (final o in h.toastOptions) reloptionEntry(o, prefix: 'toast.'),
    ];
    final clauses = [
      if (h.partitionKey case final key?) 'PARTITION BY $key',
      if (h.accessMethod case final am? when am != 'heap' && !isForeign)
        'USING ${quoteIdent(am)}',
      if (options.isNotEmpty) 'WITH (${options.join(', ')})',
      if (h.tablespace case final ts?) 'TABLESPACE ${quoteIdent(ts)}',
      if (h.foreignServer case final server?) 'SERVER ${quoteIdent(server)}',
      if (h.foreignOptions.isNotEmpty)
        'OPTIONS (${h.foreignOptions.map(fdwOptionEntry).join(', ')})',
    ];
    for (final clause in clauses) {
      out.write('\n$clause');
    }
    out.write(';');
    return out.toString();
  }

  /// One column element, or `null` for a typed-table column with nothing
  /// to add to its type's definition.
  String? _column(
    ColumnRow c,
    TableHeader h,
    IdentityRow? identity,
    Map<int, ConstraintRow> inlineNotNull, {
    required bool withDefault,
  }) {
    final options = <String>[
      if (h.relkind == 'f' && c.fdwOptions.isNotEmpty)
        'OPTIONS (${c.fdwOptions.map(fdwOptionEntry).join(', ')})',
      if (_compression(c.compression) case final method?) 'COMPRESSION $method',
      if (c.collation case final collation?) 'COLLATE $collation',
      ...switch (c) {
        ColumnRow(generated: 's', :final defaultExpr?) => [
          'GENERATED ALWAYS AS ($defaultExpr) STORED',
        ],
        ColumnRow(generated: 'v', :final defaultExpr?) => [
          'GENERATED ALWAYS AS ($defaultExpr) VIRTUAL',
        ],
        ColumnRow(identity: 'a' || 'd') => [_identity(c.identity, identity)],
        ColumnRow(:final defaultExpr?) when withDefault => [
          'DEFAULT $defaultExpr',
        ],
        _ => const <String>[],
      },
      ?_notNull(c, h, inlineNotNull[c.attnum]),
    ];
    if (h.ofType != null) {
      return options.isEmpty
          ? null
          : '${quoteIdent(c.name)} WITH OPTIONS ${options.join(' ')}';
    }
    return [quoteIdent(c.name), c.type, ...options].join(' ');
  }

  String? _notNull(ColumnRow c, TableHeader h, ConstraintRow? constraint) {
    if (!_notNullIsConstraint) return c.notNull ? 'NOT NULL' : null;
    if (constraint == null) return null;
    final defaultName = '${h.name}_${c.name}_not_null';
    return [
      if (constraint.name != defaultName)
        'CONSTRAINT ${quoteIdent(constraint.name)}',
      'NOT NULL',
      if (constraint.noInherit) 'NO INHERIT',
    ].join(' ');
  }

  static String _identity(String kind, IdentityRow? options) {
    final when = kind == 'a' ? 'ALWAYS' : 'BY DEFAULT';
    final sequenceOptions = [
      if (options != null && options.start != '1')
        'START WITH ${options.start}',
      if (options != null && options.increment != '1')
        'INCREMENT BY ${options.increment}',
    ];
    return 'GENERATED $when AS IDENTITY'
        '${sequenceOptions.isEmpty ? '' : ' (${sequenceOptions.join(' ')})'}';
  }

  static String? _compression(String code) => switch (code) {
    'p' => 'pglz',
    'l' => 'lz4',
    _ => null,
  };

  static String? _replicaIdentity(
    TableHeader h,
    List<IndexRow> indexes,
    String alterTarget,
  ) {
    final clause = switch (h.replicaIdentity) {
      'n' => 'NOTHING',
      'f' => 'FULL',
      'i' => switch (indexes.where((i) => i.isReplicaIdentity).firstOrNull) {
        final index? => 'USING INDEX ${quoteIdent(index.name)}',
        null => null,
      },
      _ => null,
    };
    return clause == null
        ? null
        : 'ALTER $alterTarget REPLICA IDENTITY $clause;';
  }

  static String _policy(PolicyRow p, String table) {
    final command = switch (p.command) {
      'r' => 'SELECT',
      'a' => 'INSERT',
      'w' => 'UPDATE',
      'd' => 'DELETE',
      _ => 'ALL',
    };
    final clauses = [
      'AS ${p.isPermissive ? 'PERMISSIVE' : 'RESTRICTIVE'}',
      'FOR $command',
      'TO ${p.roles.isEmpty ? 'PUBLIC' : p.roles.join(', ')}',
      if (p.usingExpr case final e?) 'USING ($e)',
      if (p.checkExpr case final e?) 'WITH CHECK ($e)',
    ];
    return 'CREATE POLICY ${quoteIdent(p.name)} ON $table '
        '${clauses.join('\n  ')};';
  }
}

extension on String {
  /// `ALTER <this> SET DEFAULT <expr>;`.
  String withSetDefault(String expr) => 'ALTER $this SET DEFAULT $expr;';
}
