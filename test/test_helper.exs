# The graph backend's blob store is the suite's, beside the beams it
# keeps facts of (`mix clean` takes it too), never the machine's: every
# graph run here, and in every peer (`Argus.Test.Peer`), keeps its facts
# and solves there.
System.put_env("ARGUS_CACHE_DIR", Path.join(Mix.Project.build_path(), "argus/store"))

# What earlier runs' tests left in their tmp_dirs, removed at once
# (`Argus.Test.Files.rm_tmp_dirs!/0`) rather than by ExUnit as each test
# starts, through the file server the run's tests share.
Argus.Test.Files.rm_tmp_dirs!()

# Answers to the same solve are shared across the run (`Argus.Test.Memo`),
# and facts and solves kept across runs in the blob store above.
Argus.Test.Memo.start()

# The graph's store, collected once a day as a driver run collects it,
# but after the results: whether a collection is due is decided here,
# and the stamp touched, so that no driver run inside the suite starts
# one in the middle of a test. A collection reads every trace and kept
# solve it keeps, and the suite writes hundreds of thousands a day, so
# it keeps those used within the day rather than a driver's week: one
# unused for a day was written by code this checkout no longer has, and
# costs every collection after it a read. It says it is collecting and
# what it took, so the wait for it is never silent.
if Argus.Dirs.keep?() do
  store = Argus.Graph.store()
  stamp = Path.join(store.root, "gc.stamp")
  day = 24 * 60 * 60

  due? =
    case File.stat(stamp, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime < System.os_time(:second) - day
      {:error, _} -> true
    end

  if due? do
    File.mkdir_p!(store.root)
    File.touch!(stamp)

    ExUnit.after_suite(fn _result ->
      IO.puts(:stderr, "\nCollecting the suite's store (#{store.root}), once a day...")
      {micros, stats} = :timer.tc(fn -> Roux.Blob.gc(store, keep: day) end)

      IO.puts(
        :stderr,
        "Collected it in #{div(micros, 1_000_000)}s: removed #{stats.removed} entries " <>
          "(#{div(stats.bytes, 1_000_000)} MB), kept #{stats.kept}."
      )
    end)
  end
end

# A test of a store itself (`@tag :cache`) has nothing to test when
# ARGUS_NO_CACHE turns the stores off. The identity checks of what a key
# covers (`@tag :identity_verify`, under test/argus/graph/identity: the
# schema perturbations, the producers' closures, a module's rows
# extracted apart and together) take seconds each and only move with the
# schema, the keys or what a producer reads, so they run in CI and on
# request (`mix test --include identity_verify`), not on every edit. The
# graph's incremental≡batch gate (`@tag :parity`) solves every analysis a
# dozen times over: CI runs it, and so does a change to the graph
# (`mix test --include parity`). The closed-issue corpus (`@tag :corpus`)
# clones and compiles some 160 trees of real projects, and analyzes them
# even warm for minutes: CI runs it nightly, and so does a rule change
# (`mix test --only corpus`, narrowed by `ARGUS_CORPUS_ONLY`). The built escript (`@tag :escript`) and
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
# The toolchain is built here, before any test runs: its first build
# takes minutes, far past a test's timeout. Programs then run in the
# generic engine (`Argus.FlowLog.engine/2`), which needs no build, unless
# their compiled engine is installed already (`mix argus.flowlog build`
# installs argus's own). A test of compiled engines builds them itself.
exclude =
  cond do
    Argus.FlowLog.available?() ->
      case Argus.FlowLog.toolchain(progress: &IO.puts(:stderr, &1)) do
        {:ok, _toolchain} ->
          exclude

        {:error, reason} ->
          raise "building the FlowLog toolchain failed: " <> Argus.FlowLog.describe_error(reason)
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

# A test's own program (some forty across the suite) solves a handful of
# rows, so its engine is built unoptimized, about three times faster
# (`Argus.FlowLog.Program.profile/1`); argus's own programs are built as
# they ship. `ARGUS_FLOWLOG_BUILD_PROFILE=release` builds them all
# optimized.
if System.get_env("ARGUS_FLOWLOG_BUILD_PROFILE", "") == "",
  do: System.put_env("ARGUS_FLOWLOG_BUILD_PROFILE", "quick")

# A test's own program builds its engine on first use. Builds asked for
# while another runs are built together after it (`Argus.FlowLog.Builder`),
# but on a cold cache a test may still wait out others' builds before its
# own, minutes past ExUnit's minute. Built once, an engine is kept for as
# long as its program does not change, and a warm run builds nothing.
timeout = if Argus.FlowLog.available?(), do: 1_200_000, else: 60_000

ExUnit.start(
  exclude: [:parity, :corpus, :escript, :rebar3, :gleam | exclude],
  formatters: formatters,
  timeout: timeout
)
