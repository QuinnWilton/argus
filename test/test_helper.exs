# Answers to the same solve are shared across the run, and kept across
# runs in the suite's store (`Argus.Test.Memo`), pruned when it ends.
Argus.Test.Memo.start()
ExUnit.after_suite(fn _result -> Argus.Test.Memo.prune() end)

# A test of a store itself (`@tag :cache`) has nothing to test when
# ARGUS_NO_CACHE turns the stores off.
ExUnit.start(exclude: if(Argus.Cache.enabled?(), do: [], else: [:cache]))
