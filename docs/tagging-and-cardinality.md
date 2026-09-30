# Naming, tags and cardinality

Metrics are **aggregated on the hub** into time buckets per *series*
(metric name + tag set). Every distinct tag combination is a new series, so tags
must be **low-cardinality** (bounded, small sets).

## Good
- Names: `http.requests`, `db.query_ms`, `queue.depth` — dotted, lowercase, units in the name or `unit`.
- Tags: `region=eu`, `route=/orders`, `status_class=5xx`, `method=GET`.

## Bad
- Tags with user ids, session ids, request ids, emails, full URLs, timestamps.
  Put those in a **log/event `attrs`** instead — attrs are stored, not aggregated.
- Names built from data: `latency_user_12345`.

## Hard limits (see SPEC §4)
≤ 8 tag keys per point, values ≤ 64 chars, ≤ 2000 series per app and ≤ 200 per
metric name. Beyond the cap the hub folds new combos into `tag=_overflow`; totals
stay correct, only the breakdown is lost. The admin telemetry page shows a
"cap hit" indicator when this happens.

## Types
| Type | Send | Query as |
|------|------|----------|
| counter | the **delta** since your last send (≥ 0) | rate, sum |
| gauge | current value | last, avg, min, max |
| histogram | one observation (or `n` identical ones) | p50, p95, p99, avg |
