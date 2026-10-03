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

# A test that solves (`@tag :souffle`, or its `@describetag` and
# `@moduletag`) needs the souffle binary on PATH. Without it those tests
# are excluded, said once here, and the rest of the suite still runs. A
# module or describe that mostly solves tags itself and opts the rest
# out (`souffle: false`), which is why the filter is `souffle: true`. CI
# installs souffle in every job that tests, so there a missing souffle is
# an error, never a silently smaller suite.
exclude =
  cond do
    Argus.Souffle.available?() ->
      exclude

    System.get_env("CI") ->
      raise "souffle is not on PATH: CI runs the :souffle tests"

    true ->
      IO.puts(:stderr, "souffle is not on PATH: the :souffle tests are excluded")
      [{:souffle, true} | exclude]
  end

# `ARGUS_TEST_TIMINGS=N` prints the N slowest tests as they ran beside the
# others (`Argus.Test.Timings`), as CI's log does: `mix test --slowest`
# measures another run, one test at a time with no timeout.
formatters =
  if System.get_env("ARGUS_TEST_TIMINGS"),
    do: [ExUnit.CLIFormatter, Argus.Test.Timings],
    else: [ExUnit.CLIFormatter]

ExUnit.start(exclude: [:parity, :escript, :rebar3, :gleam | exclude], formatters: formatters)
