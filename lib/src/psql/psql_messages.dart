// File: psql_messages.dart
// Purpose: Server errors and notices written the way psql shows them
// (`ERROR:  …`, `LINE 1: …` with a `^` under the error position, then
// DETAIL / HINT), and psql's `\timing` line.
//
// Ported from src/interfaces/libpq/fe-protocol3.c (pqBuildErrorMessage3,
// reportErrorPosition) and src/bin/psql/common.c (PrintTiming) -
// PostgreSQL License, (c) 1996-2026 PostgreSQL Global Development Group.
// See THIRD_PARTY_NOTICES.

import 'package:dabase_postgresql/src/psql/print/display_width.dart';

/// Formats a server error or notice like psql's default verbosity.
///
/// [severity] is `ERROR`, `FATAL`, `WARNING`, `NOTICE`…; [position] is
/// the server's 1-based character position in [query], shown as a
/// `LINE n:` excerpt (at most about 60 columns) with a caret. [context]
/// is printed only when [showContext] is set (psql shows it for errors,
/// not for notices). The result ends with a newline.
String formatServerMessage({
  required String severity,
  required String message,
  String? detail,
  String? hint,
  String? query,
  int? position,
  String? internalQuery,
  String? context,
  bool showContext = true,
}) {
  final out = StringBuffer('$severity:  $message\n');
  if (query != null && position != null && position > 0) {
    out.write(_errorPosition(query, position));
  }
  if (detail != null) out.writeln('DETAIL:  $detail');
  if (hint != null) out.writeln('HINT:  $hint');
  if (internalQuery != null) out.writeln('QUERY:  $internalQuery');
  if (showContext && context != null) out.writeln('CONTEXT:  $context');
  return out.toString();
}

const _displaySize = 60;
const _minRightCut = 10;

/// reportErrorPosition: the `LINE n: …` line and the caret line.
String _errorPosition(String query, int position) {
  final loc = position - 1;
  final chars = query.runes.toList();
  final screen = <int>[];
  var scroffset = 0;
  var locLine = 1;
  var ibeg = 0;
  var iend = -1;
  var cno = 0;
  for (; cno < chars.length; cno++) {
    var ch = chars[cno];
    screen.add(scroffset);
    if (ch == 0x09) {
      chars[cno] = ch = 0x20;
    } else if (ch == 0x0D || ch == 0x0A) {
      if (cno < loc) {
        if (ch == 0x0D || cno == 0 || chars[cno - 1] != 0x0D) locLine++;
        ibeg = cno + 1;
      } else {
        iend = cno;
        break;
      }
    }
    var w = runeWidth(ch);
    if (w <= 0) w = 1;
    scroffset += w;
  }
  if (iend < 0) {
    iend = cno;
    screen.add(scroffset);
  }
  if (loc > cno) return '';

  var begTrunc = false;
  var endTrunc = false;
  if (screen[iend] - screen[ibeg] > _displaySize) {
    if (screen[ibeg] + _displaySize >= screen[loc] + _minRightCut) {
      while (screen[iend] - screen[ibeg] > _displaySize) {
        iend--;
      }
      endTrunc = true;
    } else {
      while (screen[loc] + _minRightCut < screen[iend]) {
        iend--;
        endTrunc = true;
      }
      while (screen[iend] - screen[ibeg] > _displaySize) {
        ibeg++;
        begTrunc = true;
      }
    }
  }

  final prefix = 'LINE $locLine: ${begTrunc ? '...' : ''}';
  final line = String.fromCharCodes(chars.sublist(ibeg, iend));
  final caretColumn = prefix.length + screen[loc] - screen[ibeg];
  return '$prefix$line${endTrunc ? '...' : ''}\n${' ' * caretColumn}^\n';
}

/// psql's `\timing` line for [elapsed]: `Time: 0.512 ms`, or with
/// minutes (and hours, days) once it is a second or more.
String formatTiming(Duration elapsed) {
  final ms = elapsed.inMicroseconds / 1000;
  final text = 'Time: ${ms.toStringAsFixed(3)} ms';
  if (ms < 1000) return text;
  var seconds = ms / 1000;
  var minutes = (seconds / 60).floorToDouble();
  seconds -= 60 * minutes;
  String two(num v) => v.toInt().toString().padLeft(2, '0');
  final secs = seconds.toStringAsFixed(3).padLeft(6, '0');
  if (minutes < 60) return '$text (${two(minutes)}:$secs)';
  var hours = (minutes / 60).floorToDouble();
  minutes -= 60 * hours;
  if (hours < 24) return '$text (${two(hours)}:${two(minutes)}:$secs)';
  final days = (hours / 24).floorToDouble();
  hours -= 24 * days;
  return '$text (${days.toInt()} d ${two(hours)}:${two(minutes)}:$secs)';
}
