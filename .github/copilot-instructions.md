# Copilot instructions for Life247

## Big picture
- iOS app lives in `Life247/` (SwiftUI + SwiftData). The single source of truth for drive detection is `Life247/Core/DriveStateMachine.swift`.
- Sensors are intentionally *passive*:
  - `Life247/Services/LocationManager.swift` handles permissions, switching accuracy modes, and emits `DriveEvent`s.
  - `Life247/Services/MotionManager.swift` wraps `CMMotionActivityManager` and emits `DriveEvent`s.
  - Neither service should contain thresholds/timers/persistence; keep detection logic in the state machine.
- Persistence uses SwiftData models (`Life247/Models/*.swift`) configured in `Life247/Life247App.swift` via a `ModelContainer` schema (Drive, LocationPoint, Place, DriveLogEntry).

## Drive detection & state changes (critical invariants)
- Only call `DriveStateMachine.handle(_:)` with `DriveEvent` to change state; don’t mutate `state`/`activeDrive` directly.
- Drive lifecycle rules are enforced in `Life247/Models/Drive.swift` and the state machine:
  - Drive is created on entering `driving` (`createNewDrive(...)` in `DriveStateMachine`).
  - Drive is finalized via `finalizeDrive(...)`, which saves SwiftData and posts `.driveEnded`.
- Airplane Mode is a first-class suppressor: `DriveStateMachine.handle(_:)` bails early when `AirplaneModeManager.shared.isEnabled`.
- Cold-start recovery is centralized:
  - `Life247/Life247App.swift` calls `DriveStateMachine.recoverFromColdStart(...)` after querying `MotionManager.wasAutomotiveRecently(...)`.

## UI wiring patterns
- Root composition is in `Life247/Life247App.swift`:
  - Wires `LocationManager` + `MotionManager` event sinks to the state machine.
  - Injects `DriveSyncService` via `.environmentObject(...)`.
- `Life247/ContentView.swift` is the main switchboard:
  - Shows `PermissionsView` until Always Location is granted.
  - Uses `safeAreaInset` with `BottomBar` and toggles high-accuracy mode based on `DriveState`.

## Cloud sync (iOS ↔ server contract)
- iOS queues uploads on `Notification.Name.driveEnded` (`Life247/Core/Notifications.swift`) and uploads via `Life247/Services/DriveSyncService.swift`.
- Upload payload is `Life247/Models/DriveUploadDTO.swift` (polyline encoded + simplified speeds).
- FastAPI server lives in `server/`:
  - Run locally: `cd server && pip install -r requirements.txt && uvicorn app.main:app --reload`
  - Docker: `cd server && docker compose up -d` (API at `http://localhost:8247`)
  - Auth: `X-API-Key` header must match `LIFE247_API_KEY` (`server/app/routes/drives.py`).
  - DB: SQLite at `server/data/drives.db` (mounted in Docker).

## When changing code
- If you need to adjust detection behavior, change thresholds/timers inside `Life247/Core/DriveStateMachine.swift` (not in the managers).
- If you change the upload schema, update both `Life247/Models/DriveUploadDTO.swift` and `server/app/routes/drives.py` + `server/app/models.py` together.
- Prefer OSLog (`Logger(subsystem: "com.life247", category: ...)`) for debug traces; drive decision logging uses `Life247/Models/DriveDecision.swift` and `DriveLogger`.
