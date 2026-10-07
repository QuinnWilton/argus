//! What every engine shares, whatever its program: the relation tables'
//! shape, decoding a fact line into columns, collecting a commit's output
//! deltas, and the server that speaks argus's protocol (`main`). A program
//! is a [`Dataflow`]: a compiled engine's `glue.rs`, generated per program,
//! or the tool's generic engine, which reads the program when it starts.
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

use std::fs;
use std::fs::File;
use std::io::Read;
use std::io::Write;
use std::os::fd::FromRawFd;
use std::path::Path;
use std::sync::mpsc;
use std::time::Instant;

use rustc_hash::FxHashSet;
use serde_json::Value;
use serde_json::json;

/// A column's type at the engine's boundary.
#[derive(Clone, Copy)]
pub enum Column {
    Symbol,
    Number,
}

impl Column {
    pub fn name(self) -> &'static str {
        match self {
            Column::Symbol => "symbol",
            Column::Number => "number",
        }
    }
}

/// An input or output relation: its name, the file argus names it by, and
/// its columns.
pub struct Relation {
    pub name: &'static str,
    pub file: &'static str,
    pub columns: &'static [Column],
}

/// The lines of a facts file: split on newlines, with only the newline
/// ending the last line dropped. An empty line in the middle is a row whose
/// one column is the empty string, as argus writes it (`Argus.Tsv`).
pub fn lines(bytes: &[u8]) -> Vec<&[u8]> {
    if bytes.is_empty() {
        return Vec::new();
    }
    let body = bytes.strip_suffix(b"\n").unwrap_or(bytes);
    body.split(|&b| b == b'\n').collect()
}

/// The columns of one line, read in order. A symbol is the text between two
/// tabs as written: argus escapes tabs and newlines inside a value
/// (`Argus.Tsv`), and the escaped spelling travels through the rules and
/// back out unchanged.
pub struct Fields<'a> {
    relation: &'static Relation,
    line: &'a [u8],
    rest: std::slice::Split<'a, u8, fn(&u8) -> bool>,
    read: usize,
}

impl<'a> Fields<'a> {
    pub fn new(relation: &'static Relation, line: &'a [u8]) -> Result<Self, String> {
        fn tab(b: &u8) -> bool {
            *b == b'\t'
        }
        Ok(Fields {
            relation,
            line,
            rest: line.split(tab as fn(&u8) -> bool),
            read: 0,
        })
    }

    fn next(&mut self) -> Result<&'a [u8], String> {
        let field = self.rest.next().ok_or_else(|| self.arity_error())?;
        self.read += 1;
        Ok(field)
    }

    pub fn symbol(&mut self) -> Result<String, String> {
        let field = self.next()?;
        String::from_utf8(field.to_vec()).map_err(|_| self.error("is not UTF-8"))
    }

    pub fn number(&mut self) -> Result<i32, String> {
        let field = self.next()?;
        std::str::from_utf8(field)
            .ok()
            .and_then(|text| text.parse::<i32>().ok())
            .ok_or_else(|| self.error("is not a 32-bit number"))
    }

    /// Fails unless every column was read: a line with more columns than
    /// its relation is malformed, not truncated.
    pub fn end(&mut self) -> Result<(), String> {
        if self.rest.next().is_some() {
            return Err(self.arity_error());
        }
        Ok(())
    }

    fn arity_error(&self) -> String {
        let found = self.line.split(|&b| b == b'\t').count();
        format!(
            "a `{}` row has {found} columns, but the relation has {}: {}",
            self.relation.name,
            self.relation.columns.len(),
            String::from_utf8_lossy(self.line)
        )
    }

    fn error(&self, what: &str) -> String {
        format!(
            "column {} of a `{}` row {what}: {}",
            self.read,
            self.relation.name,
            String::from_utf8_lossy(self.line)
        )
    }
}

/// What an engine holds of an input: the lines of the file it was last
/// committed from, counted and summed by hash, which any order of the
/// same lines gives. The engine keeps no line itself: a commit that
/// changes the input names that file, checked against this, and the
/// engine diffs the two.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Held {
    lines: usize,
    sum: u128,
}

fn line_hash(line: &[u8]) -> u128 {
    use std::hash::{BuildHasher, Hasher};
    let mut low = rustc_hash::FxBuildHasher.build_hasher();
    low.write(line);
    let mut high = rustc_hash::FxBuildHasher.build_hasher();
    high.write_u64(0x9e37_79b9_7f4a_7c15);
    high.write(line);
    u128::from(high.finish()) << 64 | u128::from(low.finish())
}

impl Held {
    fn of(bytes: &[u8]) -> Self {
        let mut held = Held::default();
        for line in lines(bytes) {
            held.add(line);
        }
        held
    }

    fn add(&mut self, line: &[u8]) {
        self.lines += 1;
        self.sum = self.sum.wrapping_add(line_hash(line));
    }

    fn remove(&mut self, line: &[u8]) {
        self.lines -= 1;
        self.sum = self.sum.wrapping_sub(line_hash(line));
    }
}

/// How an input's file moved: what the engine held of the previous one,
/// what it holds of the fresh one, and the distinct lines the fresh one
/// gained and lost.
struct Diff<'a> {
    previous: Held,
    fresh: Held,
    added: Vec<&'a [u8]>,
    removed: Vec<&'a [u8]>,
}

/// The lines `fresh` gains and loses against `previous`, each once.
///
/// argus writes a relation's file module by module, in a stable order, so
/// an edit moves one stretch of it: the lines both files begin and end
/// with are the same, and only the stretch between is compared, as sets.
/// A line that stretch gains or loses but that the files share elsewhere
/// is neither; one pass over the previous file finds those, and hashes
/// it to check it against what the engine holds.
fn diff<'a>(previous: &'a [u8], fresh: &'a [u8]) -> Diff<'a> {
    let boundary = |bytes: &[u8], at: usize| at == 0 || bytes[at - 1] == b'\n';
    let mut head = previous
        .iter()
        .zip(fresh)
        .take_while(|(a, b)| a == b)
        .count();
    if head == previous.len() && head == fresh.len() {
        let held = Held::of(previous);
        return Diff {
            previous: held,
            fresh: held,
            added: Vec::new(),
            removed: Vec::new(),
        };
    }
    while !boundary(previous, head) {
        head -= 1;
    }
    let room = (previous.len() - head).min(fresh.len() - head);
    let mut tail = previous[head..]
        .iter()
        .rev()
        .zip(fresh[head..].iter().rev())
        .take(room)
        .take_while(|(a, b)| a == b)
        .count();
    while tail > 0
        && !(boundary(previous, previous.len() - tail) && boundary(fresh, fresh.len() - tail))
    {
        tail -= 1;
    }
    let (old_middle, new_middle) = (
        &previous[head..previous.len() - tail],
        &fresh[head..fresh.len() - tail],
    );
    let old_lines: FxHashSet<&[u8]> = lines(old_middle).into_iter().collect();
    let new_lines: FxHashSet<&[u8]> = lines(new_middle).into_iter().collect();
    let mut added: FxHashSet<&[u8]> = new_lines.difference(&old_lines).copied().collect();
    let mut removed: FxHashSet<&[u8]> = old_lines.difference(&new_lines).copied().collect();

    // The previous file whole, hashed; its shared lines, against the
    // stretch's changes.
    let mut held = Held::default();
    let mut at = 0;
    for line in lines(previous) {
        held.add(line);
        let shared = at < head || at >= previous.len() - tail;
        if shared && (!added.is_empty() || !removed.is_empty()) {
            added.remove(line);
            removed.remove(line);
        }
        at += line.len() + 1;
    }
    let mut fresh_held = held;
    for line in lines(old_middle) {
        fresh_held.remove(line);
    }
    for line in lines(new_middle) {
        fresh_held.add(line);
    }
    Diff {
        previous: held,
        fresh: fresh_held,
        added: added.into_iter().collect(),
        removed: removed.into_iter().collect(),
    }
}

/// A commit's output deltas: each output's changed lines with their signed
/// weight, by output index.
pub struct Changes {
    outputs: Vec<Vec<(String, i32)>>,
}

impl Changes {
    pub fn new(outputs: usize) -> Self {
        Changes {
            outputs: vec![Vec::new(); outputs],
        }
    }

    pub fn record(&mut self, output: usize, line: String, diff: i32) {
        if diff != 0 {
            self.outputs[output].push((line, diff));
        }
    }

    pub fn into_outputs(self) -> Vec<Vec<(String, i32)>> {
        self.outputs
    }
}

// =============================================================================
// The server
// =============================================================================

/// The protocol this host speaks; argus refuses an engine that answers
/// `hello` with another.
const PROTOCOL: u64 = 1;

/// The largest request argus sends: names and paths, never rows.
const MAX_REQUEST: u32 = 64 * 1024 * 1024;

/// A program's dataflow as the server drives it: its relations, staging
/// one input's lines, and committing what was staged as one epoch.
pub trait Dataflow {
    /// The program digest the engine was made for; `hello` reports it.
    fn digest(&self) -> &str;
    /// The input relations, by the index `stage` takes.
    fn inputs(&self) -> &'static [Relation];
    /// The output relations, by the index `Changes` records.
    fn outputs(&self) -> &'static [Relation];
    /// Starts staging a transaction, dropping anything staged before.
    fn begin(&mut self);
    /// Drops everything staged since `begin`.
    fn abort(&mut self);
    /// Stages `lines` of input `index` as insertions or deletions. Every
    /// line is decoded before any is staged, so a malformed one stages none.
    fn stage(&mut self, index: usize, lines: &[&[u8]], insert: bool) -> Result<(), String>;
    /// Applies what was staged as one epoch, recording each output's
    /// changed lines with their signed weights; or refuses, leaving the
    /// dataflow part way through the epoch, so that it takes no other.
    fn commit(&mut self, changes: &mut Changes) -> Result<(), Refusal>;
}

/// Why a dataflow stopped a commit part way: `kind` for argus to act on
/// (`limitsize`: a relation outgrew the limit the program sets it), and
/// a message for a person.
pub struct Refusal {
    pub kind: &'static str,
    pub message: String,
    /// What argus reads of the refusal, beside the message (for
    /// `limitsize`: the relation, its rows, and its limit).
    pub detail: Value,
}

/// Runs the server over `args` (the command line after the program
/// name): `--workers N` and `--log PATH`, and the flags `make` takes,
/// given as pairs. `make` builds the dataflow with the worker count; when
/// it fails, every request is answered with its reason, as kind
/// `program`, until the port closes.
pub fn main<D: Dataflow>(
    args: impl Iterator<Item = String>,
    make: impl FnOnce(usize, &[(String, String)]) -> Result<D, String>,
) -> ! {
    let options = Options::parse(args);
    redirect_stdio(options.log.as_deref());

    // SAFETY: the port owns descriptors 3 and 4 for the process's life;
    // nothing else in the process opens them by number.
    let requests = unsafe { File::from_raw_fd(3) };
    let mut replies = unsafe { File::from_raw_fd(4) };

    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    std::thread::spawn(move || read_requests(requests, &tx));

    let mut engine = make(options.workers, &options.extra)
        .map(|dataflow| Engine::new(dataflow, options.workers));
    for request in rx {
        let reply = match (&mut engine, serde_json::from_slice::<Value>(&request)) {
            (Err(reason), _) => failure("program", reason.clone()),
            (Ok(engine), Ok(request)) => engine.handle(&request),
            (Ok(_), Err(error)) => failure("bad_request", format!("request is not JSON: {error}")),
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
    std::process::exit(0)
}

struct Options {
    workers: usize,
    log: Option<String>,
    /// Every other `--flag value`, in order, for the dataflow's maker.
    extra: Vec<(String, String)>,
}

impl Options {
    fn parse(mut args: impl Iterator<Item = String>) -> Self {
        let mut options = Options {
            workers: 1,
            log: None,
            extra: Vec::new(),
        };
        while let Some(arg) = args.next() {
            match (arg.as_str(), args.next()) {
                ("--workers", Some(n)) => {
                    options.workers = n.parse().unwrap_or(1).max(1);
                }
                ("--log", Some(path)) => options.log = Some(path),
                (flag, Some(value)) if flag.starts_with("--") => {
                    options.extra.push((flag.to_string(), value));
                }
                _ => {
                    eprintln!("usage: engine [--workers N] [--log PATH] [--FLAG VALUE ...]");
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
        .and_then(|path| {
            fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .ok()
        })
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

struct Engine<D: Dataflow> {
    dataflow: D,
    workers: usize,
    epoch: u64,
    /// Each input's rows as the engine holds them, by `self.dataflow.inputs()`
    /// index; `None` before the first commit loads it.
    inputs: Vec<Option<Held>>,
    /// Each output's rows, by `self.dataflow.outputs()` index.
    outputs: Vec<FxHashSet<String>>,
    /// Why a commit stopped part way, after which none is taken.
    poisoned: Option<String>,
    /// The detail of the refusal the last commit answered with, if any.
    refused: Option<Value>,
}

impl<D: Dataflow> Engine<D> {
    fn new(dataflow: D, workers: usize) -> Self {
        let (inputs, outputs) = (dataflow.inputs().len(), dataflow.outputs().len());
        Engine {
            dataflow,
            workers,
            epoch: 0,
            inputs: vec![None; inputs],
            outputs: vec![FxHashSet::default(); outputs],
            poisoned: None,
            refused: None,
        }
    }

    fn handle(&mut self, request: &Value) -> Value {
        match request.get("op").and_then(Value::as_str) {
            Some("hello") => self.hello(),
            Some("commit") => match self.commit(request) {
                Ok(reply) => reply,
                Err((kind, message)) => {
                    let mut reply = failure(kind, message);
                    if let Some(detail) = self.refused.take() {
                        reply["detail"] = detail;
                    }
                    reply
                }
            },
            Some(other) => failure("bad_request", format!("unknown op `{other}`")),
            None => failure("bad_request", "request has no `op`".to_string()),
        }
    }

    fn hello(&self) -> Value {
        let describe = |relations: &[Relation]| {
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
            "digest": self.dataflow.digest(),
            "workers": self.workers,
            "epoch": self.epoch,
            "inputs": describe(self.dataflow.inputs()),
            "outputs": describe(self.dataflow.outputs()),
        })
    }

    fn commit(&mut self, request: &Value) -> Result<Value, (&'static str, String)> {
        if let Some(reason) = &self.poisoned {
            return Err((
                "poisoned",
                format!("an earlier commit stopped part way ({reason}); start another engine"),
            ));
        }
        let started = Instant::now();
        let out_dir = request
            .get("out")
            .and_then(Value::as_str)
            .ok_or(("bad_request", "commit has no `out` directory".to_string()))?;
        // Every output is written, changed or not: the caller lost the files
        // an earlier commit wrote.
        let rewrite = request
            .get("rewrite")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let named = request
            .get("inputs")
            .and_then(Value::as_object)
            .ok_or(("bad_request", "commit has no `inputs` object".to_string()))?;

        // Which input each named file replaces, all checked before any is
        // read: an unknown relation, or a first commit missing one, fails
        // the commit whole. An input the engine holds is named with the
        // file it was last committed from (`previous`), to diff against.
        let mut replaced: Vec<(usize, &str, Option<&str>)> = Vec::with_capacity(named.len());
        for (name, entry) in named {
            let index = self
                .dataflow
                .inputs()
                .iter()
                .position(|r| r.name == name)
                .ok_or_else(|| {
                    (
                        "unknown_relation",
                        format!("the program has no input `{name}`"),
                    )
                })?;
            let (path, previous) = match entry {
                Value::String(path) => (path.as_str(), None),
                Value::Object(entry) => (
                    entry
                        .get("path")
                        .and_then(Value::as_str)
                        .ok_or_else(|| ("bad_request", format!("input `{name}` names no file")))?,
                    entry.get("previous").and_then(Value::as_str),
                ),
                _ => return Err(("bad_request", format!("input `{name}` names no file"))),
            };
            match (self.inputs[index].is_some(), previous) {
                (true, None) => {
                    return Err((
                        "bad_request",
                        format!(
                            "the engine holds input `{name}`: name the file it was last \
                             committed from (`previous`)"
                        ),
                    ));
                }
                (false, Some(_)) => {
                    return Err((
                        "bad_request",
                        format!("the engine holds no `{name}` to diff a `previous` file against"),
                    ));
                }
                _ => {}
            }
            replaced.push((index, path, previous));
        }
        let missing: Vec<&str> = self
            .dataflow
            .inputs()
            .iter()
            .enumerate()
            .filter(|(i, _)| self.inputs[*i].is_none() && !replaced.iter().any(|(r, _, _)| r == i))
            .map(|(_, r)| r.name)
            .collect();
        if !missing.is_empty() {
            return Err((
                "missing_inputs",
                format!(
                    "the first commit must load every input; missing: {}",
                    missing.join(", ")
                ),
            ));
        }

        let read = |path: &str| {
            fs::read(path).map_err(|e| ("read_failed", format!("cannot read {path}: {e}")))
        };
        let contents: Vec<(usize, Vec<u8>, Option<Vec<u8>>)> = replaced
            .iter()
            .map(|&(index, path, previous)| {
                Ok((index, read(path)?, previous.map(read).transpose()?))
            })
            .collect::<Result<_, (&'static str, String)>>()?;

        let read_done = Instant::now();
        let first = self.epoch == 0;
        let mut staged = false;
        let mut counts = serde_json::Map::new();
        // What each replaced input holds afterwards, recorded only once the
        // commit succeeded.
        let mut holds: Vec<(usize, Held)> = Vec::with_capacity(contents.len());
        // Each input's change: against its `previous` file, checked against
        // what the engine holds, or every line of a first load.
        let mut diffs: Vec<Diff<'_>> = Vec::with_capacity(contents.len());
        for (index, bytes, previous) in &contents {
            let diff = match previous {
                Some(previous) => {
                    let diff = diff(previous, bytes);
                    if Some(diff.previous) != self.inputs[*index] {
                        return Err((
                            "stale_previous",
                            format!(
                                "input `{}`: the `previous` file is not what the engine holds",
                                self.dataflow.inputs()[*index].name
                            ),
                        ));
                    }
                    diff
                }
                None => {
                    let fresh: FxHashSet<&[u8]> = lines(bytes).into_iter().collect();
                    Diff {
                        previous: Held::default(),
                        fresh: Held::of(bytes),
                        added: fresh.into_iter().collect(),
                        removed: Vec::new(),
                    }
                }
            };
            diffs.push(diff);
        }
        self.dataflow.begin();
        for (
            (index, _, _),
            Diff {
                fresh,
                added,
                removed,
                ..
            },
        ) in contents.iter().zip(diffs)
        {
            let stage = |dataflow: &mut D, lines: &[&[u8]], insert| {
                if lines.is_empty() {
                    return Ok(());
                }
                dataflow.stage(*index, lines, insert)
            };
            if let Err(message) = stage(&mut self.dataflow, &added, true)
                .and_then(|()| stage(&mut self.dataflow, &removed, false))
            {
                self.dataflow.abort();
                return Err(("bad_row", message));
            }
            staged |= !added.is_empty() || !removed.is_empty();
            counts.insert(
                self.dataflow.inputs()[*index].name.to_string(),
                json!({"rows": fresh.lines, "added": added.len(), "removed": removed.len()}),
            );
            holds.push((*index, fresh));
        }

        let staged_done = Instant::now();
        let mut changes = Changes::new(self.dataflow.outputs().len());
        if staged || first {
            if let Err(refusal) = self.dataflow.commit(&mut changes) {
                // Part way through an epoch, the dataflow answers nothing
                // reliably again: every later commit is refused too.
                self.poisoned = Some(refusal.message.clone());
                self.refused = Some(refusal.detail);
                return Err((refusal.kind, refusal.message));
            }
            self.epoch += 1;
        } else {
            self.dataflow.abort();
        }
        let dataflow_done = Instant::now();
        for (index, held) in holds {
            self.inputs[index] = Some(held);
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
                let file = self.dataflow.outputs()[index].file;
                write_output(&Path::new(out_dir).join(file), rows)
                    .map_err(|e| ("write_failed", format!("cannot write {file}: {e}")))?;
                written.push(file);
            }
        }

        let sizes: serde_json::Map<String, Value> = self
            .dataflow
            .outputs()
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A small deterministic generator: xorshift.
    struct Rng(u64);

    impl Rng {
        fn next(&mut self, bound: u64) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0 % bound
        }
    }

    fn file(lines: &[String], trailing: bool) -> Vec<u8> {
        let mut bytes = lines.join("\n").into_bytes();
        if trailing && !lines.is_empty() {
            bytes.push(b'\n');
        }
        bytes
    }

    #[test]
    fn a_diff_is_the_two_files_difference_as_sets() {
        let mut rng = Rng(0x2545_f491_4f6c_dd1d);
        for _ in 0..4000 {
            // Few distinct lines, so that duplicates and lines shared with
            // the unchanged stretches are common.
            let line = |rng: &mut Rng| format!("r{}\t{}", rng.next(6), rng.next(3));
            let previous: Vec<String> = (0..rng.next(12)).map(|_| line(&mut rng)).collect();
            let mut fresh = previous.clone();
            for _ in 0..rng.next(4) {
                match rng.next(3) {
                    0 if !fresh.is_empty() => {
                        let at = rng.next(fresh.len() as u64) as usize;
                        fresh.remove(at);
                    }
                    1 => {
                        let at = rng.next(fresh.len() as u64 + 1) as usize;
                        fresh.insert(at, line(&mut rng));
                    }
                    _ if !fresh.is_empty() => {
                        let at = rng.next(fresh.len() as u64) as usize;
                        fresh[at] = line(&mut rng);
                    }
                    _ => {}
                }
            }
            let (a, b) = (rng.next(2) == 0, rng.next(2) == 0);
            let (old_bytes, new_bytes) = (file(&previous, a), file(&fresh, b));
            let d = diff(&old_bytes, &new_bytes);

            let old_set: FxHashSet<&[u8]> = lines(&old_bytes).into_iter().collect();
            let new_set: FxHashSet<&[u8]> = lines(&new_bytes).into_iter().collect();
            let added: FxHashSet<&[u8]> = d.added.iter().copied().collect();
            let removed: FxHashSet<&[u8]> = d.removed.iter().copied().collect();
            let want_added: FxHashSet<&[u8]> = new_set.difference(&old_set).copied().collect();
            let want_removed: FxHashSet<&[u8]> = old_set.difference(&new_set).copied().collect();
            assert_eq!(added, want_added, "{previous:?} -> {fresh:?}");
            assert_eq!(removed, want_removed, "{previous:?} -> {fresh:?}");
            assert_eq!(added.len(), d.added.len(), "each line added once");
            assert_eq!(removed.len(), d.removed.len(), "each line removed once");
            assert_eq!(d.previous, Held::of(&old_bytes));
            assert_eq!(d.fresh, Held::of(&new_bytes));
        }
    }

    #[test]
    fn what_an_engine_holds_does_not_depend_on_the_lines_order() {
        assert_eq!(Held::of(b"a\nb\nc\n"), Held::of(b"c\na\nb"));
        assert_ne!(Held::of(b"a\nb\n"), Held::of(b"a\nc\n"));
        assert_ne!(Held::of(b"a\n"), Held::of(b"a\na\n"));
    }
}
