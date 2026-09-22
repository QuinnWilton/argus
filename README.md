# Panoptes

[![CI](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml/badge.svg)](https://github.com/QuinnWilton/argus/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/panoptes.svg)](https://hex.pm/packages/panoptes)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/panoptes)

Whole-program BEAM analysis for subtle OTP and supervision bugs. The
package is `panoptes` — Argus Panoptes, the hundred-eyed watchman — and
its modules are `Argus.*`.

Argus disassembles compiled `.beam` files, extracts facts from the bytecode,
and evaluates [Souffle](https://souffle-lang.github.io/) Datalog rules to
detect BEAM/OTP-specific anti-patterns: supervision-tree coupling, GenServer
deadlocks, leaked tasks, ETS misuse, atom-table exhaustion, and more.

## Installation

```elixir
def deps do
  [
    {:panoptes, "~> 0.17"}
  ]
end
```

[Souffle](https://souffle-lang.github.io/install) must be installed and
available on your `PATH`.

To run the analyses over a project, use [scry](https://github.com/QuinnWilton/scry),
the Mix compiler built on this library: it runs them incrementally after
every compile and reports findings as compiler diagnostics. This package
is the engine — the extraction pipeline, the rules, and the in-VM API
below.

## Approach

Argus is inspired by [Doop](https://bitbucket.org/yanniss/doop/src/master/)
(JVM), [cclyzer++](https://github.com/GaloisInc/cclyzer-plusplus) (LLVM IR),
and [Gigahorse](https://github.com/nevillegrech/gigahorse-toolchain) (EVM),
but takes advantage of the BEAM's register-based instruction set to skip
the expensive IR-lifting step those frameworks need. BEAM instructions map
to Datalog facts directly, with no intermediate representation.

```
.beam → disassemble → facts (emitter + extractors) → stage 0 call graph → Souffle rules → findings
```

The emitter walks every instruction and records the generic facts —
instructions, registers, control flow, calls, literals. The extractors
read the same bytecode for what the analyses reason about: behaviours,
supervision trees, process calls, monitors, ETS, return shapes. A shared
call graph is derived once per run, and each analysis is one Souffle
program over the facts and a common rule library, producing findings with
a severity, a source anchor and a remediation hint.

## Analyses

Argus ships 13 analyses, one per concern (`mix scry --list` prints the
same table). An analysis answers "what goes wrong"; the mechanism, the
phase and the proximity to a request are columns on its relations, never
separate analyses, so a defect has one owner.

| Analysis | Concern |
|---|---|
| `startup` | work in `init/1` or `handle_continue/2` that blocks, deadlocks or races the tree's start |
| `shutdown` | cleanup a supervisor shutdown will skip, and teardown that hurts a peer |
| `blocking` | synchronous waits that can last forever or nest: call chains, cycles, fan-in, rpc, locks, receives in callbacks |
| `coupling` | two owners of one relationship across supervisor branches |
| `mailbox` | messages that arrive with no clause for them, and replies that never come |
| `failure` | error paths swallowed, half-caught or ignored |
| `structure` | child specs, registrations and tree shapes that are wrong on their own |
| `state_machine` | gen_statem states no transition reaches, and terminal states that never stop |
| `ets` | ETS table ownership, concurrency options, and lifecycle |
| `effects` | `@pure` contracts, and effects inside a transaction that a rollback cannot undo |
| `unsafe_input` | atom exhaustion, unsafe deserialization and code execution reachable from a request |
| `exposure` | secrets that `inspect/1` prints, and TLS that does not verify the peer |
| `coverage` | extractor coverage and imprecision (meta-analysis, opt-in) |

Named sets stand in for a list: `:all` (everything but `coverage`),
`:default` (what scry runs unconfigured), `:security`, `:effects` and
`:otp`. The names these replaced (`supervision`, `error_handling`,
`sync_call_in_init`, ...) keep working through `Argus.Analysis.aliases/0`
for two minor versions: a retired name runs the concern its findings
live in, reports the rows that were its under the old name, and sets
`concern` on every finding to the analysis it belongs to today.

## Programmatic API

```elixir
# Every analysis, one extraction: structured findings with severity,
# source anchors and remediation hints.
{:ok, %{findings: findings}} = Argus.run_analyses([MyApp.Supervisor, MyApp.WorkerA])

# One analysis, raw output relations.
{:ok, results} = Argus.analyze([MyApp.Supervisor, MyApp.WorkerA], :startup)

# Ad-hoc Datalog rules over the same facts.
{:ok, results} = Argus.analyze([MyApp.Worker], {:custom, "path/to/rules.dl"})
```

## License

MIT
