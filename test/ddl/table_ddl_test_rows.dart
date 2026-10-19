// File: table_ddl_test_rows.dart
// Purpose: Hand-written catalog rows (server text, as CatalogQuery returns
//          them) for the table assembler tests.

import 'package:dabase_postgresql/catalog.dart';
import 'package:dabase_postgresql/ddl.dart';

TableHeader headerRow([CatalogRow extra = const {}]) => TableHeader.fromRow({
  'oid': '16384',
  'schema': 'public',
  'name': 'orders',
  'relkind': 'r',
  'relpersistence': 'p',
  'relispartition': 'f',
  'of_type': null,
  'partition_key': null,
  'partition_bound': null,
  'access_method': 'heap',
  'reloptions': null,
  'toast_reloptions': null,
  'tablespace': null,
  'relrowsecurity': 'f',
  'relforcerowsecurity': 'f',
  'relreplident': 'd',
  'owner': 'app',
  'relacl': null,
  'comment': null,
  'foreign_server': null,
  'foreign_options': null,
  ...extra,
});

ColumnRow columnRow(
  int attnum,
  String name,
  String type, [
  CatalogRow extra = const {},
]) => ColumnRow.fromRow({
  'attnum': '$attnum',
  'attname': name,
  'type': type,
  'attnotnull': 'f',
  'attidentity': '',
  'attgenerated': '',
  'default_or_generation_expr': null,
  'collation': null,
  'attislocal': 't',
  'attinhcount': '0',
  'attcompression': '',
  'attfdwoptions': null,
  'comment': null,
  ...extra,
});

ConstraintRow constraintRow(
  String name,
  String type,
  String def, [
  CatalogRow extra = const {},
]) => ConstraintRow.fromRow({
  'oid': '20000',
  'conname': name,
  'contype': type,
  'conislocal': 't',
  'convalidated': 't',
  'connoinherit': 'f',
  'attnum': null,
  'def': def,
  'comment': null,
  ...extra,
});

IndexRow indexRow(String name, String def, [CatalogRow extra = const {}]) =>
    IndexRow.fromRow({
      'name': name,
      'def': def,
      'indisclustered': 'f',
      'indisvalid': 't',
      'indisreplident': 'f',
      'is_constraint': 'f',
      'comment': null,
      ...extra,
    });

GrantRow grantRow(
  String grantee,
  String privilege, {
  bool grantable = false,
  bool owner = false,
}) => GrantRow.fromRow({
  'grantee': grantee,
  'privilege_type': privilege,
  'is_grantable': grantable ? 't' : 'f',
  'is_owner': owner ? 't' : 'f',
});
