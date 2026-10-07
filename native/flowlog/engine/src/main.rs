//! An argus engine: one compiled FlowLog program's dataflow, kept alive
//! between solves and driven over a port (`host`, the protocol every
//! engine speaks).

mod glue;
mod host;
// The generated module has an insert method for each relation of inline
// facts too, which no engine calls.
#[allow(dead_code)]
mod program {
    include!("program.rs");
}

use mimalloc::MiMalloc;

#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

fn main() {
    host::main(std::env::args().skip(1), |workers, extra| match extra {
        [] => Ok(glue::Compiled::new(workers)),
        [(flag, _), ..] => Err(format!("a compiled engine takes no `{flag}`")),
    })
}
