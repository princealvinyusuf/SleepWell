# SleepWell Observability

## Core KPIs
- Daily active listeners.
- Session completion rate.
- Average session duration.
- Bedtime reminder open rate.
- Bedtime missed rate (`schedule_missed` / scheduled reminders).
- Login conversion rate.
- Ad fill and click-through rate.

## Operational dashboards
- API error rates by endpoint (`/sleep-now`, `/sessions/*`, `/auth/*`).
- Session event ingestion lag.
- Failed queued event flush count.
- Ad placement enabled/disabled distribution.

## Alerts
- 5xx error rate > 2% over 5 minutes.
- Session start success drops below 95%.
- Auth login failure spike > baseline + 3 sigma.
- Ad placement endpoint latency > 500 ms p95.
- Queued event backlog > 50 for any user over 30 minutes.

## Event taxonomy
- Playback: `play`, `pause`, `resume`, `timer_set`, `timer_completed`.
- Mixer: `mixer_start`, `mixer_stop`, `mixer_preset_apply`.
- Routine: `schedule_triggered`, `schedule_adherence_hit`, `schedule_missed`.
- Ads: `ad_impression`, `ad_click`.
