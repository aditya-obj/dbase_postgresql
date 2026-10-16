// File: server_configured_test.dart
// Purpose: Guards CI against a silently green integration run. The other
// integration tests skip when DBASE_PG_URL is unset, which is right
// locally; on CI (the CI environment variable is "true", as GitHub
// Actions sets it) a missing URL is a configuration error.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support/pg_server.dart';

void main() {
  final onCi = Platform.environment['CI'] == 'true';

  test(
    '$urlVariable is set on CI',
    () => expect(testServerUrl, isNotNull, reason: '$urlVariable is unset'),
    skip: onCi ? false : 'not running on CI',
  );
}
