// File: type_ddl.dart
// Purpose: Rows and DDL for user-defined types a dump recreates: enums,
// composite types, range types and domains (with their constraints).
// Base (C-language) and shell types need superuser and are not covered.

import 'package:dbase_postgresql/src/catalog/catalog_query.dart';
import 'package:dbase_postgresql/src/ddl/ddl_statements.dart';
import 'package:dbase_postgresql/src/sql/sql_quoting.dart';

/// One attribute of a composite type.
final class TypeAttributeRow {
  /// Creates an attribute row.
  const TypeAttributeRow({
    required this.name,
    required this.type,
    this.collation,
  });

  /// Reads `attname`, `type` and `collation`.
  factory TypeAttributeRow.fromRow(CatalogRow row) => TypeAttributeRow(
    name: requireText(row, 'attname'),
    type: requireText(row, 'type'),
    collation: row['collation'],
  );

  /// Attribute name.
  final String name;

  /// `format_type` text.
  final String type;

  /// Quoted collation name, when not the type's default.
  final String? collation;
}

/// One CHECK constraint of a domain.
final class DomainConstraintRow {
  /// Creates a domain constraint row.
  const DomainConstraintRow({
    required this.name,
    required this.def,
    this.isValidated = true,
  });

  /// Reads `conname`, `def` and `convalidated`.
  factory DomainConstraintRow.fromRow(CatalogRow row) => DomainConstraintRow(
    name: requireText(row, 'conname'),
    def: requireText(row, 'def'),
    isValidated: pgBool(row['convalidated']) ?? true,
  );

  /// Constraint name.
  final String name;

  /// `pg_get_constraintdef(oid, true)`, including `NOT VALID`.
  final String def;

  /// `false` for `NOT VALID`.
  final bool isValidated;
}

/// An enum, composite, range or domain type.
final class TypeRow {
  /// Creates a type row.
  const TypeRow({
    required this.schema,
    required this.name,
    required this.kind,
    this.baseType,
    this.notNull = false,
    this.defaultExpr,
    this.collation,
    this.rangeSubtype,
    this.rangeOpclass,
    this.rangeCollation,
    this.rangeCanonical,
    this.rangeSubdiff,
    this.multirangeName,
    this.enumLabels = const [],
    this.comment,
  });

  /// Reads the `typesQuery` columns.
  factory TypeRow.fromRow(CatalogRow row) => TypeRow(
    schema: requireText(row, 'schema'),
    name: requireText(row, 'name'),
    kind: requireText(row, 'typtype'),
    baseType: row['base_type'],
    notNull: pgBool(row['typnotnull']) ?? false,
    defaultExpr: row['typdefault'],
    collation: row['collation'],
    rangeSubtype: row['range_subtype'],
    rangeOpclass: row['range_opclass'],
    rangeCollation: row['range_collation'],
    rangeCanonical: row['range_canonical'],
    rangeSubdiff: row['range_subdiff'],
    multirangeName: row['range_multirange'],
    enumLabels: pgTextArray(row['enum_labels']).nonNulls.toList(),
    comment: row['comment'],
  );

  /// Schema name.
  final String schema;

  /// Type name.
  final String name;

  /// `typtype`: `e` enum, `c` composite, `r` range, `d` domain.
  final String kind;

  /// Domain: `format_type(typbasetype, typtypmod)`.
  final String? baseType;

  /// Domain: NOT NULL.
  final bool notNull;

  /// Domain: the DEFAULT expression.
  final String? defaultExpr;

  /// Domain: quoted collation, when not the base type's.
  final String? collation;

  /// Range: SUBTYPE.
  final String? rangeSubtype;

  /// Range: SUBTYPE_OPCLASS, when not the default one.
  final String? rangeOpclass;

  /// Range: COLLATION, when not the subtype's default.
  final String? rangeCollation;

  /// Range: CANONICAL function.
  final String? rangeCanonical;

  /// Range: SUBTYPE_DIFF function.
  final String? rangeSubdiff;

  /// Range: MULTIRANGE_TYPE_NAME (PostgreSQL 14+), schema-qualified.
  final String? multirangeName;

  /// Enum: labels in `enumsortorder`.
  final List<String> enumLabels;

  /// `COMMENT ON TYPE` / `COMMENT ON DOMAIN` text.
  final String? comment;

  /// `DOMAIN` for domains, else `TYPE` (for COMMENT ON and GRANT).
  String get objectKeyword => kind == 'd' ? 'DOMAIN' : 'TYPE';
}

/// Builds `CREATE TYPE` / `CREATE DOMAIN` statements.
final class TypeDdlAssembler {
  /// Creates an assembler.
  const TypeDdlAssembler();

  /// The statements creating [type]: one CREATE, plus `ALTER DOMAIN ...
  /// ADD CONSTRAINT ... NOT VALID` for a domain's unvalidated checks.
  /// [attributes] are a composite type's; [constraints] a domain's.
  List<String> create(
    TypeRow type, {
    List<TypeAttributeRow> attributes = const [],
    List<DomainConstraintRow> constraints = const [],
  }) {
    final name = qualifiedName(type.schema, type.name);
    switch (type.kind) {
      case 'e':
        final labels = type.enumLabels.map((l) => '    ${quoteLiteral(l)}');
        return ['CREATE TYPE $name AS ENUM ${_list(labels)};'];
      case 'c':
        final columns = [
          for (final a in attributes)
            [
              '    ${quoteIdent(a.name)} ${a.type}',
              if (a.collation case final c?) ' COLLATE $c',
            ].join(),
        ];
        return ['CREATE TYPE $name AS ${_list(columns)};'];
      case 'r':
        final options = [
          'SUBTYPE = ${type.rangeSubtype}',
          if (type.rangeOpclass case final o?) 'SUBTYPE_OPCLASS = $o',
          if (type.rangeCollation case final c?) 'COLLATION = $c',
          if (type.rangeCanonical case final f?) 'CANONICAL = $f',
          if (type.rangeSubdiff case final f?) 'SUBTYPE_DIFF = $f',
          if (type.multirangeName case final m?) 'MULTIRANGE_TYPE_NAME = $m',
        ];
        return [
          'CREATE TYPE $name AS RANGE ${_list(options.map((o) => '    $o'))};',
        ];
      case 'd':
        final clauses = [
          'CREATE DOMAIN $name AS ${type.baseType}',
          if (type.collation case final c?) 'COLLATE $c',
          if (type.defaultExpr case final d?) 'DEFAULT $d',
          if (type.notNull) 'NOT NULL',
          for (final c in constraints)
            if (c.isValidated) 'CONSTRAINT ${_named(c)}',
        ];
        return [
          '${clauses.join('\n    ')};',
          for (final c in constraints)
            if (!c.isValidated)
              'ALTER DOMAIN $name ADD CONSTRAINT ${_named(c)};',
        ];
    }
    throw ArgumentError.value(type.kind, 'type.kind', 'not e, c, r or d');
  }

  static String _named(DomainConstraintRow c) =>
      '${quoteIdent(c.name)} ${c.def}';

  /// `(\n  a,\n  b\n)`, or `(\n)` when empty.
  static String _list(Iterable<String> lines) =>
      lines.isEmpty ? '(\n)' : '(\n${lines.join(',\n')}\n)';

  /// `COMMENT ON TYPE|DOMAIN ...`, or nothing.
  List<String> comment(TypeRow type) => commentStatement(
    type.objectKeyword,
    qualifiedName(type.schema, type.name),
    type.comment,
  );
}
