//! `argus-flowlog-tool`: what argus asks of a FlowLog program before it
//! builds an engine for it.
//!
//! ```text
//! argus-flowlog-tool inspect PROGRAM
//! argus-flowlog-tool generate PROGRAM SRC_DIR DIGEST
//! ```
//!
//! Both print the program's manifest as one JSON object on stdout and exit
//! 0, or print `{"ok": false, "diagnostic": ...}` and exit 1 when the program
//! does not compile or is not one argus can host. `inspect`'s manifest also
//! lists every relation with its columns (`relations`), for a debugging
//! probe to name. `inspect` runs FlowLog's
//! front end and planner only; `generate` also writes the engine's
//! `program.rs` (FlowLog's library-mode module) and `glue.rs` (the typed
//! dispatch between the engine host and that module) into `SRC_DIR`.

use std::fmt::Write as _;
use std::fs;
use std::path::Path;
use std::path::PathBuf;
use std::process::ExitCode;

use flowlog_common::Config;
use flowlog_common::SourceMap;
use flowlog_common::emit;
use flowlog_parser::DataType;
use flowlog_parser::Mutability;
use flowlog_parser::Program;
use flowlog_parser::Relation;
use serde_json::Value;
use serde_json::json;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.as_slice() {
        [cmd, program] if cmd == "inspect" => inspect(Path::new(program)),
        [cmd, program, src_dir, digest] if cmd == "generate" => {
            generate(Path::new(program), Path::new(src_dir), digest)
        }
        _ => Err(Failure::Usage),
    };
    match result {
        Ok(manifest) => {
            println!("{manifest}");
            ExitCode::SUCCESS
        }
        Err(Failure::Usage) => {
            eprintln!(
                "usage: argus-flowlog-tool inspect PROGRAM\n       \
                 argus-flowlog-tool generate PROGRAM SRC_DIR DIGEST"
            );
            ExitCode::from(2)
        }
        Err(Failure::Program(diagnostic)) => {
            println!("{}", json!({"ok": false, "diagnostic": diagnostic}));
            ExitCode::FAILURE
        }
    }
}

enum Failure {
    Usage,
    /// The program does not compile, or argus cannot host it: the text a
    /// user reads, rendered against the source where FlowLog located it.
    Program(String),
}

/// A column type an engine exchanges with argus: facts and findings are
/// symbols and 32-bit numbers, as argus's schema declares them.
#[derive(Clone, Copy)]
enum Column {
    Symbol,
    Number,
}

impl Column {
    fn name(self) -> &'static str {
        match self {
            Column::Symbol => "symbol",
            Column::Number => "number",
        }
    }

    fn variant(self) -> &'static str {
        match self {
            Column::Symbol => "Column::Symbol",
            Column::Number => "Column::Number",
        }
    }
}

struct Io {
    /// The relation's name as the program spells it.
    name: String,
    /// The identifier FlowLog's library API derives its methods from.
    ident: String,
    file: String,
    columns: Vec<Column>,
}

fn parse(program: &Path) -> Result<(Program, SourceMap), Failure> {
    let path = program
        .to_str()
        .ok_or_else(|| Failure::Program(format!("non-UTF-8 program path: {}", program.display())))?;
    let mut sources = SourceMap::new();
    let mut config = Config {
        program: path.to_string(),
        str_intern: true,
        ..Config::default()
    };
    match flowlog_parser::parse(path, &[] as &[&Path], &mut sources, &mut config) {
        Ok(parsed) => Ok((parsed, sources)),
        Err(error) => Err(Failure::Program(render(&error.into(), &sources))),
    }
}

fn render(error: &flowlog_common::BoxError, sources: &SourceMap) -> String {
    let mut buffer = Vec::new();
    match emit(error, sources, &mut buffer) {
        Ok(()) => String::from_utf8_lossy(&buffer).into_owned(),
        Err(_) => error.to_string(),
    }
}

/// The program's inputs and outputs, or why argus cannot host it.
fn interface(program: &Program) -> Result<(Vec<Io>, Vec<Io>), Failure> {
    let mut problems = Vec::new();

    // An input is a relation the program reads from argus (`.input`). A
    // relation of inline facts alone is part of the program and never
    // changes, however FlowLog classifies it.
    let mut inputs = Vec::new();
    for rel in program.edbs().into_iter().filter(|rel| rel.has_input()) {
        if rel.input_mutability() != Mutability::Mutable {
            problems.push(format!(
                "input relation `{}` must be declared `mutable`: an engine keeps its \
                 dataflow between solves and deletes the rows a relation loses",
                rel.raw_name()
            ));
        }
        let file = rel
            .input()
            .and_then(|source| source.filename())
            .map_or_else(|| format!("{}.facts", rel.raw_name()), str::to_string);
        if let Some(io) = io(rel, file, "input", &mut problems) {
            inputs.push(io);
        }
    }

    let mut outputs = Vec::new();
    for rel in program.output_idbs() {
        let file = rel
            .output_sink()
            .map_or_else(|| format!("{}.csv", rel.raw_name()), |sink| sink.filename().to_string());
        if let Some(io) = io(rel, file, "output", &mut problems) {
            outputs.push(io);
        }
    }
    if inputs.is_empty() && problems.is_empty() {
        problems.push(
            "the program reads no input relation (`.input`): an engine keeps a program's \
             results up to date as its inputs change, so it needs at least one"
                .into(),
        );
    }
    if outputs.is_empty() && problems.is_empty() {
        problems.push("the program has no `.output` relation, so a solve derives nothing".into());
    }

    let mut files: Vec<&str> = outputs.iter().map(|io| io.file.as_str()).collect();
    files.sort_unstable();
    for pair in files.windows(2) {
        if pair[0] == pair[1] {
            problems.push(format!("two output relations write `{}`", pair[0]));
        }
    }

    if problems.is_empty() {
        Ok((inputs, outputs))
    } else {
        Err(Failure::Program(format!(
            "error: argus cannot host this program\n{}",
            problems.iter().fold(String::new(), |mut text, problem| {
                let _ = writeln!(text, "  - {problem}");
                text
            })
        )))
    }
}

fn io(rel: &Relation, file: String, role: &str, problems: &mut Vec<String>) -> Option<Io> {
    if rel.arity() == 0 {
        problems.push(format!(
            "{role} relation `{}` has no columns; argus exchanges rows of symbols and numbers",
            rel.raw_name()
        ));
        return None;
    }
    let mut columns = Vec::with_capacity(rel.arity());
    for (attribute, data_type) in rel.attributes().iter().zip(rel.data_type()) {
        match data_type {
            DataType::String => columns.push(Column::Symbol),
            DataType::Int32 => columns.push(Column::Number),
            other => {
                problems.push(format!(
                    "{role} relation `{}` column `{}` has type `{other}`; argus exchanges \
                     only `symbol` and `number` columns",
                    rel.raw_name(),
                    attribute.name()
                ));
                return None;
            }
        }
    }
    Some(Io {
        name: rel.raw_name().to_string(),
        ident: rel.name().to_string(),
        file,
        columns,
    })
}

/// Every relation of the program after component inlining, with its
/// columns' names and types: what a debugging probe may name.
fn relations(program: &Program) -> Vec<Value> {
    program
        .relations()
        .iter()
        .map(|rel| {
            let columns: Vec<Value> = rel
                .attributes()
                .iter()
                .zip(rel.data_type())
                .map(|(attribute, data_type)| json!({"name": attribute.name(), "type": data_type.to_string()}))
                .collect();
            json!({"name": rel.raw_name(), "columns": columns})
        })
        .collect()
}

fn manifest(inputs: &[Io], outputs: &[Io]) -> Value {
    let describe = |io: &Io| {
        json!({
            "name": io.name,
            "file": io.file,
            "columns": io.columns.iter().map(|c| c.name()).collect::<Vec<_>>(),
        })
    };
    json!({
        "ok": true,
        "inputs": inputs.iter().map(describe).collect::<Vec<_>>(),
        "outputs": outputs.iter().map(describe).collect::<Vec<_>>(),
    })
}

fn inspect(program: &Path) -> Result<Value, Failure> {
    let (parsed, _sources) = parse(program)?;
    let (inputs, outputs) = interface(&parsed)?;
    // Planning catches what the front end does not (a rule FlowLog cannot
    // plan), so a program that inspects cleanly also generates.
    let _ = fs::remove_dir_all(plan(program)?);
    let mut value = manifest(&inputs, &outputs);
    value["relations"] = Value::Array(relations(&parsed));
    Ok(value)
}

/// FlowLog's whole library-mode pipeline, into a scratch directory: the
/// generated module, or the rendered diagnostic of the stage that failed.
fn plan(program: &Path) -> Result<PathBuf, Failure> {
    let out = scratch_dir()?;
    let mut sources = SourceMap::new();
    let built = flowlog_build::Builder::default()
        .string_intern(true)
        .compile_into(program, &out, &mut sources);
    match built {
        Ok(()) => Ok(out),
        Err(error) => {
            let _ = fs::remove_dir_all(&out);
            Err(Failure::Program(render(&error, &sources)))
        }
    }
}

fn scratch_dir() -> Result<PathBuf, Failure> {
    let dir = std::env::temp_dir().join(format!(
        "argus-flowlog-tool-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos())
    ));
    fs::create_dir_all(&dir)
        .map_err(|e| Failure::Program(format!("cannot create {}: {e}", dir.display())))?;
    Ok(dir)
}

fn generate(program: &Path, src_dir: &Path, digest: &str) -> Result<Value, Failure> {
    let (parsed, _sources) = parse(program)?;
    let (inputs, outputs) = interface(&parsed)?;
    let out = plan(program)?;
    let stem = program
        .file_stem()
        .and_then(|s| s.to_str())
        .ok_or_else(|| Failure::Program(format!("program path has no stem: {}", program.display())))?;
    let generated = out.join(format!("{stem}.rs"));
    let write = |name: &str, contents: &str| {
        fs::write(src_dir.join(name), contents).map_err(|e| {
            Failure::Program(format!("cannot write {}: {e}", src_dir.join(name).display()))
        })
    };
    let module = fs::read_to_string(&generated)
        .map_err(|e| Failure::Program(format!("cannot read {}: {e}", generated.display())))?;
    let _ = fs::remove_dir_all(&out);
    write("program.rs", &module)?;
    write("glue.rs", &glue(&inputs, &outputs, digest))?;
    Ok(manifest(&inputs, &outputs))
}

/// The typed half of the engine host: relation tables, staging by input
/// index, and draining a commit's deltas by output index. The host itself
/// (`main.rs`) is the same for every program.
fn glue(inputs: &[Io], outputs: &[Io], digest: &str) -> String {
    let mut s = String::new();
    let _ = writeln!(s, "// GENERATED by argus-flowlog-tool for one program; do not edit.\n");
    let _ = writeln!(s, "use crate::host::Changes;\nuse crate::host::Column;\nuse crate::host::Fields;");
    let _ = writeln!(s, "use crate::host::Relation;\nuse crate::program::IncrementalEngine;");
    let _ = writeln!(s, "use crate::program::IncrementalResults;\n");
    let _ = writeln!(s, "pub const DIGEST: &str = {digest:?};\n");
    let table = |s: &mut String, name: &str, ios: &[Io]| {
        let _ = writeln!(s, "pub const {name}: &[Relation] = &[");
        for io in ios {
            let columns: Vec<&str> = io.columns.iter().map(|c| c.variant()).collect();
            let _ = writeln!(
                s,
                "    Relation {{ name: {:?}, file: {:?}, columns: &[{}] }},",
                io.name,
                io.file,
                columns.join(", ")
            );
        }
        let _ = writeln!(s, "];\n");
    };
    table(&mut s, "INPUTS", inputs);
    table(&mut s, "OUTPUTS", outputs);

    let _ = writeln!(
        s,
        "/// Stages `lines` of input `index` as insertions or deletions. Every\n\
         /// line is decoded before any is staged, so a malformed one stages none.\n\
         pub fn stage(engine: &mut IncrementalEngine, index: usize, lines: &[&[u8]], insert: bool) -> Result<(), String> {{\n    \
         match index {{"
    );
    for (index, io) in inputs.iter().enumerate() {
        let fields: Vec<String> = io
            .columns
            .iter()
            .map(|c| match c {
                Column::Symbol => "f.symbol()?".to_string(),
                Column::Number => "f.number()?".to_string(),
            })
            .collect();
        let _ = writeln!(
            s,
            "        {index} => {{\n            \
             let mut items = Vec::with_capacity(lines.len());\n            \
             for line in lines {{\n                \
             let mut f = Fields::new(&INPUTS[{index}], line)?;\n                \
             let row = ({},);\n                \
             f.end()?;\n                \
             items.push(row);\n            \
             }}\n            \
             if insert {{ engine.insert_{ident}(items) }} else {{ engine.remove_{ident}(items) }}\n            \
             Ok(())\n        }}",
            fields.join(", "),
            ident = io.ident
        );
    }
    let _ = writeln!(
        s,
        "        _ => Err(format!(\"no input relation at index {{index}}\")),\n    }}\n}}\n"
    );

    let _ = writeln!(
        s,
        "/// Records a commit's output deltas by output index.\n\
         pub fn drain(results: IncrementalResults, changes: &mut Changes) {{"
    );
    for (index, io) in outputs.iter().enumerate() {
        let mut encode = String::new();
        for (position, column) in io.columns.iter().enumerate() {
            if position > 0 {
                encode.push_str("            line.push('\\t');\n");
            }
            match column {
                Column::Symbol => {
                    let _ = writeln!(encode, "            line.push_str(&row.{position});");
                }
                Column::Number => {
                    let _ = writeln!(
                        encode,
                        "            line.push_str(itoa::Buffer::new().format(row.{position}));"
                    );
                }
            }
        }
        let _ = writeln!(
            s,
            "    for (row, diff) in results.{ident} {{\n        \
             let mut line = String::new();\n{encode}        \
             changes.record({index}, line, diff);\n    }}",
            ident = io.ident
        );
    }
    let _ = writeln!(s, "}}");
    s
}
