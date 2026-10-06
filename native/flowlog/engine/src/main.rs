//! An argus engine: one FlowLog program's dataflow, kept alive between
//! solves and driven over a port.
//!
//! The BEAM opens the engine as a port without stdio (`:nouse_stdio`), so
//! requests arrive on file descriptor 3 and replies leave on 4, each a
//! 4-byte big-endian length and a JSON object. Standard output and error go
//! to the log file named by `--log` (or nowhere), so nothing the runtime
//! prints can be mistaken for a reply.
//!
//! A commit names, for each input relation whose rows changed, a file
//! holding all of its rows (the tab-separated lines argus writes). The
//! engine diffs it against the rows it holds, stages the lines the
//! relation gained and lost, and advances the dataflow by one epoch: only
//! the derivations those lines touch are recomputed. The first commit names
//! every input. Every output a commit changed is written, whole and sorted,
//! into the commit's output directory; the first commit, and one that asks
//! (`"rewrite": true`), writes them all.
//!
//! The engine exits as soon as the port closes, whatever it is doing: a
//! reader thread watches the request descriptor, so a BEAM that timed a
//! solve out, died or halted never leaves an engine running.

mod glue;
mod host;
// The generated module has an insert method for each relation of inline
// facts too, which no engine calls.
#[allow(dead_code)]
mod program {
    include!("program.rs");
}

use std::fs;
use std::fs::File;
use std::io::Read;
use std::io::Write;
use std::os::fd::FromRawFd;
use std::path::Path;
use std::sync::mpsc;
use std::time::Instant;

use host::Changes;
use mimalloc::MiMalloc;
use rustc_hash::FxHashSet;
use serde_json::Value;
use serde_json::json;

#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

/// The protocol this host speaks; argus refuses an engine that answers
/// `hello` with another.
const PROTOCOL: u64 = 1;

/// The largest request argus sends: names and paths, never rows.
const MAX_REQUEST: u32 = 64 * 1024 * 1024;

fn main() {
    let options = Options::parse();
    redirect_stdio(options.log.as_deref());

    // SAFETY: the port owns descriptors 3 and 4 for the process's life;
    // nothing else in the process opens them by number.
    let requests = unsafe { File::from_raw_fd(3) };
    let mut replies = unsafe { File::from_raw_fd(4) };

    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    std::thread::spawn(move || read_requests(requests, &tx));

    let mut engine = Engine::new(options.workers);
    for request in rx {
        let reply = match serde_json::from_slice::<Value>(&request) {
            Ok(request) => engine.handle(&request),
            Err(error) => failure("bad_request", format!("request is not JSON: {error}")),
        };
        let body = reply.to_string().into_bytes();
        let Ok(length) = u32::try_from(body.len()) else {
            std::process::exit(3);
        };
        if replies.write_all(&length.to_be_bytes()).is_err()
            || replies.write_all(&body).is_err()
            || replies.flush().is_err()
        {
            std::process::exit(0);
        }
    }
}

struct Options {
    workers: usize,
    log: Option<String>,
}

impl Options {
    fn parse() -> Self {
        let mut options = Options { workers: 1, log: None };
        let mut args = std::env::args().skip(1);
        while let Some(arg) = args.next() {
            match (arg.as_str(), args.next()) {
                ("--workers", Some(n)) => {
                    options.workers = n.parse().unwrap_or(1).max(1);
                }
                ("--log", Some(path)) => options.log = Some(path),
                _ => {
                    eprintln!("usage: engine [--workers N] [--log PATH]");
                    std::process::exit(2);
                }
            }
        }
        options
    }
}

/// Points standard output and error at the log file, or at /dev/null.
fn redirect_stdio(log: Option<&str>) {
    let target = log
        .and_then(|path| fs::OpenOptions::new().create(true).append(true).open(path).ok())
        .or_else(|| fs::OpenOptions::new().write(true).open("/dev/null").ok());
    if let Some(file) = target {
        use std::os::fd::AsRawFd;
        // SAFETY: dup2 onto the standard descriptors; `file` stays open
        // until both are duplicated.
        unsafe {
            libc::dup2(file.as_raw_fd(), 1);
            libc::dup2(file.as_raw_fd(), 2);
        }
    }
}

/// Forwards each request frame to the main thread, and ends the process
/// when the port closes: at end of file, or a read error.
fn read_requests(mut requests: File, tx: &mpsc::Sender<Vec<u8>>) {
    loop {
        let mut header = [0u8; 4];
        if requests.read_exact(&mut header).is_err() {
            std::process::exit(0);
        }
        let length = u32::from_be_bytes(header);
        if length > MAX_REQUEST {
            std::process::exit(3);
        }
        let mut body = vec![0u8; length as usize];
        if requests.read_exact(&mut body).is_err() || tx.send(body).is_err() {
            std::process::exit(0);
        }
    }
}

fn failure(kind: &str, message: String) -> Value {
    json!({"ok": false, "kind": kind, "message": message})
}

struct Engine {
    dataflow: program::IncrementalEngine,
    workers: usize,
    epoch: u64,
    /// Each input's rows as the engine holds them, by `glue::INPUTS`
    /// index; `None` before the first commit loads it.
    inputs: Vec<Option<FxHashSet<Box<[u8]>>>>,
    /// Each output's rows, by `glue::OUTPUTS` index.
    outputs: Vec<FxHashSet<String>>,
}

impl Engine {
    fn new(workers: usize) -> Self {
        Engine {
            dataflow: program::IncrementalEngine::new(workers),
            workers,
            epoch: 0,
            inputs: vec![None; glue::INPUTS.len()],
            outputs: vec![FxHashSet::default(); glue::OUTPUTS.len()],
        }
    }

    fn handle(&mut self, request: &Value) -> Value {
        match request.get("op").and_then(Value::as_str) {
            Some("hello") => self.hello(),
            Some("commit") => match self.commit(request) {
                Ok(reply) => reply,
                Err((kind, message)) => failure(kind, message),
            },
            Some(other) => failure("bad_request", format!("unknown op `{other}`")),
            None => failure("bad_request", "request has no `op`".to_string()),
        }
    }

    fn hello(&self) -> Value {
        let describe = |relations: &[host::Relation]| {
            relations
                .iter()
                .map(|r| {
                    json!({
                        "name": r.name,
                        "file": r.file,
                        "columns": r.columns.iter().map(|c| c.name()).collect::<Vec<_>>(),
                    })
                })
                .collect::<Vec<_>>()
        };
        json!({
            "ok": true,
            "protocol": PROTOCOL,
            "digest": glue::DIGEST,
            "workers": self.workers,
            "epoch": self.epoch,
            "inputs": describe(glue::INPUTS),
            "outputs": describe(glue::OUTPUTS),
        })
    }

    fn commit(&mut self, request: &Value) -> Result<Value, (&'static str, String)> {
        let started = Instant::now();
        let out_dir = request
            .get("out")
            .and_then(Value::as_str)
            .ok_or(("bad_request", "commit has no `out` directory".to_string()))?;
        // Every output is written, changed or not: the caller lost the files
        // an earlier commit wrote.
        let rewrite = request.get("rewrite").and_then(Value::as_bool).unwrap_or(false);
        let named = request
            .get("inputs")
            .and_then(Value::as_object)
            .ok_or(("bad_request", "commit has no `inputs` object".to_string()))?;

        // Which input each named file replaces, all checked before any is
        // read: an unknown relation, or a first commit missing one, fails
        // the commit whole.
        let mut replaced: Vec<(usize, &str)> = Vec::with_capacity(named.len());
        for (name, path) in named {
            let index = glue::INPUTS
                .iter()
                .position(|r| r.name == name)
                .ok_or_else(|| ("unknown_relation", format!("the program has no input `{name}`")))?;
            let path = path
                .as_str()
                .ok_or_else(|| ("bad_request", format!("input `{name}` names no file")))?;
            replaced.push((index, path));
        }
        let missing: Vec<&str> = glue::INPUTS
            .iter()
            .enumerate()
            .filter(|(i, _)| self.inputs[*i].is_none() && !replaced.iter().any(|(r, _)| r == i))
            .map(|(_, r)| r.name)
            .collect();
        if !missing.is_empty() {
            return Err((
                "missing_inputs",
                format!("the first commit must load every input; missing: {}", missing.join(", ")),
            ));
        }

        let contents: Vec<(usize, Vec<u8>)> = replaced
            .iter()
            .map(|&(index, path)| {
                fs::read(path)
                    .map(|bytes| (index, bytes))
                    .map_err(|e| ("read_failed", format!("cannot read {path}: {e}")))
            })
            .collect::<Result<_, _>>()?;

        let read_done = Instant::now();
        let first = self.epoch == 0;
        let mut staged = false;
        let mut counts = serde_json::Map::new();
        // What each replaced input gained and lost, applied to the held rows
        // only once the commit succeeded.
        let mut deltas: Vec<(usize, Vec<Box<[u8]>>, Vec<Box<[u8]>>)> = Vec::with_capacity(contents.len());
        self.dataflow.begin();
        for (index, bytes) in &contents {
            let fresh: FxHashSet<&[u8]> = host::lines(bytes).into_iter().collect();
            let empty = FxHashSet::default();
            let held = self.inputs[*index].as_ref().unwrap_or(&empty);
            let added: Vec<&[u8]> = fresh.iter().copied().filter(|line| !held.contains(*line)).collect();
            // Every fresh line held, and as many lines as held: the same set.
            let removed: Vec<&[u8]> = if added.is_empty() && fresh.len() == held.len() {
                Vec::new()
            } else {
                held.iter().map(|line| &**line).filter(|line| !fresh.contains(line)).collect()
            };
            let stage = |dataflow: &mut program::IncrementalEngine, lines: &[&[u8]], insert| {
                if lines.is_empty() {
                    return Ok(());
                }
                glue::stage(dataflow, *index, lines, insert)
            };
            if let Err(message) = stage(&mut self.dataflow, &added, true)
                .and_then(|()| stage(&mut self.dataflow, &removed, false))
            {
                self.dataflow.abort();
                return Err(("bad_row", message));
            }
            staged |= !added.is_empty() || !removed.is_empty();
            counts.insert(
                glue::INPUTS[*index].name.to_string(),
                json!({"rows": fresh.len(), "added": added.len(), "removed": removed.len()}),
            );
            deltas.push((
                *index,
                added.into_iter().map(Box::from).collect(),
                removed.into_iter().map(Box::from).collect(),
            ));
        }

        let staged_done = Instant::now();
        let mut changes = Changes::new(glue::OUTPUTS.len());
        if staged || first {
            let results = self.dataflow.commit();
            self.epoch += 1;
            glue::drain(results, &mut changes);
        } else {
            self.dataflow.abort();
        }
        let dataflow_done = Instant::now();
        for (index, added, removed) in deltas {
            let held = self.inputs[index].get_or_insert_with(FxHashSet::default);
            for line in &removed {
                held.remove(line);
            }
            held.extend(added);
        }

        let mut written = Vec::new();
        for (index, delta) in changes.into_outputs().into_iter().enumerate() {
            let rows = &mut self.outputs[index];
            for (line, diff) in &delta {
                if *diff > 0 {
                    rows.insert(line.clone());
                } else if *diff < 0 {
                    rows.remove(line);
                }
            }
            if first || rewrite || !delta.is_empty() {
                let file = glue::OUTPUTS[index].file;
                write_output(&Path::new(out_dir).join(file), rows)
                    .map_err(|e| ("write_failed", format!("cannot write {file}: {e}")))?;
                written.push(file);
            }
        }

        let sizes: serde_json::Map<String, Value> = glue::OUTPUTS
            .iter()
            .zip(&self.outputs)
            .map(|(r, rows)| (r.file.to_string(), json!(rows.len())))
            .collect();
        Ok(json!({
            "ok": true,
            "epoch": self.epoch,
            "written": written,
            "sizes": sizes,
            "inputs": counts,
            "micros": {
                "read": micros(read_done - started),
                "diff": micros(staged_done - read_done),
                "dataflow": micros(dataflow_done - staged_done),
                "total": micros(started.elapsed()),
            },
        }))
    }
}

fn micros(duration: std::time::Duration) -> u64 {
    u64::try_from(duration.as_micros()).unwrap_or(u64::MAX)
}

/// An output's rows, sorted by their bytes and each ended by a newline: a
/// function of the relation alone, so its digest is too.
fn write_output(path: &Path, rows: &FxHashSet<String>) -> std::io::Result<()> {
    let mut sorted: Vec<&str> = rows.iter().map(String::as_str).collect();
    sorted.sort_unstable();
    let mut file = std::io::BufWriter::new(File::create(path)?);
    for row in sorted {
        file.write_all(row.as_bytes())?;
        file.write_all(b"\n")?;
    }
    file.flush()
}
