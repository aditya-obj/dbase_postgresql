// File: catalog.dart
// Purpose: Narrow entrypoint for reading the PostgreSQL catalog: the
// CatalogQuery callback type, parsers for catalog text, and the bulk
// CatalogReader that builds a SchemaModel.

/// Read the PostgreSQL catalog in bulk (one statement per object kind,
/// version-gated for PostgreSQL 13 to 18) into an immutable [SchemaModel]
/// with dependency edges. Queries run through a [CatalogQuery] callback,
/// so there is no driver dependency and no `dart:io`.
library;

import 'package:dabase_postgresql/src/catalog/catalog_query.dart';
import 'package:dabase_postgresql/src/catalog/schema_model.dart';

export 'src/catalog/catalog_query.dart'
    show
        CatalogQuery,
        CatalogRow,
        oidArrayLiteral,
        pgBool,
        pgDouble,
        pgInt,
        pgTextArray,
        requireText;
export 'src/catalog/catalog_reader.dart'
    show
        CatalogReader,
        CatalogScope,
        ListedRelation,
        RelationListing,
        ServerFacts;
export 'src/catalog/schema_model.dart'
    show
        DependencyEdge,
        ExtensionInfo,
        ObjectKey,
        ObjectKind,
        RoutineInfo,
        SchemaInfo,
        SchemaModel,
        SequenceInfo,
        SkippedObjects,
        TableInfo,
        TypeInfo,
        ViewInfo;
