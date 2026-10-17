// File: sql.dart
// Purpose: Narrow entrypoint for the PostgreSQL SQL lexer, keyword table,
// statement splitter, and statement safety analyzer.

/// Tokenize, split, and analyze PostgreSQL SQL without a server.
library;

export 'src/sql/analysis/safety_finding.dart'
    show SafetyFinding, SafetyFindingCode, SafetySeverity;
export 'src/sql/analysis/sql_statement_analyzer.dart' show SqlStatementAnalyzer;
export 'src/sql/analysis/statement_analysis.dart' show StatementAnalysis;
export 'src/sql/analysis/statement_kind.dart' show StatementKind;
export 'src/sql/analysis/table_lock_mode.dart' show TableLockMode;
export 'src/sql/sql_keywords.dart'
    show
        SqlKeywordCategory,
        defaultHighlightCategories,
        isHighlightKeyword,
        sqlKeywordCategories,
        sqlKeywordCategory;
export 'src/sql/sql_lexer.dart' show SqlLexer;
export 'src/sql/sql_statement.dart' show SqlStatement;
export 'src/sql/sql_statement_splitter.dart' show SqlStatementSplitter;
export 'src/sql/sql_token.dart' show SqlToken, SqlTokenDiagnostic, SqlTokenKind;
