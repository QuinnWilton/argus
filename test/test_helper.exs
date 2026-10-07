# The graph backend's blob store is the suite's, beside the beams it
# keeps facts of (`mix clean` takes it too), never the machine's: every
# graph run here, and in every peer (`Argus.Test.Peer`), keeps its facts
# and solves there.
System.put_env("ARGUS_CACHE_DIR", Path.join(Mix.Project.build_path(), "argus/store"))

# Answers to the same solve are shared across the run (`Argus.Test.Memo`),
# and facts and solves kept across runs in the blob store above.
Argus.Test.Memo.start()

ExUnit.after_suite(fn _result ->
  # The graph's store, as a driver run collects it: once a day.
  if Argus.Dirs.keep?(), do: Roux.Blob.maybe_gc(Argus.Graph.store())
end)

# A test of a store itself (`@tag :cache`) has nothing to test when
# ARGUS_NO_CACHE turns the stores off. The identity checks of what a key
# covers (`@tag :identity_verify`, under test/argus/graph/identity: the
# schema perturbations, the producers' closures, a module's rows
# extracted apart and together) take seconds each and only move with the
# schema, the keys or what a producer reads, so they run in CI and on
# request (`mix test --include identity_verify`), not on every edit. The
# graph's incremental≡batch gate (`@tag :parity`) solves every analysis a
# dozen times over: CI runs it, and so does a change to the graph
# (`mix test --include parity`). The built escript (`@tag :escript`) and
# the real rebar3 and gleam (`:rebar3`, `:gleam`) run in CI's escript job
# and on request: `mix test --include escript --include rebar3 --include
# gleam`.
exclude = if Argus.Dirs.keep?(), do: [:identity_verify], else: [:cache, :identity_verify]

# A test that solves (`@tag :flowlog`, or its `@describetag` and
# `@moduletag`) needs FlowLog engines, which argus builds with Rust
# (`Argus.FlowLog.Toolchain`). Without Rust those tests are excluded,
# said once here, and the rest of the suite still runs. A module or
# describe that mostly solves tags itself and opts the rest out
# (`flowlog: false`), which is why the filter is `flowlog: true`. CI
# installs Rust in every job that tests, so there a missing toolchain is
# an error, never a silently smaller suite.
#
# Every built-in program's engine is built here, before any test runs:
# a large program's engine takes minutes to compile, far past a test's
# timeout, and is built once per version of its rules (the build cache,
# `ARGUS_FLOWLOG_DIR`, outlives the suite). A test that compiles a
# program of its own or an edited copy of argus's builds its engine
# itself. `ARGUS_TEST_PREBUILD=0` skips the prebuild, for running a test
# file that builds only its own programs.
exclude =
  cond do
    Argus.FlowLog.available?() and System.get_env("ARGUS_TEST_PREBUILD") == "0" ->
      exclude

    Argus.FlowLog.available?() ->
      case Argus.FlowLog.prebuild(Argus.FlowLog.builtin_programs(),
             progress: &IO.puts(:stderr, &1)
           ) do
        :ok ->
          exclude

        {:error, reason} ->
          raise "building the FlowLog engines failed: " <> Argus.FlowLog.describe_error(reason)
      end

    System.get_env("CI") ->
      raise "the FlowLog toolchain is unavailable, and CI runs the :flowlog tests: " <>
              Argus.FlowLog.not_found_message()

    true ->
      IO.puts(
        :stderr,
        "no Rust toolchain: the :flowlog tests are excluded (#{Argus.FlowLog.not_found_message()})"
      )

      [{:flowlog, true} | exclude]
  end

# `ARGUS_TEST_TIMINGS=N` prints the N slowest tests as they ran beside the
# others (`Argus.Test.Timings`), as CI's log does: `mix test --slowest`
# measures another run, one test at a time with no timeout.
formatters =
  if System.get_env("ARGUS_TEST_TIMINGS"),
    do: [ExUnit.CLIFormatter, Argus.Test.Timings],
    else: [ExUnit.CLIFormatter]

# A test's own program (some forty across the suite) builds its engine
# on first use, and the builds take turns on the toolchain's one Cargo
# target: on a cold cache a test may wait out others' builds before its
# own, minutes past ExUnit's minute. Built once, an engine is kept for as
# long as its program does not change, and a warm run builds nothing.
timeout = if Argus.FlowLog.available?(), do: 1_200_000, else: 60_000

ExUnit.start(
  exclude: [:parity, :escript, :rebar3, :gleam | exclude],
  formatters: formatters,
  timeout: timeout
)
