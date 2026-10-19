// File: view_ddl_assembler.dart
// Purpose: Builds view and materialized view DDL from parsed rows: the
// viewer text, and the same statements as parts for a dump. Pure: no I/O.
// Moved from the dabase app in 0.6.0.

import 'package:dabase_postgresql/src/ddl/ddl_rows.dart';
import 'package:dabase_postgresql/src/ddl/ddl_statements.dart';
import 'package:dabase_postgresql/src/ddl/object_ddl_rows.dart';
import 'package:dabase_postgresql/src/sql/sql_quoting.dart';

/// Everything fetched for one view or materialized view.
final class ViewDdlSource {
  /// Creates a view source.
  const ViewDdlSource({
    required this.header,
    this.columnComments = const [],
    this.triggers = const [],
    this.rules = const [],
    this.indexes = const [],
    this.grants = const [],
  });

  /// The view itself.
  final ViewHeader header;

  /// Columns that have comments.
  final List<ColumnCommentRow> columnComments;

  /// Views only (`INSTEAD OF` triggers).
  final List<TriggerRow> triggers;

  /// Rules other than `_RETURN`.
  final List<RuleRow> rules;

  /// Materialized views only.
  final List<IndexRow> indexes;

  /// Grants (only fetched when the view has an ACL).
  final List<GrantRow> grants;
}

/// The statements of one view, grouped by where a dump writes them.
final class ViewDdlParts {
  /// Creates the parts.
  const ViewDdlParts({
    required this.create,
    this.indexes = const [],
    this.cluster = const [],
    this.triggersAndRules = const [],
    this.owner = const [],
    this.grants = const [],
    this.comments = const [],
  });

  /// CREATE VIEW / CREATE MATERIALIZED VIEW.
  final String create;

  /// CREATE INDEX (materialized views).
  final List<String> indexes;

  /// CLUSTER ON (materialized views).
  final List<String> cluster;

  /// CREATE TRIGGER and CREATE RULE.
  final List<String> triggersAndRules;

  /// ALTER ... OWNER TO.
  final List<String> owner;

  /// GRANT statements.
  final List<String> grants;

  /// COMMENT ON the view, its columns and indexes.
  final List<String> comments;
}

/// Assembles view and materialized view DDL.
final class ViewDdlAssembler {
  /// Creates an assembler.
  const ViewDdlAssembler();

  static const _checkOptionPrefix = 'check_option=';

  /// The viewer text.
  String assemble(ViewDdlSource source) {
    final p = parts(source);
    final script = DdlScript()
      ..add([p.create])
      ..add(p.indexes)
      ..add(p.cluster)
      ..add(p.triggersAndRules)
      ..add(p.owner)
      ..add(p.grants)
      ..add(p.comments);
    return script.toString();
  }

  /// The statements of [source] by kind. With [withNoData] a materialized
  /// view is created `WITH NO DATA` whatever its state (a dump refreshes
  /// it after loading the tables).
  ViewDdlParts parts(ViewDdlSource source, {bool withNoData = false}) {
    final h = source.header;
    final view = qualifiedName(h.schema, h.name);
    final kind = h.isMaterialized ? 'MATERIALIZED VIEW' : 'VIEW';
    return ViewDdlParts(
      create: h.isMaterialized
          ? _materialized(h, view, withData: h.isPopulated && !withNoData)
          : _view(h, view),
      indexes: createIndexStatements(source.indexes),
      cluster: clusterStatements(source.indexes, '$kind $view'),
      triggersAndRules: [
        // ALTER VIEW has no trigger subcommands; ALTER TABLE accepts views.
        ...triggerStatements(source.triggers, 'TABLE $view'),
        ...ruleStatements(source.rules),
      ],
      owner: ownerStatement(kind, view, h.owner),
      grants: grantStatements(source.grants, 'TABLE $view'),
      comments: [
        ...commentStatement(kind, view, h.comment),
        for (final c in source.columnComments)
          ...commentStatement(
            'COLUMN',
            '$view.${quoteIdent(c.name)}',
            c.comment,
          ),
        ...indexCommentStatements(source.indexes, h.schema),
      ],
    );
  }

  /// `CREATE OR REPLACE VIEW`, with `check_option` moved from `WITH (...)`
  /// to a trailing `WITH ... CHECK OPTION`, as psql's `\sv` prints it.
  String _view(ViewHeader h, String view) {
    String? checkOption;
    final options = <String>[];
    for (final option in h.options) {
      if (option.startsWith(_checkOptionPrefix)) {
        checkOption = option.substring(_checkOptionPrefix.length);
      } else {
        options.add(reloptionEntry(option));
      }
    }
    final withClause = options.isEmpty ? '' : ' WITH (${options.join(', ')})';
    final body = checkOption == null
        ? terminate(h.def)
        : '${unterminate(h.def)}\n  WITH ${checkOption.toUpperCase()} '
              'CHECK OPTION;';
    return 'CREATE OR REPLACE VIEW $view$withClause AS\n$body';
  }

  String _materialized(ViewHeader h, String view, {required bool withData}) {
    final options = h.options.map(reloptionEntry).toList();
    final clauses = [
      if (h.accessMethod case final am? when am != 'heap')
        'USING ${quoteIdent(am)}',
      if (options.isNotEmpty) 'WITH (${options.join(', ')})',
      if (h.tablespace case final ts?) 'TABLESPACE ${quoteIdent(ts)}',
    ];
    final head = ['CREATE MATERIALIZED VIEW $view', ...clauses].join(' ');
    return '$head AS\n${unterminate(h.def)}\n'
        '${withData ? 'WITH DATA' : 'WITH NO DATA'};';
  }
}
