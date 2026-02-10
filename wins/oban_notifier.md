# Oban: coupled siblings under one_for_one

PR: https://github.com/oban-bg/oban/pull/1413

## Discovery

Ran argus `one_for_one_coupling` analysis against Oban's 69 project modules.

**Supervision structure found:**

```
Oban (one_for_one)
  ├── 0. Notifier
  ├── 1. Nursery
  ├── 2. Peer
  ├── 3. Sonar
  └── 4. Harbor
```

**Finding: coupled siblings under one_for_one.** `Oban.Sonar` transitively
depends on `Oban.Notifier` — it calls `Notifier.listen/2` and
`Notifier.notify/3` during its `handle_continue(:start, ...)` callback. Both
are siblings under a `one_for_one` supervisor. If Notifier crashes, Sonar
continues running but cannot listen or broadcast, leading to silent
degradation of the pubsub health monitoring system.

`Oban.Midwife` has the identical pattern with the `:signal` channel, under
a different supervisor branch (Nursery, `rest_for_one`).

## Fix

- **Sonar**: re-registers on every ping cycle by calling `Notifier.listen`
  before `Notifier.notify`, wrapped in `try/catch` to survive transient
  Notifier unavailability.
- **Midwife**: monitors the Notifier process and re-registers on `:DOWN`
  via `handle_continue`, with timed retry fallback.

## Reproduce

```bash
cd /tmp && git clone --depth 1 https://github.com/oban-bg/oban.git
cd oban && mix deps.get && mix compile
cd /path/to/argus && mix run scripts/analyze_project.exs /tmp/oban
```
