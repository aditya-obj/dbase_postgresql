import 'package:dabase_postgresql/sql.dart';
import 'package:test/test.dart';

void main() {
  group('quoteIdent (matches quote_ident)', () {
    test('plain lower-case names stay bare', () {
      expect(quoteIdent('orders'), 'orders');
      expect(quoteIdent('_tmp1'), '_tmp1');
      expect(quoteIdent(r'a$b'), r'a$b');
    });

    test('unreserved keywords stay bare', () {
      expect(quoteIdent('name'), 'name');
      expect(quoteIdent('data'), 'data');
      expect(quoteIdent('update'), 'update');
    });

    test('reserved, column-name and type/function keywords are quoted', () {
      expect(quoteIdent('select'), '"select"');
      expect(quoteIdent('table'), '"table"');
      expect(quoteIdent('int'), '"int"');
      expect(quoteIdent('left'), '"left"');
    });

    test('upper case, spaces, leading digits and non-ASCII are quoted', () {
      expect(quoteIdent('Mixed Case'), '"Mixed Case"');
      expect(quoteIdent('Orders'), '"Orders"');
      expect(quoteIdent('1st'), '"1st"');
      expect(quoteIdent('café'), '"café"');
    });

    test('embedded double quotes are doubled', () {
      expect(quoteIdent('a"b'), '"a""b"');
    });
  });

  test('qualifiedName quotes each part', () {
    expect(qualifiedName('public', 'select'), 'public."select"');
    expect(qualifiedName('My Schema', 't'), '"My Schema".t');
  });

  test('quoteLiteral doubles single quotes and leaves backslashes', () {
    expect(quoteLiteral("it's"), "'it''s'");
    expect(quoteLiteral(r'C:\path'), r"'C:\path'");
  });

  group('reloptionEntry', () {
    test('plain values stay bare', () {
      expect(reloptionEntry('fillfactor=70'), 'fillfactor=70');
      expect(
        reloptionEntry('autovacuum_enabled=false', prefix: 'toast.'),
        'toast.autovacuum_enabled=false',
      );
    });

    test('other values are quoted literals', () {
      expect(reloptionEntry("opt=a b'c"), "opt='a b''c'");
    });
  });

  test('fdwOptionEntry renders name and literal', () {
    expect(fdwOptionEntry('schema_name=remote'), "schema_name 'remote'");
    expect(fdwOptionEntry('Table=x=y'), "\"Table\" 'x=y'");
  });
}
