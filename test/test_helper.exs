# The graph backend's blob store is the suite's, beside the beams it
# keeps facts of (`mix clean` takes it too), never the machine's: every
# graph run here, and in every peer (`Argus.Test.Peer`), keeps its facts
# and solves there.
System.put_env("ARGUS_CACHE_DIR", Path.join(Mix.Project.build_path(), "argus/store"))

# Answers to the same solve are shared across the run (`Argus.Test.Memo`),
# and facts and solves kept across runs in the blob store above.
Argus.Test.Memo.start()
Argus.Test.Memo.warm_programs()

ExUnit.after_suite(fn _result ->
  # The graph's store, as a driver run collects it: once a day.
  if Argus.Dirs.keep?(), do: Roux.Blob.maybe_gc(Argus.Graph.store())
end)

# A test of a store itself (`@tag :cache`) has nothing to test when
# ARGUS_NO_CACHE turns the stores off. The perturbation checks of what a
# key covers (`@tag :cache_verify`) take seconds each and only move with
# the schema, the stores or what a producer reads, so they run in CI and
# on request (`mix test --include cache_verify`), not on every edit. The
# graph's incremental≡batch gate (`@tag :parity`) solves every analysis a
# dozen times over: CI runs it, and so does a change to the graph
# (`mix test --include parity`). The built escript (`@tag :escript`) and
# the real rebar3 and gleam (`:rebar3`, `:gleam`) run in CI's escript job
# and on request: `mix test --include escript --include rebar3 --include
# gleam`.
exclude = if Argus.Dirs.keep?(), do: [:cache_verify], else: [:cache, :cache_verify]
ExUnit.start(exclude: [:parity, :escript, :rebar3, :gleam | exclude])
