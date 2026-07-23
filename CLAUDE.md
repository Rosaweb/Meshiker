# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Meshiker (`meshiker`, package: "Application de navigation pour la randonnée") is a Flutter offline-first hiking/navigation app: GPS recording, GPX import, offline vector maps, and a community-shared trail network synced through Supabase. Code comments throughout the codebase are written in French — match that convention when editing files that are already commented in French.

## Commands

Standard Flutter tooling — run from the repo root.

```bash
flutter pub get                     # install dependencies
flutter analyze                     # static analysis (uses analysis_options.yaml / flutter_lints)
flutter test                        # run all tests
flutter test test/widget_test.dart  # run a single test file
flutter run                         # run on a connected device/emulator
flutter build apk                   # Android release build
```

Isar models use code generation (`@collection` classes have matching `*.g.dart` files). After changing any file under `lib/models/`, regenerate:

```bash
dart run build_runner build --delete-conflicting-outputs
```

Android build config: `compileSdk 36`, AGP 8.14.0, Kotlin 2.2.20 (see `android/build.gradle.kts`, `android/settings.gradle.kts`).

## Architecture

### Local-first data flow

Isar (via the `isar_community` fork, not the original `isar` package — see comments in `lib/database/isar_service.dart` for why) is the single source of truth, opened once in `main()` before `runApp` and threaded through the app via `provider`. Every read path (map viewport, search, navigation stats) hits Isar first; Supabase is always a secondary, opportunistic layer — the app must stay fully usable with no network connection ("zone blanche" requirement). `IsarService` is the only class that touches `Isar` directly; add new query methods there rather than reaching into `isar.<collection>` from UI/service code.

Core entities (`lib/models/`): `Segment` (an atomic trail piece, embeds its own `List<PointGPS>`), `Trace` (an ordered sequence of `TraceSegmentEntry` referencing segments, i.e. a full hike), `PointOfInterest`, `Waypoint`/`WaypointCategory`/`WaypointFolder`, `Utilisateur`, `OfflineMap`, `RecordingDraft`/`RecordingPointBatch`/`RecordingModeOverride` (recording-session staging). `Segment`, `Trace`, and `Utilisateur` implement the `Syncable` interface (`lib/models/syncable.dart`) structurally (Dart doesn't require explicit `implements` when the shape matches) so sync code can operate generically over `localUuid`/`remoteId`/`syncStatus`/`updatedAt`.

### Recording → Segmentation → Sync pipeline

1. **`RecordingService`** (`lib/recording/`) streams GPS positions (`geolocator`), batches raw points into `RecordingPointBatch` rows, and tracks a `RecordingDraft` so an abandoned session (app killed mid-hike) can be resumed on next launch via `findAbandonedDraft()`. The user can manually toggle "aimant" (magnet) routed vs. off-path mode mid-recording (`RecordingModeOverride`, timestamp-based so GPS noise cleanup never desyncs it from point indices).
2. **`SegmentationEngine`** (`lib/gpx/segmentation_engine.dart`) is a *pure* function of GPX/track points — no Isar access — that cuts a track into `Segment`s and dedupes against segments/POIs already known nearby (passed in by the caller, e.g. `RecordingService._finalizeSession` or `GpxImportService`). It calls into `ValhallaService` (native Valhalla/Meili map-matching via FFI, see `lib/utils/valhalla_service.dart`) to snap points to OSM ways/nodes, then falls back to geometric buffer matching for off-road terrain. Cut points, in priority order: track boundaries → GPX segment breaks → OSM node/way transitions → proximity to a waypoint → prolonged stop → manual magnet toggle. It deliberately does **not** retroactively split an already-stored segment when a new trace crosses its middle — that's server-side (PostGIS `ST_Split`) territory, not local-import territory.
3. **`SyncEngine`** (`lib/sync/sync_engine.dart`) pushes `pending`-status entities to Supabase in batches via RPCs (`upsert_segments_batch`, `upsert_pois_batch` — server decides spatial-buffer merges, the client never does) and pulls community-contributed segments/POIs/aggregate stats (passage count, reliability index) for a viewport. It is caller-triggered only — never call it during an active recording (battery constraint) or without a live Supabase auth session.

Server-side counterpart lives in `supabase/schema.sql` (tables, RLS) and `supabase/functions.sql` (the RPCs referenced above).

### Map & search

- `MapViewModel` (`lib/map/`) feeds `MapScreen`: always loads from Isar first (viewport-indexed bounding-box queries on `Segment`/`PointOfInterest`), debounces viewport-change callbacks (300ms default) before doing anything expensive, and treats `SyncEngine` pulls / `OverpassService` (live OSM POI fetch) as optional enrichment.
- `vector_map_tiles` + `mbtiles` render offline `.mbtiles` vector tiles (see `lib/map/vector_tile_source.dart`, `map_style.dart`); `TileCacheService` manages the on-disk tile cache.
- `LocalSearchEngine` (`lib/search/`) is an in-memory trigram index (`TrigramIndex`) over `Trace`/`PointOfInterest`, rebuilt from Isar at startup and updated incrementally on writes (never a full rebuild per write) — needed for instant fuzzy search once the local DB reaches thousands of entities.

### Services layer (`lib/utils/`)

Singletons/near-singletons wired up in `main.dart` and exposed via `provider`: `SettingsService` (ChangeNotifier wrapping `shared_preferences`, all app display/unit/panel-visibility toggles), `SubscriptionService` (RevenueCat, `purchases_flutter`), `TileCacheService`, `PedometerService` (calibrates step length against GPS-measured slope during recording), `ValhallaService` (native FFI map-matching), `OverpassService` (live OSM POI HTTP queries), `GeoUtils` (haversine, bounding boxes, geohash, polyline snapping — the shared geometry toolkit used everywhere above).

### Startup sequence (`lib/main.dart`)

Errors are captured globally (`FlutterError.onError`, `PlatformDispatcher.onError`, `runZonedGuarded`) and render a fallback error screen rather than crashing silently — preserve this pattern when touching startup code. Init order matters: `IsarService.open()` → `SettingsService.init()` → `SubscriptionService.init()` (non-fatal if it fails) → `TileCacheService.init()` → `LocalSearchEngine.rebuildFromDatabase()` → services that depend on the above (`GpxImportService`, `MapViewModel`, `RecordingService`, `GpxScannerService`). `GpxScannerService` kicks off an unawaited folder scan if a GPX storage path is already configured.

## UI structure

`lib/ui/main_navigation_screen.dart` is the app shell (map + overlay panels + edge-swipe gesture handling — has previously conflicted with map drag and the OS back gesture, so be careful with gesture arena changes here). Feature screens are grouped under `lib/ui/settings/`, `lib/ui/tracks/`, `lib/ui/waypoints/`, `lib/ui/segments/`.
