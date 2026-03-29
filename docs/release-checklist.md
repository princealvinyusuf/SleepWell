# SleepWell Release Checklist

## Backend
- Run `composer install` in `cariloker`.
- Run migrations: `php artisan migrate`.
- Seed required SleepWell data:
  - `php artisan db:seed --class=SleepWellHomeFeedSeeder`
  - `php artisan db:seed --class=SleepWellAdPlacementSeeder`
- Verify `/api/v1/sleepwell/auth/register`, `/auth/login`, `/auth/me`, `/home-feed`, `/ad-placements`.

## Flutter app
- Run `flutter pub get`.
- Verify environment API base URL points to production.
- Configure AdMob app ids and placement unit ids in backoffice.
- Run smoke checks on Home, Profile, Settings, Saved, Sounds, Routine, Insights.

## QA and analytics
- Confirm session lifecycle events: start/event/end.
- Confirm queued offline events flush after reconnect.
- Confirm account login/register/logout and data sync.
- Confirm ad placements render only for enabled slots.

## Go-live checks
- CI passing (`flutter analyze`, `flutter test`, backend tests).
- Crash-free cold start on Android and iOS.
- Rollback plan prepared (DB backup + previous app build).
