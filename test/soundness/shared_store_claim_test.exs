defmodule Argus.Soundness.SharedStoreClaimTest do
  use ExUnit.Case, async: true
  @moduletag :souffle

  import Argus.Test.Soundness, only: [fired: 2]
  alias Argus.Test.Fixtures.SharedStoreClaim, as: C

  test "read-derived error details do not hide a successful one-use claim verdict" do
    assert {:warning, "Non-atomic claim of a shared-store key",
            {C.SuccessWithErrorDetails, :claim, 2}} in fired([C.SuccessWithErrorDetails], :races)
  end

  test "isolation captures the actual computed cache value and its key" do
    assert fired([C.AtomicComputedCache], :races) == []
  end
end
