# Changelog

Notable changes and upgrade notes for Argus. Entries describe the release in
which a change appeared; older names and APIs may have changed since then.

## Unreleased

### Changed

- Argus solves its rules with [FlowLog](https://github.com/flowlog-rs/flowlog)
  instead of Soufflé, on Differential Dataflow. A program runs in the generic
  engine, which plans it as it starts and needs no build, or in an engine
  compiled for it, a native executable cached under `~/.cache/argus/flowlog`
  (`ARGUS_FLOWLOG_DIR`) once built (`ARGUS_FLOWLOG_ENGINE` chooses). The
  query graph keeps an engine running between solves, for as long as its
  database is open, and sends it only the rows that changed, so a rerun
  after a small edit in the same VM (an editor's session, `iex -S mix`) costs
  in proportion to the edit. Building the toolchain, or an engine, needs Rust
  1.88 or newer (`cargo` on `PATH`, in `~/.cargo/bin`, or named by
  `ARGUS_CARGO`); a release's prebuilt bundle carries the toolchain and
  argus's own engines. Soufflé is no longer used.
- Rename the `souffle:` configuration key to `engine:`, the
  `:souffle_missing` notice to `:engine_unavailable`, and
  `Argus.Driver.Result.souffle_missing?/1` to `engine_unavailable?/1`. The old
  key is rejected with a message naming the new one.
- Remove the `:souffle_bin` and `:souffle_timeout` options; use `:timeout`
  and `:workers` (engine threads, `ARGUS_FLOWLOG_WORKERS`). A solve that
  runs out of time fails as `:flowlog_timeout`.
- Rename `Argus.Schema.souffle_decls/0` to `datalog_decls/0`. Input
  declarations end in `mutable`; a custom rules file's inputs must too.
- Custom rules use FlowLog's dialect: no ADTs, `inline` relations,
  subsumption, body aggregates or `.plan`. `.limitsize` stops a solve as a
  relation grows past its limit, and a program that declares one runs in the
  generic engine. The [rule guide](docs/design/rule-style.md#the-dialect)
  lists the differences.
- The points-to stage still stops its exact program at the row budget
  (`.limitsize`) and falls back to the bounded one. The stage chosen depends
  only on the facts.
- `.facts` files escape a byte that is not part of valid UTF-8 as `\xHH`
  (`Argus.Tsv`), because engines hold symbols as UTF-8 text. `Argus.Tsv.decode/1`
  restores the bytes.

### Added

- `mix argus.flowlog build`, `status`, `solve` and `clean`: build engines
  ahead of time, show the toolchain and what is built, run a program over a
  facts directory, and remove the toolchains this argus no longer uses.
- Releases ship prebuilt engines for macOS and Linux on arm64 and x86_64
  (`Argus.FlowLog.Prebuilt`): argus downloads its platform's bundle once,
  checks it against the SHA-256 the package names, and runs its own
  analyses without Rust. `ARGUS_FLOWLOG_PREBUILT=0` turns it off. `mix
  argus.flowlog bundle` and `prebuilt` make a release's bundles.
- Engines missing from the cache are built in one Cargo build that compiles
  them side by side (`ARGUS_FLOWLOG_BUILD_JOBS`), and so are the engines
  asked for while another build runs, whoever asks for them
  (`Argus.FlowLog.Builder`).
- The generic engine (`argus-flowlog-tool serve`) runs any program argus can
  host without compiling it: argus's own, an edited copy, or a rules file of
  your own, at once and without Rust where a release's bundle supplies the
  toolchain. On a 544-module project it gives the compiled engines' results
  on every built-in program, its first solve within 1 to 2.4 times theirs
  and a one-row edit as fast. It keeps each program's plan by digest, so it
  starts again in milliseconds. `ARGUS_FLOWLOG_ENGINE=compiled` (or
  `Argus.FlowLog.engine/2`'s `:engine`) builds an engine for every program
  instead; the generic engine has no averages,
  user-defined functions, or columns other than symbols, numbers, booleans
  and tuples of them, and a program using one is built.
- An engine keeps no copy of its inputs' files: a commit names the file each
  changed input was last committed from (`Argus.FlowLog.Engine.commit/6`
  takes `{path, previous}`), which the engine checks against a digest and
  diffs. A held input whose file the store has collected is loaded by a new
  engine. On Ash's dependencies each analysis's engine holds 8 to 24 per cent
  less.
- A run that ends with its session (a compile, `mix argus`, an escript,
  `Argus.Run`) stops each engine as its solve returns, rather than holding
  every one until the run ends (`Argus.FlowLog.Pool.keep/2`): on a
  544-module project its engines peak at 400 to 590 MB together instead of
  1.2 GB. A session kept open (an editor's) keeps them.
- `mix argus.flowlog solve PROGRAM FACTS_DIR --profile` (and
  `Argus.FlowLog.run/3`'s `:profile`) reports where a solve's memory and
  time went: the arrangements holding the most updates and the operators
  that ran the longest, each named by its relation or rule expression
  (`σ(call_edge by 0)`, `(σ(a by 1) ⋈ σ(b by 0))`). It reports a solve a
  `.limitsize` stopped too, as far as it got.
- Engines report their starts and commits as telemetry
  (`[:argus, :flowlog, :engine, :start]` and `:commit`, with durations).
- `ARGUS_FLOWLOG_BUILD_PROFILE=quick` builds the engine of a program argus
  does not ship (a rules file of your own) unoptimized: about three times
  faster to build, and about three and a half times slower to solve. argus's
  own programs are always built optimized. argus's test suite builds its
  tests' programs so.
- `mix argus.flowlog bench FACTS_DIR` measures each program over a facts
  directory in fresh engines: its time from scratch, its one-row edits' commits,
  the engine's peak memory and what it kept, and a digest of every output.
  `--save` keeps a run and `--against` compares with one, naming each output
  whose rows moved (`Argus.FlowLog.Bench`). `mix argus.flowlog facts OUT_DIR`
  extracts the facts it reads from a corpus checkout or from beams.
- `Argus.FlowLog.Engine.usage/1` reports the memory an engine holds now and has
  held at most: its footprint on macOS, its resident set elsewhere.
- `mix argus.corpus diff` lists every finding a change added or removed
  across the corpus's checkouts since their baselines, by title, with each
  checkout's function and line; `mix argus.corpus accept` takes the findings
  as they are as the new baseline. The first run of a checkout records its
  baseline, and the corpus test says in brief what moved after each run.
  `ARGUS_CORPUS_ONLY` narrows `fetch`, `tally`, `diff` and `accept` as it
  does the test.

### Other changes

- Add a Breeze terminal explorer with `mix argus.debug explore`: search relations,
  filter and page through rows, inspect column and producer descriptions, follow
  IDs and rule references to source, and browse retained successful solves.
  Save each new solve's metadata for accurate historical inspection. Breeze is
  an optional dependency for projects using Argus.
- Add `mix argus.debug` and `Argus.Debug` for retaining editable analysis bundles,
  inspecting relations by named columns, probing intermediate rules, resolving
  IDs to source, and rerunning solves. Add executable contributor walkthroughs.
- Separate CFG-derived extraction from pipeline lifecycle management and organize
  shutdown rules by defect family. Share named-column row selection between
  debugging and fixture assertions.
- Create empty fact files for declared custom extractor outputs, including when
  the extractor emits no rows.
- `shared_store_site_lift` derives only the sites and values a claim asks
  about. On large projects it had enumerated every pairing, which made the
  `races` analysis take minutes and gigabytes.

## 0.21.0 — 2026-10-06

### Added

- Detect unenforced cryptographic verification, compressed ETF allocation,
  runtime template evaluation, SQL injection, unescaped HTML, upload filename
  traversal, and non-atomic shared-store claims. Real EEF CNA advisory revisions
  join the corpus, with fixed revisions checked where the vulnerable path is removed.
- Follow actual same-module helper and callback returns when tracking input.
  Security facts retain exact value/field identities, guards and verification-result
  uses, so unrelated checks cannot suppress a finding.
- Extraction now uses the function query graph and reverse dependency tracking
  by default. Unchanged functions reuse their facts and prepared data; unrelated
  input edits skip validation. Packed traces reduce small-file storage overhead.
  Fact assembly merges only requested relations and deduplicates rows in one pass.
- Returning to a cached module version reuses the finished fact pack after
  checking its code, schema and specs, avoiding function validation and merging.
- Restored module queries check their completed trace before visiting function
  queries. Fact assembly caches a small pack descriptor instead of another copy
  of the rows, and name-specific extractors skip functions that cannot emit facts.
- Cold extraction shares the specs source context and discovers packed traces
  once per module. Handle, socket, TLS and process-registry extractors skip
  functions whose instructions cannot produce their facts.

### Changed

- Rename `Argus.Extractors.PidFlow` to `TermFlow`.
  General `pid_{arg,return,result,object,field,base,sets,load}` relations become
  `value_*`; process `pid_{call,message,register,send,signal,remote,probe}`
  relations become `process_*_source`. Update custom extractors and fact consumers;
  the old module and relation names are removed.

### Removed

- `Argus.Schema.version/0` and the schema version number. Nothing in argus
  read it; schema changes are recorded here instead.

### Fixed

- On Elixir 1.20, Ecto's generated `Repo.query/1,2` (the default-argument
  versions of `query/3`) were no longer recognized as generated: argus reported
  them as SQL injection and stopped checking the SQL their callers build, such
  as `MyRepo.query!("SELECT ... '#{name}'")`. A module's own default-argument
  functions also looked macro-generated. Both are fixed, on 1.19 and 1.20.
- "Async task never awaited" now follows each task itself, not the function that
  starts it (#10). Awaited tasks started in a comprehension or an `Enum`
  callback, such as `tasks = for a <- as, b <- bs, do: Task.async(...)` followed
  by `Task.await_many(tasks)`, are no longer reported; dropped ones are now
  caught, such as `_ = Enum.map(urls, fn url -> Task.async(...) end)`, or tasks
  started beside another task the function does await. A task handed somewhere
  argus cannot follow (a send, an unmodeled call, a public function's return) is
  not reported.
- A task stored in a map under a literal key and read back with a dynamic one,
  such as `Map.get(jobs, key)` after `Map.put(jobs, :a, Task.async(...))`, is no
  longer reported as never awaited. argus cannot tell which value such a read
  returns, so it treats the task as handed somewhere it cannot follow.
- An `async_nolink` task's reply and `:DOWN` are reported as unhandled only when
  that task is not collected: collecting it in a helper, or after `Enum.map`, no
  longer triggers "No handle_info/2 clause", and collecting a different task no
  longer hides it. `Task.Supervisor.async/3` and `async_nolink/3` are now
  recognized.
- Deadlock and startup checks treat a function as waiting on exactly the tasks
  it awaits, wherever they were started: `init/1` awaiting tasks a comprehension
  started now waits on their work, and awaiting one task no longer counts as
  waiting on another.
- "Task.async in library code" is noted only when the program collects that
  task, not any task.
- Monitors taken in an `Enum.map` callback, such as `refs = Enum.map(pids, fn
  pid -> Process.monitor(pid) end)`, and released by a later `Enum.each` that
  receives each ref's `:DOWN` (or demonitors it), are no longer reported as
  "Monitor left live". A wait that may give up (a receive with a timeout), or a
  call that may stop early (`Enum.find/2`), still is.
- A socket handed to another process by a helper (`defp give(sock, pid), do:
  :gen_tcp.controlling_process(sock, pid)`), from around a closure, or through a
  captured `&:gen_tcp.controlling_process/2`, now counts as handed off: its
  close messages are no longer reported as unhandled. Ports handed off with
  `port_connect` likewise.
- Start results thrown away are reported as "Start result ignored" (and a capped
  `Task.Supervisor.start_child` as unchecked) wherever they are discarded: in an
  `Enum.each` or `Enum.any?` callback, or in a list from `Enum.map`, a
  comprehension (any number of generators, or a filter) or a fold that the
  caller, or a helper's caller, drops, such as `_ = for a <- as, b <- bs, do:
  Agent.start_link(...)`. A list whose elements are matched, or that a public
  function returns, is the caller's to check.
- A monitor ref thrown away by any library call that ignores its callback's
  result, such as `Enum.filter(pids, fn pid -> Process.monitor(pid) end)`, is
  now reported as dropped, not only one thrown away by `Enum.each` or
  `:lists.foreach`.
- Processes spawned in an `Enum.map` callback and monitored afterwards, as in
  `Enum.each(pids, &Process.monitor/1)`, are no longer reported as "Unlinked
  process spawned".
- Count a `trap_exit` set by a function a `proc_lib` start runs when that
  function goes on to enter its own module's loop
  (`gen_server:enter_loop(?MODULE, ...)` or `gen_statem:enter_loop/4,5,6`):
  the process becomes that module's server, so its trap is the server's.
  Servers started this way (the pattern ranch documents for protocols) were
  reported as never trapping exits, and their `terminate/2` cleanup as skipped
  on shutdown.
- Accept `--color always` and `--color never` in the escript. Both crashed with
  "not an already existing atom", which broke `rebar3 argus` in a terminal,
  since the plugin passes `--color always` there.
- Preserve map/access defaults, send results and fields of dictionary-held
  containers in value provenance. Recognize compound literal map keys and
  reject cyclic positional list summaries. Intraprocedural value
  flow converges without a fixed iteration cutoff; explicit solver budgets
  fail visibly rather than returning incomplete facts.
- Recognize finite atom values passed through private helpers, recursive
  non-executable term validation, and context-specific HTML escaping. Unknown
  callers, incomplete validation, and unchecked alternatives remain reportable.
  A validated compiler copy no longer stands in for an unchecked sibling.
  Finite lists retain their bounds through reversal; custom protocol output is
  not assumed finite merely because its input is fixed.
  Character bounds survive recursive helpers and tuple returns, and numeric
  equality preserves the distinct values that can produce different atom names.
- Treat generated Ecto Repo query wrappers as SQL APIs and check statement
  construction at their callers, including default-argument calls. Bound query
  values do not count as statement construction. SQL joins retain caller-supplied
  separators independently of escaping in their mapping callbacks.
- Keep captured ETF decoders reportable when direct callers reject compression.
- Exclude known boolean schema policy flags from secret-exposure findings.
  Hash-named secrets retain a lower severity redaction warning without being
  described as reusable credentials.
- Exclude fully literal shell commands from unsafe-input findings. Deserialization
  warnings now state when custom recursive validators are unproven.
- Refresh cached specs when a transitive remote type changes, including recent
  equal-size BEAM replacements with the same modification timestamp.
- Recognize exception data returned as maps, closures or the exception class,
  avoiding false reports that a catch handler swallows the exception.
- Follow tuple values to actual returns when classifying callbacks. Overwritten
  tuples and call arguments no longer count as callback return values.
- Recognize `from` retained in the callback state or used after constructing a
  `:noreply` tuple, avoiding false reports of missing replies.
- Silence Souffle warnings during analysis and fix singleton-variable warnings
  in the shipped rules. A separate compile check keeps warnings visible in CI.
- Follow process starts through wrappers when checking monitor lifetimes.
  Monitoring a process the caller just started no longer looks like a repeated
  monitor leak. A wrapper must return the start's result on every path.
- Recognize task factories that return their task after doing other work, so
  `task = Task.async(fun); log(task); task` is not reported as an unawaited task.
- Distinguish gen_statem clauses by both event type and content. Separate
  `:internal` events no longer share state updates, and `:info` clauses handling
  `:DOWN` are recognized correctly.
- Tie a monitor's bookkeeping to the fields, ETS writes, or returned values
  that actually keep its ref or pid. Resetting an unrelated counter or buffer
  no longer looks like dropping the monitor's record.
- For monitors created only when a lookup fails, check whether the store used
  by that lookup loses the entry. Removing a separate record no longer implies
  that the next lookup will create another monitor.
- Detect monitor leaks when a state reset discards the only retained reference.
  Resetting one field remains safe when another still holds the ref.
- Keep unread options unknown instead of treating them as absent defaults.
  This applies to child restart/type settings, DynamicSupervisor limits,
  exit trapping, ETS options, and GenServer registration. Child-spec options
  and overrides are resolved from the arguments supplied at each start.

### Schema changes

Custom Datalog consumers must account for:

- New TermFlow relations: `element_fun` (the program's fun a library call runs
  on each element), `task_op_source` (what a Task operation is handed) and
  `value_escape` (a value handed where value flow cannot follow it). TermFlow
  now follows every value through the standard library's collection calls
  (`Argus.Extractors.TermFlow.Library`), emitting `element` `value_arg`s,
  `value_result`s naming the fun a call runs, and objects for what calls answer.
  Enumerating a map yields `{key, value}` pairs (`pair <map>` in points-to), a
  map key that is not a literal is held under `@key`, and `**` reads any field.
- `element_fun`'s `answers` column says whether the library call keeps or drops
  what the fun answers.
- `result_lost` (ErrorHandling): a call to an ok/error API (or
  `Task.Supervisor.start_child`) whose result is never read, in place or
  wherever it is handed back (`Argus.Extractor.ResultFate`).
- The points-to stage stages `task_handled` (which Task operation is handed
  which task) and `task_escapes` (tasks whose handle goes where value flow
  stops), from `clientlib/task_handles.dl`.
- `answers_call` and the replacement of `monitor_started` with
  `monitor_answer`, which follows results through wrappers.
- `clause_event`, the `statem_insert.content` column, and gen_statem clause tags
  that include the event content.
- `child_spec_option`, `shorthand_arg`, `shorthand_option`, and explicit `own`
  or `dynamic` values in child specifications.
- `trap_flag_unread` for exit-trapping settings that cannot be resolved.
- `returned_field_from`, `returns_from`, and `monitor_kept`, replacing
  `monitor_clause`. The final `monitor_kept` column, `holds`, distinguishes
  retained refs from retained pids.
- `acquired_if_absent`, which links an acquisition to the store it checked.
- `call_arg_param` and `call_arg_runtime` for parameter and runtime-callback origins.
- `security_arg_*`, `security_value_*` and `security_result*` for exact argument
  identities, field provenance, safety/limit proofs and checked or discarded results.
- `etf_decode_site`, `etf_compression_rejected`, `code_template_site`, `code_call`,
  `code_arg_identity`, `code_site_gate`, `sql_input`, `sql_input_safe`,
  `html_output_site`, `html_input_escaped`, `upload_path_use`, and
  `upload_path_leaf_safe` for operation-specific security evidence.
- `shared_store_*` relations for store/key identities, conditional claims,
  locks and callback returns.
- `decoded_term_validated` for a recursive validation proof tied to the exact
  decode result, and `sql_call_input` / `sql_call_input_safe` for SQL construction
  at callers of generated query APIs. The unsafe-input analysis consumes these
  relations; compressed ETF allocation remains a separate check.

## 0.20.1 — 2026-09-29

### Changed

- Require Elixir `~> 1.19`, up from `~> 1.18`. OTP 28 remains required.
- Upgrade roux to `~> 0.2.3` for concurrent cache access and dependency-tracking
  fixes.

### Fixed

- Restore finding locations on OTP 29, whose disassembler returns resolved
  line locations. Correct function-boundary detection on OTP 29 and for the
  first function in each module on OTP 28.
- Read OTP 29 native-record instructions and Elixir 1.20's membership and
  `Process.send_after` calls correctly.
- Sort analysis results consistently across Souffle versions.
- Re-extract modules when cached blobs disappear, instead of repeatedly
  failing the run or losing finding locations.
- Skip corpus pairs whose pinned toolchain is missing or whose repository
  cannot be fetched, with the reason shown. Existing checkouts remain usable,
  and Git no longer waits for interactive credentials.

## 0.20.0 — 2026-09-27

### Upgrade notes

- **Package and application rename:** replace `{:panoptes, ...}` with
  `{:argus_beam, "~> 0.20"}` and application references or configuration for
  `:panoptes` with `:argus_beam`. Modules remain under `Argus`. Install the
  escript with `mix escript.install hex argus_beam`; its command, the Mix
  compiler, `mix argus`, and the `argus:` project setting keep their names.
- **One analysis backend:** Scry's incremental query graph is now part of
  Argus. `Argus.run_analyses/2`, `Argus.analyze/3`,
  `Argus.Analysis.extract_facts/3`, and `Argus.Findings.run/2` use it. The old
  batch options now raise `ArgumentError`:

  | Removed option | Replacement |
  |---|---|
  | `backend:` | There is one backend. |
  | `cache:` | `store:` for the blob store; `manifest:` to retain the graph between calls. |
  | `solve_cache:` | Solves are cached in the store automatically. |
  | `facts_dir:` | Use `Argus.Analysis.run_rules/3` to solve an existing extraction. |
  | `extractors:` | Remove the override; use `Argus.Pipeline.extract/2` for a custom extraction. |
  | `relations:` | The Datalog program determines its inputs. |

- `Argus.Souffle.run/3` also rejects `solve_cache:`, and
  `Argus.Souffle.input_relations/2` no longer accepts `programs:`.
- Removed the batch cache APIs (`Argus.Cache` and its submodules,
  `Argus.Souffle.Cache`), `Argus.Findings.Runner`, `Argus.BeamDigest`,
  `Argus.Symbols`, and interned facts (`Argus.Facts.intern/2`,
  `materialize/2`, `decode/2`). `Argus.Facts.decode/1` remains. Use
  `Roux.Code.beam_digest/2` for BEAM digests, `Argus.Graph.Code.closure/1` for
  code dependencies, and `Argus.Graph.Reads` for graph schema reads.
- Removed `Argus.Pipeline.Shards`, `run_shards/3`, `extract_shards/3`, and
  `Argus.Pipeline.Writer.digests/1`. Use `Argus.Pipeline.extract_module/2`
  for per-producer extraction. `Argus.Specs.interface_digest/2` replaces
  `environment_digest/1`.
- Removed the analysis aliases introduced in 0.17 and `mix argus.migrate`.
  Upgrade from 0.16 or earlier through 0.19, or use the name mapping below.
  A finding's `analysis` and `concern` now always match.
- Replace `mix argus.corpus prune` with `argus gc` or `mix argus gc`.
  Old `<checkout>/.argus-facts` stores are unused and can be removed.
- Cache roots must belong to the current user and must not be writable by
  other users. For an older cache rejected with `Roux.Blob.TrustError`, run
  `chmod go-w <root> <root>/FORMAT`, or remove it and let Argus recreate it.
- Fact schema advances to 154, with positional changes to facts and analysis
  outputs. Regenerate facts and update custom consumers against the schema
  declarations. Removed bytecode relations `move`, `allocate`, `deallocate`,
  `try_end`, and `module_attribute` must be read from disassembly instead.
  Fact fields now escape backslashes, tabs, newlines, and
  carriage returns; use `Argus.Tsv` when reading or writing them. Missing
  relation files raise `Argus.MissingRelationError` instead of meaning an
  empty relation. Relations used only by in-process passes are exported only
  when a selected custom program reads them.

### Added

- Incremental extraction, solving, and finding construction backed by roux.
  Unchanged inputs reuse cached results; extractor edits invalidate the affected
  producer. Standalone rule comments and blank lines do not invalidate solves.
  The store uses `ARGUS_CACHE_DIR`, then `$XDG_CACHE_HOME/argus/store`, then
  `~/.cache/argus/store`; `ARGUS_NO_CACHE` uses a temporary store.
- The `rebar3_argus` plugin is available on Hex.
- Process and ETS identity tracking through parameters, return values, state,
  closures, messages, registrations, and the process dictionary. A bounded
  fallback prevents large points-to analyses from exhausting their budget.
- A `races` concern for registry, ETS, and Mnesia check-then-act races, including
  lost updates, missing-row crashes, stale refills, uniqueness checks, and
  publishing an index before the referenced row exists. Findings identify the
  competing operation and the harm it can cause, including across helpers.
- Mailbox findings for messages a server or spawned process cannot handle,
  repeated timer loops and subscriptions, and message registrations during a
  LiveView's static render. Sources include timers, monitors, sockets, ports,
  node events, linked exits, task results, and late replies to timed receives.
- Findings for local-only BIFs applied to potentially remote pids, RPCs to
  unexported functions, and files, sockets, or ports dropped without closing.
- Findings for named ETS tables created in a server's `start_link`, socket
  calls without timeouts inside callbacks, synchronous calls to self, and
  Broadway producers that keep fetching while draining.
- Unsafe decompression checks and request entries for Phoenix controller
  actions, WebSock handlers, and ThousandIsland handlers. Input tracking now
  follows regex results, template assigns, helper returns, and more conversions.
- Optional priors for a value's source, whether a peer answers locally, and
  whether code is used only by tools or tests. Findings retain their structural
  evidence and label any heuristic severity adjustment.
- `Argus.Driver` and `Argus.Located` provide shared project execution and
  source locations for frontends. Findings and related frames carry `file`,
  `line`, and `end_line`.
- Corpus support for pinned OTP/Elixir versions, project subdirectories,
  umbrella apps, and Git submodules.

### Changed

- Coupling findings now identify state or registrations lost when a sibling
  restarts. Calls between siblings alone no longer imply restart coupling.
  ETS restart checks ask whether the reader outlives the owner; owner-lifetime
  uncertainty stays at `:info`.
- Monitor findings are unified as `mailbox.monitor_leak`, with evidence that
  repeated execution leaves a previous monitor live. `unconsumed_monitor` and
  `monitored_entry_removal` are removed. Timed-wait leaks are now warnings.
- Retire `mailbox.partial_handler`: a missing catch-all alone is no finding.
  `unhandled_info` reports concrete message sources, and `unhandled_timeout`
  reports gen_statem timeouts with no matching clause.
- Code execution reachable from a request is at least a warning; proven input
  flow remains an error. Recognized tooling and test-support code is graded
  one severity lower, subject to that floor.
- `reply_defect` kinds `self_call`/`self_cast` become
  `unhandled_call`/`unhandled_cast`. In
  `coupling.rest_for_one_orphaned_children`, `confidence` becomes `basis`,
  and its `named` value becomes `resolved`.
- Shared models distinguish process ownership, code that runs once or repeats,
  startup before acknowledgement, exit trapping at a call site, and named or
  unnamed ETS tables. Analyses use these definitions consistently.

### Fixed

- Supervision extraction handles more Erlang and Elixir child-spec forms,
  runtime list construction, helpers, overrides, and shorthand restart/type
  settings. OTP starts also identify callback behaviours when an attribute is
  absent.
- Startup and blocking checks distinguish local locks from cluster locks,
  finite retries from unbounded retries, and a caller's work from spawned work.
  Awaited tasks still contribute dependencies; acknowledged startup work does
  not hold the parent. Call cycles may contain more than two servers.
- Shutdown checks follow the supervisor's `:shutdown` reason through helpers,
  respect stop order, and require the relevant call to be protected by its
  exception handler. Cleanup of an owned ETS table that dies automatically is
  not reported as lost cleanup.
- Task and monitor checks account for the actual reply handler, release path,
  process, and ref. An unrelated handler or demonitor no longer suppresses a
  leak. Ignored Task.Supervisor starts matter only when a child limit may apply.
- gen_statem extraction follows event redispatch and helper transitions;
  self-loops no longer hide terminal or unreachable states. Only returned
  timeout actions count as armed.
- Unsafe-input checks respect finite allowlists while preserving findings for
  input that escapes them. Literal commands found on `PATH` stay safe, while
  dynamic shell or interpreter arguments remain code-execution sinks.
- Effects checks recognize `Repo.transact`, more network and broadcast APIs,
  and effectful BIFs. They associate each transaction with its own closure and
  report spawned work at the spawn, rather than duplicating its later effects.
- Secret classification distinguishes secret values from public keys and
  references to secrets. TLS checks use each connection's options instead of
  an unrelated `:verify_peer` elsewhere in the module.
- Findings and evidence point to the relevant call, clause, field, or module
  declaration. One malformed result row degrades that row without discarding
  the rest of its analysis.
- Extraction handles improper literals, register lifetimes, exception paths,
  and binary construction consistently. A failed extractor preserves the
  module's other facts and reports the failure. Facts are deterministic across
  VMs and do not invoke the analyzed code's `Inspect` implementations.
- Souffle processes stop when their caller dies or their deadline expires.
  Concurrent derivations no longer overwrite or remove one another's outputs.

## 0.19.0 — 2026-09-22

### Added

- Track request data into unsafe operations through `call_arg_derived` and
  `sink_arg_derived`. Proven flow is an error at any call depth; unproven paths
  retain their distance-based severity.
- Detect process API calls that differ from the program's prevailing result
  or exception handling (`failure.inconsistent_handling`).
- Detect registry and ETS check-then-act races. Atomic updates and handled
  `{:error, {:already_started, pid}}` outcomes avoid the corresponding finding.
- Optional model priors for secret fields, input sources, and process roles.
  `priors: :off` is the default; `:cached_only` is offline and deterministic,
  while `:live` requires `TYPESAFE_API_KEY`. `mix argus.priors` manages cached
  answers. Priors may add findings or adjust severity, never remove structural
  findings. Results gain `provenance` and `confidence` fields.

### Changed

- Fact schema advances to 42. `name_lookup` replaces `whereis_call`; new facts
  cover data flow, result handling, guarded creates/writes, and priors.
  `sink_reachable` gains `source` and `permille`; `sibling_dependency` gains
  `basis` and `permille`.

### Fixed

- Preserve dataflow through binary construction and matching.

## 0.18.1 — 2026-09-21

### Fixed

- Remove compiler warnings from interleaved callback clauses and misplaced
  function documentation.

## 0.18.0 — 2026-09-21

### Changed

- Consolidate output relations by defect, using columns to distinguish
  variants. Custom consumers must update to these relation names:

  | Concern | Previous relations | Replacement |
  |---|---|---|
  | `coupling` | `one_for_one_coupling`, `suspect_nonpermanent_dependency`, `cached_sibling_pid` | `sibling_dependency` |
  | `effects` | `purity_violated`, `effect_in_transaction` | `effect_in_context` |
  | `failure` | `swallowed_error`, `erpc_transport_unhandled`, `rpc_result_unhandled` | `unhandled_failure` |
  | `failure` | `unchecked_start_child`, `whereis_race` | `unchecked_result` |
  | `failure` | `unlinked_spawn`, `exit_in_callback` | `orphan_process` |
  | `shutdown` | `cleanup_never_runs`, `cleanup_unclear`, `terminate_may_be_truncated` | `cleanup_defect` |
  | `shutdown` | `trap_exit_without_handler`, `trap_exit_without_exit_clause` | `unhandled_exit_signal` |
  | `shutdown` | `terminate_calls_sibling`, `callback_stops_sibling` | `teardown_touches_sibling` |
  | `shutdown` | `deliberate_termination_while_monitored` | `kills_monitored_child` |
  | `mailbox` | `handle_info_without_catchall`, `handle_info_partial`, `nolink_messages_unhandled`, `statem_timeout_unhandled`, `state_missing_info_catchall` | `partial_handler` |
  | `mailbox` | `leaked_monitor`, `monitor_never_released`, `monitor_ref_discarded` | `unconsumed_monitor` |
  | `mailbox` | `leaked_async_task`, `yield_on_linked_task`, `linked_task_in_library` | `task_result_defect` |
  | `mailbox` | `unhandled_self_message`, `never_replies`, `call_never_replied` | `reply_defect` |
  | `blocking` | `timeout_chain_risk`, `blocking_cast_handler`, `timeout_insufficient` | `call_chain` |
  | `blocking` | `infinity_timeout_in_chain`, `rpc_without_timeout`, `rpc_in_genserver_callback`, `global_blocking_op` | `unbounded_wait` |
  | `blocking` | `blocking_receive_in_callback`, `receive_in_callback` | `receive_in_callback` |
  | `startup` | startup dependencies, ordering, supervisor calls, locks, and remote operations | `blocks_on_peer` |
  | `startup` | `blocking_recv_in_init`, `connect_in_init_without_backoff` | `unbounded_effect_in_init` |
  | `startup` | `init_timeout_deferral`, `continue_crash_loop_risk` | `deferral_defect` |
  | `startup` → `blocking` | `mutual_continue_deadlock` | `call_cycle`, with `phase = continue` |

- An init call to a later sibling produces one deadlock finding, with the
  supervision tree as evidence, instead of separate deadlock and order findings.
- Call-cycle edges, bottleneck callers, and sink endpoints become related
  evidence rather than standalone findings. Use `Argus.Findings.build/2` to
  attach them and `Argus.Analysis.finding_relations/1` to list finding outputs.
- Support per-variant deduplication keys and empty leading/trailing CSV columns.

## 0.17.2 — 2026-09-21

### Fixed

- Preserve Unicode and comments when `mix argus.migrate encore` rewrites pinned
  counts. Zero counts spanning multiple concerns now migrate to each concern.
  `--analyzer` limits which analyzer maps are changed.

## 0.17.1 — 2026-09-21

### Fixed

- Include `mix argus.migrate` and `Argus.Migrate`, omitted from the 0.17.0 tag.

## 0.17.0 — 2026-09-21

### Changed

- Group analyses by the defect they report. Old names remain aliases for two
  minor releases, and findings gain a `concern` field. The migration is:

  | Previous analysis | Concern |
  |---|---|
  | `atom_safety`, `request_surface`, `unbounded_dynamic_children` | `unsafe_input` |
  | `secret_exposure`, `tls_verification` | `exposure` |
  | `purity`, `transaction_safety` | `effects` |
  | `timeout_chain`, `call_cycle`, `process_bottleneck`, `callback_receive` | `blocking` |
  | `one_for_one_coupling` | `coupling` |
  | `sync_call_in_init`, `deferred_startup_deadlock` | `startup` |
  | `shutdown_safety` | `shutdown` |
  | `unlinked_spawn` | `failure` |
  | `message_contract`, `reply_contract` | `mailbox` |
  | `unsafe_task` | `failure` for ignored starts; `mailbox` for task lifetime/replies |
  | `monitor_leak` | `shutdown` for deliberate termination; `mailbox` for leaks |
  | `process_registry` | `structure` for duplicate names; `failure` for unchecked lookups |
  | `gen_statem` | `state_machine` for state structure; `mailbox` for replies/messages |
  | `supervision` | `coupling`, `structure`, `startup`, `shutdown` |
  | `distributed` | `blocking`, `structure`, `startup`, `failure` |
  | `error_handling` | `blocking`, `startup`, `shutdown`, `failure`, `mailbox` |

- Add named analysis sets: `:all`, `:default`, `:security`, `:effects`, `:otp`.
- Add `mix argus.migrate encore MANIFEST` to migrate pinned counts and identify
  counts that require review because their old analysis spans several concerns.

## 0.16.0 — 2026-09-21

### Changed

- Consolidate shared call-reachability, closure, receive, exception, effect,
  process, supervision, and startup definitions in the Datalog client library.
  Finding behavior is unchanged.

## 0.15.0 — 2026-09-16

### Changed

- Match timer cancellation to the timer's actual state field, including helper
  functions. A flush must accept that timer's message. Findings name the field
  and message, with separate verdicts for distinct timers.
- Schema 36 adds `timer_ref`, `timer_cancel`, `timer_store`, `returns_call`,
  `recv_pattern`, and `call_arg_field`; `timer_arm` gains `literal`.

## 0.14.1 — 2026-09-16

### Fixed

- Recognize blocking receives as timer flushes, including a receive used only
  when `cancel_timer` returns `false`.

## 0.14.0 — 2026-09-16

### Added

- Findings for unchecked RPC failure results, timer cancellation without a
  flush, unhandled `async_nolink` task messages, startup connects without a
  deferral path, callbacks stopping supervised siblings, and cached sibling
  pids under `one_for_one`.
- Schema 35 adds `rpc_result`, `callback_ref_head`, and `timer_arm`.

### Fixed

- Recognize gen_statem generic timeouts built at runtime or returned as a
  single action. Match their event type correctly and count them as a
  reconnect path.

## 0.13.2 — 2026-09-16

### Fixed

- Count a gen_statem timeout as armed only when the action reaches the
  callback's return.
- Require dual-restart-authority findings to monitor the child that was
  started, and resolve the correct argument of `:erlang.monitor/2`.
- Classify monotonic-time calls as time effects, avoiding cleanup warnings for
  terminate callbacks that only timestamp and log.

## 0.13.1 — 2026-09-16

### Fixed

- Read callback catch-alls across clause heads and shared tests without
  mistaking state patterns or body fallbacks for message coverage.
- Count Elixir's `send/2`, as well as Erlang's send instruction, as a source of
  self-messages.

## 0.13.0 — 2026-09-16

### Added

- A corpus of before/after bug-fix pairs, with `mix argus.corpus fetch|tally`
  and `mix argus.pins` for maintaining corpus inputs.

### Changed

- Schema 34 records catch tags per clause and exception class; `catch_tag`
  gains `class`, and unused `catch_handler` is removed.
- Missing-catch-all findings require an identifiable mailbox source. Catch-all
  detection asks whether every message is accepted, independent of state shape.
- Follow ETS table names through helper parameters and attribute work to the
  process whose callbacks run it.
- Startup checks include bare receives; foreign-child checks include
  Task.Supervisor. Calls protected by a matching `:noproc` catch stay quiet.
- Resolve dynamic process targets more conservatively from message tags.
  Cycle-edge and timeout-chain outputs gain an inference column (`tag` or
  `static`), and findings identify inferred edges.

### Fixed

- Preserve gen_statem caller/event aliases when revisiting control-flow blocks.

## 0.12.1 — 2026-09-16

### Fixed

- Attribute foreign children and ETS reads to the process running the code,
  including work in helper modules.
- Recognize gen_statem replies deferred by retaining `from` in a tuple or a
  saved event register.

## 0.12.0 — 2026-09-16

### Added

- Resolve dynamic process-call targets from unambiguous message tags, staged
  in `call_tag.facts`.
- Findings for partial message handlers, terminate callbacks calling siblings,
  foreign dynamic children, permanent ConsumerSupervisor children, competing
  restart authorities, and shared state initialized after children start.
- Findings for incomplete `:noproc` catches, unhandled erpc transport errors,
  ETS reads during owner restarts, unbounded socket/receive waits in init,
  gen_statem calls with no reply, and linked-task lifetime mistakes.
- Schemas 32–33 add unreplied gen_statem calls, child restart policies,
  post-start calls, `:DOWN` matching, and exception-handler facts.

### Changed

- Call-chain and message analyses read staged tags instead of positional
  bytecode relations, reducing unnecessary recomputation.

### Fixed

- Do not treat a dynamic call handled by another module as a self-message.

## 0.11.0 — 2026-09-16

### Upgrade notes

- The package and OTP application become `panoptes`; update dependencies and
  application references from `:argus` to `:panoptes`. The `Argus` namespace
  stays the same. This rename is superseded by `argus_beam` in 0.20.
- Remove `mix argus`, `scripts/analyze_project.exs`, and `Argus.Report`.
  At this release, Scry provides project integration and Argus provides the
  engine API. `mix argus.gen.dl` remains a maintainer task.

## 0.10.0 — 2026-09-16

### Added

- Interned fact storage through `Argus.Symbols`, a pluggable symbol store, and
  `format: :interned` in `Argus.Pipeline.extract/2`. `Argus.Facts.intern/2`,
  `materialize/2`, and `decode/2` convert between fact representations.

## 0.9.1 — 2026-09-16

### Fixed

- Report unchecked `Process.whereis/1` results rather than every lookup.
  Schema 31 adds the `whereis_call.checked` column.
- Treat literal commands with dynamic argv as safe from shell injection.
  Shells and interpreters with dynamic arguments remain sinks.

## 0.9.0 — 2026-09-12

### Changed

- Stream extracted facts per module instead of holding the whole program's
  facts in memory. Stage only relations used by the selected analyses.
- Replace full call-graph closures in built-in analyses with searches seeded
  by the operations each rule needs. `call_reachable` remains available to
  custom programs; `same_process_reaches` is removed.
- Limit concurrent Souffle solves to four by default; `:concurrency` overrides it.

### Fixed

- Remove `mix argus` work directories after a run.

## 0.8.1 — 2026-09-12

### Changed

- Fail before extraction when Souffle is missing and show installation guidance.

## 0.8.0 — 2026-09-12

### Changed

- Consolidate shared Datalog definitions, call-site indexing, and API extraction.
  Extractors declare their relations through `relations/0`.
- Schemas 29–30 move `tuple_literal` to layer 1 and standardize `rpc_call`
  timeouts: `-1` for infinity, `0` for unknown.
- Return only declared analysis outputs and clean up generated directories.
  `Argus.Findings.run/2` accepts an existing `:facts_dir`.

### Fixed

- Recognize Erlang application-owned ETS tables and resolve gen_statem state
  function IDs correctly. Do not treat unresolved via targets as modules.

### Removed

- Autoresearch tooling and batch harness scripts.
- `Argus.Origins`, `Argus.Resolution`, `Argus.Pipeline.read_facts/1`,
  `Argus.Facts.canonicalize/1`, the report `:facts` option, and
  `Argus.Schema.fetch!/1`, `arity/1`, `field_names/1`, `souffle_decl/1`.
- Souffle's `:fallback_rules` option and `_argus_mode` result key.
- The unused CFG client library and relations `module_info`, `import_ref`,
  `recv_end`, `make_fun`, `tuple_field_access`, `unhandled_op`,
  `deferred_reply`, `delayed_message`, `sync_call_via`, `via_tuple`,
  `registry_op`, and `gen_event_handler`.

## 0.7.3 — 2026-09-11

### Changed

- Lower the Elixir requirement to `~> 1.18`; OTP 28 remains required.

## 0.7.2 — 2026-09-11

### Changed

- Startup waits on a running server require an unbounded operation in its
  handler; starting a child alone no longer qualifies.
- Grade deliberate normal stops of permanent children as `:info`.
  Orphaned-child findings are warnings for resolved holders and informational
  when the holder is inferred.

## 0.7.1 — 2026-09-11

### Added

- Detect discarded monitor refs through schema 28's `monitor_ref_dropped` fact.

### Changed

- Follow monitor-lifetime helpers through closures and recognize bookkeeping
  removal outside callbacks.

## 0.7.0 — 2026-09-11

### Added

- Schema 27 records supervisor management calls, callback stop reasons and
  timeouts, gen_statem event clauses, and `handle_info` message coverage.
- Recognize calls/casts through gen_statem, GenStateMachine, and GenStage, and
  callback behaviours used by Connection and Postgrex wrappers.
- Findings for trapped exits without a handler, permanent children stopping
  normally, interruptible init timeouts, monitor lifetime mistakes, growing ETS
  tables, orphaned dynamic children, startup waits on supervisors, and
  unhandled gen_statem timeout events.

### Fixed

- Preserve child-spec order when literal and runtime elements are mixed,
  resolve default child modules from options, and form valid state-function IDs.

## 0.6.1 — 2026-09-11

### Changed

- Extract supervision trees outside Supervisor modules, follow child specs
  through helpers and comprehensions, and read runtime-built strategy options.
- Resolve callback modules in explicit start specs and reject unrelated tuples
  or behaviour modules mistaken for children.

## 0.6.0 — 2026-09-11

### Changed

- Schema 26 adds `conditional_call`; stage 0 adds `unconditional_call_edge`.
  Consumers projecting fact directories must supply the new stage output.
- `sync_call_in_init` gains `kind` (`conditional` or `unconditional`) and
  distinguishes optional blocking paths in its wording.

## 0.5.1 — 2026-09-11

### Changed

- Distinguish call and cast coupling. Cast-only dependencies are informational,
  and findings point to the coupling call.
- Startup calls with unknown ordering are informational; proven deadlocks
  remain errors. Modules with a `handle_info/2` are treated as task consumers.
- Omit embedded `file`/`line` metadata from literals to avoid invalidating
  semantic facts after source-only edits.

## 0.5.0 — 2026-09-11

### Added

- Structured findings through `Argus.run_analyses/2`, with source anchors,
  related locations, anchor labels, remediation help, and deterministic
  deduplication.
- Purity contracts through `Argus.Purity`, with verified, violated, and
  unprovable outcomes; callback-receive checks; and unsafe-operation checks
  rooted at request handlers.
- Generated Souffle declarations through `mix argus.gen.dl`, instruction-ID
  helpers, and line resolution through `Argus.Lines`.
- In-memory BEAM extraction, public `Argus.Pipeline.write_facts/2`, and
  `Argus.Analysis.run_rules/3` for consumers managing their own facts.
- Port extraction, broader DynamicSupervisor/via-name support, and
  post-dominators/control dependence in `Argus.Cfg`.
- Autoresearch commands for measuring and comparing corpus results.

### Changed

- Split positional data from stable facts: `function_entry` replaces the
  entry column of `function_def`; `supervisor_site` holds the tree location;
  `call_arg` loses its site and gains a separate `call_arg_forward` relation.
- Call and receive facts carry their enclosing function. Stage 0 materializes
  `call_edge` and `call_site`; built-in analyses no longer read `instruction`.
- Analysis outputs gain call-site and witness columns. Custom row consumers
  must update their positional readers, including the leading `id` in atom
  safety and `whereis_race` outputs.
- `line_info` resolves actual source lines for each instruction, including
  OTP 28 debug markers. `statem_state` gains `site`; `global_register` gains
  arity; `spawn_call` and other call facts carry more context.
- Extraction order and finding deduplication are deterministic.
- Use the workspace beam_spy dependency for its Line-chunk fixes.

### Fixed

- Do not verify purity through unknown protocol dispatch. Classify Path
  operations individually, honor local purity contracts, and resolve literal
  `apply` targets.
- Preserve dataflow through call arguments and results; handle improper lists
  and unknown values without crashing or emitting false literal identities.
- Avoid Souffle partial string conversions whose safety depended on evaluation
  order. Remove unused CFG materialization from ordinary solves.
- Recover supervisor children from runtime-built lists and keep same-module
  children with distinct registered names separate.
- Correct state discovery and initial-state extraction, avoid false synchronous
  chains through pure helpers, recognize propagated/re-raised exceptions, and
  require actual process interaction for startup ordering findings.
- Detect ignored start results and dependencies on temporary children. Do not
  report equal default timeouts as insufficient or global registration with a
  conflict resolver as lacking one.
- Give concurrent VMs separate temporary directories so runs cannot overwrite
  one another's facts.

### Removed

- Duplicate coupling/order findings, unused state-machine coverage output, and
  `Argus.Schema.Pin`. Schema versioning remains available to consumers.

## 0.4.0 — Unreleased

### Added

- Opt-in `coverage` analysis for unresolved extraction and missing detail:
  supervisors without children, servers or registered names without traffic,
  unused ETS tables, and state machines without transitions.
- `imprecision` facts and tracing helpers record where extractors fall back to
  unknown values. Tracing is disabled for ordinary analysis runs.

## 0.3.0 — Unreleased

### Added

- Deferred-startup checks for `handle_continue` cycles, later-sibling calls,
  parent-supervisor calls, and caught deadlocks that can become restart loops.
- gen_event calls, DynamicSupervisor children, PartitionSupervisor child specs,
  closure call edges, via names, delayed messages, and deferred replies.
- Better parameter, destructuring, and pure-BIF resolution. `:global` lock
  checks distinguish retrying operations from zero-retry attempts.

### Changed

- Include deferred-startup checks in the default correctness set.
- Remove the unused `process_monitor` relation.

## 0.2.0 — Unreleased

### Upgrade notes

- Rename `Argus.Extract`, `Argus.Normalize`, and `Argus.Emitter` to
  `Argus.Pipeline`, `Argus.Pipeline.Normalize`, and `Argus.Pipeline.Emit`.
- Remove the generic dataflow analyses (`cfg`, `callgraph`, `callgraph_ctx`,
  `reachability`, `reaching_def`, `liveness`, `dominators`, `loops`,
  `tail_call`, `constant_propagation`, `function_summary`, `message_flow`),
  plus `phoenix_security` and `resource_lifecycle`. Custom rules can still
  use the shared Datalog library.
- Inline `Argus.Souffle.CLI` into `Argus.Souffle` and remove DOT output.

### Fixed

- Discover dependencies through Mix's project paths and skip stale BEAMs for
  unloaded modules instead of crashing.

## 0.1.0

Initial research release with 28 analyses covering dataflow, BEAM/OTP defects,
and framework checks.
