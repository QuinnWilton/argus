//! What a profiled generic engine measures (`serve --profile PATH`): the
//! updates each arrangement holds and the time each operator ran, by the
//! names the engine gives them (a relation's, or the rule expression a
//! collection is), written to `PATH` after every commit.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;
use std::time::Instant;

use flowlog_runtime::differential_dataflow::logging::DifferentialEvent;
use flowlog_runtime::timely::logging::StartStop;
use flowlog_runtime::timely::logging::TimelyEvent;

/// Operators that are scopes: their time is their children's.
const SCOPES: [&str; 2] = ["Dataflow", "Iterative"];

pub struct Profile {
    path: PathBuf,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    /// Each worker's arrangements' updates, by operator.
    updates: HashMap<(usize, usize), i64>,
    names: HashMap<usize, String>,
    started: HashMap<(usize, usize), Instant>,
    busy: HashMap<usize, Duration>,
}

impl Profile {
    pub fn new(path: PathBuf) -> Arc<Self> {
        Arc::new(Profile {
            path,
            state: Mutex::new(State::default()),
        })
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().expect("the profile")
    }

    /// The `differential/arrange` logger for `worker`: an arrangement's
    /// updates are its batches', less what merging two batches cancelled,
    /// less what was dropped.
    pub fn arrangements(
        self: &Arc<Self>,
        worker: usize,
    ) -> impl FnMut(&Duration, &mut Option<Vec<(Duration, DifferentialEvent)>>) + 'static {
        let profile = Arc::clone(self);
        move |_time, events| {
            let Some(events) = events else { return };
            let mut state = profile.state();
            for (_, event) in events.iter() {
                let (operator, change) = match event {
                    DifferentialEvent::Batch(batch) => (batch.operator, batch.length as i64),
                    DifferentialEvent::Merge(merge) => match merge.complete {
                        Some(merged) => (
                            merge.operator,
                            merged as i64 - (merge.length1 + merge.length2) as i64,
                        ),
                        None => continue,
                    },
                    DifferentialEvent::Drop(dropped) => {
                        (dropped.operator, -(dropped.length as i64))
                    }
                    _ => continue,
                };
                *state.updates.entry((worker, operator)).or_default() += change;
            }
        }
    }

    /// The `timely` logger for `worker`: operators' names, and the time
    /// each ran.
    pub fn operators(
        self: &Arc<Self>,
        worker: usize,
    ) -> impl FnMut(&Duration, &mut Option<Vec<(Duration, TimelyEvent)>>) + 'static {
        let profile = Arc::clone(self);
        move |_time, events| {
            let Some(events) = events else { return };
            let mut state = profile.state();
            for (_, event) in events.iter() {
                match event {
                    TimelyEvent::Operates(operates) => {
                        state.names.insert(operates.id, operates.name.clone());
                    }
                    TimelyEvent::Schedule(schedule) => match schedule.start_stop {
                        StartStop::Start => {
                            state.started.insert((worker, schedule.id), Instant::now());
                        }
                        StartStop::Stop => {
                            if let Some(started) = state.started.remove(&(worker, schedule.id)) {
                                *state.busy.entry(schedule.id).or_default() += started.elapsed();
                            }
                        }
                    },
                    _ => {}
                }
            }
        }
    }

    /// Writes what was measured so far: every arrangement by the updates
    /// it holds, and the operators by the time they ran, the largest first.
    pub fn write(&self) -> std::io::Result<()> {
        let state = self.state();
        let name = |operator: &usize| {
            state
                .names
                .get(operator)
                .cloned()
                .unwrap_or_else(|| format!("operator {operator}"))
        };
        let mut updates: HashMap<usize, i64> = HashMap::new();
        for ((_, operator), held) in &state.updates {
            *updates.entry(*operator).or_default() += held;
        }
        let mut arrangements: Vec<(String, i64)> =
            updates.iter().map(|(op, held)| (name(op), *held)).collect();
        arrangements.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        let mut operators: Vec<(String, f64)> = state
            .busy
            .iter()
            .map(|(op, busy)| (name(op), busy.as_secs_f64()))
            .filter(|(name, _)| !SCOPES.contains(&name.as_str()))
            .collect();
        operators.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        let report = serde_json::json!({
            "arranged": arrangements.iter().map(|(_, held)| held).sum::<i64>(),
            "arrangements": arrangements
                .iter()
                .map(|(name, updates)| serde_json::json!({"name": name, "updates": updates}))
                .collect::<Vec<_>>(),
            "operators": operators
                .iter()
                .map(|(name, seconds)| serde_json::json!({"name": name, "seconds": seconds}))
                .collect::<Vec<_>>(),
        });
        std::fs::write(&self.path, report.to_string())
    }
}
