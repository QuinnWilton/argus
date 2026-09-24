# Answers to the same solve are shared across the run (`Argus.Test.Memo`).
Argus.Test.Memo.start()

# A test of a store itself (`@tag :cache`) has nothing to test when
# ARGUS_NO_CACHE turns the stores off.
ExUnit.start(exclude: if(Argus.Cache.enabled?(), do: [], else: [:cache]))
