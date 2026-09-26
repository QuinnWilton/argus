# Answers to the same solve are shared across the run, and kept across
# runs in the suite's store (`Argus.Test.Memo`), pruned when it ends.
Argus.Test.Memo.start()
Argus.Test.Memo.warm_programs()
ExUnit.after_suite(fn _result -> Argus.Test.Memo.prune() end)

# A test of a store itself (`@tag :cache`) has nothing to test when
# ARGUS_NO_CACHE turns the stores off. The perturbation checks of what a
# key covers (`@tag :cache_verify`) take seconds each and only move with
# the schema, the stores or what a producer reads, so they run in CI and
# on request (`mix test --include cache_verify`), not on every edit. The
# graph's incremental≡batch gate (`@tag :parity`) solves every analysis a
# dozen times over: CI runs it, and so does a change to the graph
# (`mix test --include parity`).
exclude = if Argus.Cache.enabled?(), do: [:cache_verify], else: [:cache, :cache_verify]
ExUnit.start(exclude: [:parity | exclude])
