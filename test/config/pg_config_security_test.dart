// File: pg_config_security_test.dart
// Purpose: Tests that connection-string errors, toString, and redacted
// output never leak secrets, plus security warnings.

import 'package:dabase_postgresql/connection_string.dart';
import 'package:test/test.dart';

const _secret = 'hunter2';

String _errorText(String input) {
  try {
    PgConnectionConfig.parse(input);
  } on PgConfigParseException catch (e) {
    return '${e.message} | $e';
  }
  fail('expected a parse error for a malformed input');
}

void main() {
  group('errors never echo input', () {
    for (final input in [
      'host=db $_secret',
      "host=db $_secret='x",
      'host=db port=$_secret',
      'host=db sslmode=$_secret',
      'host=db connect_timeout=$_secret',
      'postgres://u:pw@h/db?ssl=$_secret',
      'postgres://u:$_secret@h:99999/db',
      'postgres://u:$_secret%zz@h/db',
      'postgres://u:$_secret%00@h/db',
      'postgres://u:$_secret@h/db?a=b=c',
      'postgres://u:$_secret@h/db?a b=c',
      'postgres://u:$_secret@[::1/db',
      '$_secret\u0000',
      'jdbc:postgresql://u:$_secret@h/db',
    ]) {
      test(input.replaceAll('\u0000', r'\0'), () {
        expect(_errorText(input), isNot(contains(_secret)));
      });
    }

    // Regression (found by the mutation fuzzer): a mistyped scheme fell
    // through to conninfo parsing and kept `postsql://u:<password>@...` as
    // an unknown parameter name, which redacted() then printed.
    test('mistyped URI scheme is an error, not a parameter name', () {
      for (final input in [
        'postsql://u:$_secret@h/db?sslmode=require',
        "postgr'esql://u:$_secret@h/db?sslmode=require",
        'postgres:/u:$_secret@h/db?sslmode=require',
      ]) {
        expect(_errorText(input), isNot(contains(_secret)), reason: input);
      }
      expect(
        () => PgConnectionConfig.parse('postgres://h/db?a.b=1'),
        throwsA(isA<PgConfigParseException>()),
      );
    });

    test('known keywords are named in errors', () {
      expect(_errorText("host=db password='x"), contains('"password"'));
      expect(_errorText('host=db user'), contains('"user"'));
    });
  });

  group('redaction', () {
    final config = PgConnectionConfig.parse(
      'postgres://u:$_secret@h/db?sslpassword=$_secret'
      '&oauth_client_secret=$_secret&application_name=a%0D%0Ab',
    );

    test('redacted() masks every secret', () {
      final text = config.redacted();
      expect(text, isNot(contains(_secret)));
      expect(text, contains('u:****@h'));
      expect(text, contains('sslpassword=****'));
    });

    test('redacted() percent-encodes CR/LF (no log injection)', () {
      expect(config.redacted(), isNot(contains('\n')));
      expect(config.redacted(), contains('a%0D%0Ab'));
    });

    test('toString() is redacted', () {
      expect(config.toString(), isNot(contains(_secret)));
    });

    test('toUri() without includePassword drops secrets', () {
      expect(config.toUri(), isNot(contains(_secret)));
      expect(config.toUri(includePassword: true), contains(_secret));
    });
  });

  group('security warnings', () {
    List<PgSecurityWarningCode> codes(String input) =>
        PgConnectionConfig.parse(input).securityWarnings
            .map((w) => w.code)
            .toList();

    test('no sslmode: libpq default prefer, flagged twice', () {
      expect(codes('postgres://h/db'), [
        PgSecurityWarningCode.sslMayFallBackToPlaintext,
        PgSecurityWarningCode.sslModeNotSpecified,
      ]);
    });

    test('disable, allow, require, verify-ca, verify-full', () {
      expect(codes('host=h sslmode=disable'), [
        PgSecurityWarningCode.sslDisabled,
      ]);
      expect(codes('host=h sslmode=allow'), [
        PgSecurityWarningCode.sslMayFallBackToPlaintext,
      ]);
      expect(codes('host=h sslmode=require'), [
        PgSecurityWarningCode.serverIdentityNotVerified,
      ]);
      expect(codes('host=h sslmode=verify-ca'), [
        PgSecurityWarningCode.serverIdentityNotVerified,
      ]);
      expect(codes('host=h sslmode=verify-full'), isEmpty);
    });

    test('password embedded in the string', () {
      expect(codes('postgres://u:pw@h/db?sslmode=verify-full'), [
        PgSecurityWarningCode.passwordInConnectionString,
      ]);
    });

    test('warning messages never contain the password', () {
      final warnings = PgConnectionConfig.parse('postgres://u:$_secret@h/db')
          .securityWarnings;
      expect(warnings.map((w) => w.message).join(), isNot(contains(_secret)));
    });

    test('SslMode properties', () {
      expect(SslMode.prefer.requiresEncryption, isFalse);
      expect(SslMode.require.requiresEncryption, isTrue);
      expect(SslMode.require.verifiesCertificate, isFalse);
      expect(SslMode.verifyCa.verifiesCertificate, isTrue);
      expect(SslMode.verifyCa.verifiesHostName, isFalse);
      expect(SslMode.verifyFull.verifiesHostName, isTrue);
      expect(SslMode.tryParse('VERIFY-FULL'), SslMode.verifyFull);
      expect(SslMode.tryParse('nope'), isNull);
    });
  });
}
