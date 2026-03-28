# SleepWell: AI-Powered ASMR Sleep App

SleepWell is an MVP-first mobile product designed for rapid growth and habit retention.
The product is fully free at this stage and optimized to collect behavioral signals for future AI personalization.

## What is implemented

- Flutter MVP app flow in `lib/main.dart`
  - Personalization onboarding
  - One-tap `Sleep Now` mode
  - Combined `Sleep Now + Mixer` option (single tap can start primary track + ambient layers)
  - Bedtime routine scheduler (auto-start at selected time) with adherence event logging
  - Local persistence for onboarding/routine/mixer settings across app restarts
  - Automatic in-app screen dimming during Sleep Now playback
  - Smart player UI (categories, loop, timer, fade-out action)
  - Real `just_audio` playback (play/pause, progress, loop, sleep timer fade-out)
  - Background playback notification support (`just_audio_background`)
  - Real multi-layer ambient mixer playback (rain/wind/white noise simultaneously)
  - Mixer preset save/load via `/mix-presets` API
  - Basic sleep tracking insights
  - Sound mixer sliders
- Laravel API and data foundation in `cariloker`
  - API route group: `/api/v1/sleepwell/*`
  - Analytics-ready schema for preferences, sessions, and events
  - Admin page: `/dashboard/sleepwell`

## Product strategy (MVP)

- Growth first: all features are free, no paywalls, no ads.
- Habit first: design pushes one primary action (`Sleep Now`) and low-friction bedtime usage.
- Data first: schema captures preference and behavior events for future recommendation quality.

## App architecture

### Mobile (Flutter)

- Presentation: onboarding + tabbed home (`Sleep Now`, `Player`, `Mixer`, `Insights`)
- State: centralized `SleepWellState` (`ChangeNotifier`) for quick MVP iteration
- Domain entities:
  - `SleepTrack`
  - `SleepSession`
- Integration status:
  - API client connected to `/api/v1/sleepwell/*` (catalog, onboarding, sleep-now, sessions, insights)
  - offline fallback mode if backend is unreachable
  - audio engine (`just_audio`) with true background playback is still next

### Backend (Laravel in `cariloker`)

- API layer: REST endpoints for onboarding, catalog, sessions, events, insights, and mixer presets
- Data layer: dedicated SleepWell tables (no coupling to job portal tables)
- Backoffice:
  - `/dashboard/sleepwell` for key health metrics
  - room to add track/content management without refactor

## Database schema (future personalization optimized)

- `sleepwell_listeners`
  - `device_id`, onboarding preferences, timezone, sleep difficulty, last active
- `sleepwell_audio_tracks`
  - category, talking/non-talking, duration, stream URL, active flag
- `sleepwell_sleep_sessions`
  - start/end/duration, mode (`player`/`sleep_now`), status, entry point
- `sleepwell_session_events`
  - event type (`skip`, `repeat`, `timer_set`, etc), event timestamp, track, metadata
- `sleepwell_mix_presets`
  - per-listener mixer channel volumes

This schema is intentionally event-rich so recommendation/ranking models can be added later without breaking storage contracts.

## User flow (MVP)

1. Install and open app
2. Onboarding captures talking preference, sound types, categories, sleep difficulty
3. User taps `Sleep Now` from home
4. App starts personalized sequence and session tracking
5. During listening, app logs events (play, skip, repeat, timer, complete)
6. Insights page shows frequency + consistency trends

## Wireframe descriptions

- Onboarding
  - single column, dark calm UI, segmented and chip controls
  - one CTA: `Start Sleeping Better`
- Home / Sleep Now
  - large centered primary button, minimal secondary choices
- Player
  - categorized track list + loop toggle + sleep timer + fade-out stop
- Mixer
  - simple slider rows, no complex visual noise
- Insights
  - 3-card overview: usage frequency, consistency score, average duration

## API structure

Base: `/api/v1/sleepwell`

- `POST /onboarding`
- `GET /onboarding/content`
- `POST /onboarding/responses`
- `GET /catalog`
- `POST /sessions/start`
- `POST /sessions/{session}/event`
- `POST /sessions/{session}/end`
- `POST /sleep-now`
- `GET /insights/{deviceId}`
- `GET /mix-presets/{deviceId}`
- `POST /mix-presets`

## Development roadmap

### Phase 1 (done in this repo)

- MVP product flow and backend data foundation
- Admin visibility for core usage metrics

### Phase 2 (next 1-2 sprints)

- Real audio playback service with background support
- persistent device ID storage across reinstalls (current device ID is hostname/OS based)
- automated fade-out + timer completion events
- admin content CRUD for tracks and categories

### Phase 3 (after PMF signal)

- recommendation engine v1 from event history
- nightly personalization jobs
- experiment framework (A/B for onboarding and Sleep Now)

## Cost-efficient infrastructure plan

- App hosting: Flutter builds (Android/iOS)
- Backend: single Laravel app server (small VM) + managed MySQL/Postgres
- Storage/CDN: object storage for audio + CDN edge caching
- Queues: lightweight worker only when recommendation jobs are introduced
- Observability:
  - start with Laravel logs + basic uptime checks
  - add analytics warehouse only after event volume grows

## Run locally

### Flutter app

```bash
flutter pub get
flutter run
```

With API base URL:

```bash
flutter run --dart-define=SLEEPWELL_API_BASE_URL=https://your-domain.com/api/v1/sleepwell
```

### Laravel API/admin (`cariloker`)

```bash
cd cariloker
composer install
cp .env.example .env
php artisan key:generate
php artisan migrate
php artisan serve
```

Then open:

- API: `http://127.0.0.1:8000/api/v1/sleepwell/catalog`
- Admin: `http://127.0.0.1:8000/dashboard/sleepwell`
- Onboarding Admin: `http://127.0.0.1:8000/dashboard/sleepwell/onboarding`
