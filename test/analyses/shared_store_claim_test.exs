defmodule Argus.Analyses.SharedStoreClaimTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.SharedStoreClaim, as: C

  @modules [
    C.Claim,
    C.Helpers,
    C.Atomic,
    C.WrongLock,
    C.DifferentKey,
    C.DifferentStore,
    C.Unused,
    C.Owner,
    C.Refresh,
    C.WrongNormalization,
    C.DifferentFields,
    C.RepeatedReader,
    C.ChangedSentinel,
    C.SentinelLookup,
    C.ReusedCallback
  ]

  setup_all do
    %{batch: Batch.solve(:races, [@modules])}
  end

  defp claims(ctx, module) do
    {:ok, results} = Batch.analyze(ctx.batch, List.wrap(module))
    results["shared_store_claim"]
  end

  test "concurrent callers can both receive a successful claim", ctx do
    assert [[_, func, _, _, _, _]] = claims(ctx, C.Claim)
    assert func =~ ":claim/2"
  end

  test "normalizing a key separately in the check and mark preserves its identity", ctx do
    assert [[_, func, _, _, _, _]] = claims(ctx, C.Helpers)
    assert func =~ ":verify/2"
  end

  test "isolation protects the actual cache and key, not an unrelated key", ctx do
    assert [] == claims(ctx, C.Atomic)
    assert [_ | _] = claims(ctx, C.WrongLock)
    assert [_ | _] = claims(ctx, C.ReusedCallback)
  end

  test "different stores or keys do not claim the same row", ctx do
    assert [] == claims(ctx, C.DifferentKey)
    assert [] == claims(ctx, C.DifferentStore)
    assert [] == claims(ctx, C.WrongNormalization)
    assert [] == claims(ctx, C.DifferentFields)
  end

  test "a second invocation of the same checker must protect the written key", ctx do
    assert [] == claims(ctx, C.RepeatedReader)
  end

  test "data returned on an error path does not transparently carry the absence sentinel", ctx do
    assert [] == claims(ctx, [C.ChangedSentinel, C.SentinelLookup])
  end

  test "refreshing an existing key does not promise a one-use claim", ctx do
    assert [] == claims(ctx, C.Refresh)
  end

  test "a duplicate fill whose verdict is unused has no witnessed harm", ctx do
    assert [] == claims(ctx, C.Unused)
  end

  test "one registered owner serializes the complete claim", ctx do
    assert [] == claims(ctx, C.Owner)
  end
end
