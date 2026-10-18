// File: catalog_query.dart
// Purpose: The one primitive catalog code needs (run one statement with
// `$n` parameters, get the rows back as column-name maps of server text)
// and parsers for the server's text output of catalog columns. Moved from
// the dbase app in 0.6.0.

/// One result row: column name to the server's text value (`null` for SQL
/// NULL).
typedef CatalogRow = Map<String, String?>;

/// Runs one statement and returns all its rows.
///
/// Values are the server's text output (`t`/`f` for booleans, `{a,b}` for
/// arrays): parse them with [pgBool], [pgInt] and [pgTextArray].
/// Parameters are untyped text, so SQL must cast them
/// (`$1::pg_catalog.oid`). An implementation must return every row and
/// every byte of every value, or throw: a cut catalog value would make
/// generated DDL silently wrong.
typedef CatalogQuery = Future<List<CatalogRow>> Function(
  String sql, [
  List<String?> parameters,
]);

/// Reads a column that the query guarantees is non-NULL.
///
/// Throws a [FormatException] naming the column when it is NULL or missing.
String requireText(CatalogRow row, String column) =>
    row[column] ??
    (throw FormatException('Catalog column "$column" is NULL or missing.'));

/// `t` / `f`; anything else (including NULL) is `null`.
bool? pgBool(String? text) => switch (text) {
  't' => true,
  'f' => false,
  _ => null,
};

/// An integer column, or `null` for NULL or text that is not an integer.
int? pgInt(String? text) => text == null ? null : int.tryParse(text);

/// A floating point column, or `null` for NULL or unparsable text.
double? pgDouble(String? text) => text == null ? null : double.tryParse(text);

/// Parses a one-dimensional array literal. Unquoted `NULL` elements become
/// `null`; quoted elements are unescaped (`\"` and `\\`). Returns an empty
/// list for `null` or `{}`.
List<String?> pgTextArray(String? text) {
  if (text == null || text.length < 2) return const [];
  // Arrays with explicit bounds start with "[1:2]={...}".
  final body = text.substring(text.indexOf('{') + 1, text.lastIndexOf('}'));
  if (body.isEmpty) return const [];
  final out = <String?>[];
  final current = StringBuffer();
  var quoted = false;
  var wasQuoted = false;
  for (var i = 0; i < body.length; i++) {
    final ch = body[i];
    if (quoted) {
      if (ch == r'\' && i + 1 < body.length) {
        current.write(body[++i]);
      } else if (ch == '"') {
        quoted = false;
      } else {
        current.write(ch);
      }
    } else if (ch == '"') {
      quoted = true;
      wasQuoted = true;
    } else if (ch == ',') {
      out.add(_element(current.toString(), wasQuoted));
      current.clear();
      wasQuoted = false;
    } else {
      current.write(ch);
    }
  }
  out.add(_element(current.toString(), wasQuoted));
  return out;
}

String? _element(String raw, bool wasQuoted) =>
    !wasQuoted && raw.toUpperCase() == 'NULL' ? null : raw;

/// A one-element-per-OID array literal for an `$n::pg_catalog.oid[]`
/// parameter, e.g. `{16384,16390}`.
String oidArrayLiteral(Iterable<int> oids) => '{${oids.join(',')}}';
