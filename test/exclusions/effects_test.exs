defmodule Argus.Exclusions.EffectsTest do
  @moduledoc """
  Exclusions of the effects analysis that no evaluation program
  exercises (census 2026-09-26). The test pins what one negated atom
  keeps quiet, beside a twin the analysis does report. The census is
  docs/design/exclusions.md; the fixtures are in
  test/fixtures/exclusions/effects.ex.
  """
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Rows
  alias Excl.Effects, as: E

  @captured_body [E.CapturedBody.Repo, E.CapturedBody.Ledger, E.CapturedBody.EndOfDay]
  @closure_body [E.ClosureBody.Repo, E.ClosureBody.EndOfDay]

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against a
  # solve of its own).
  @batched [@captured_body, @closure_body]

  setup_all do
    %{batch: Batch.solve(:effects, @batched)}
  end

  # {function, context, category, api} of each effect in a context.
  defp effects(%{batch: batch}, set) do
    unless Souffle.available?(), do: flunk("souffle not installed")
    {:ok, results} = Batch.analyze(batch, set)

    for [func, context, category, api] <-
          Rows.where(results, :effects, "effect_in_context", drop: [:scope, :via, :site, :opened]),
        do: {func |> String.split(":") |> List.last(), context, category, api}
  end

  describe "a transaction's body" do
    # effects.dl, transaction_body: !fun_handed(site, caller, _, _).
    test "a transaction handed a capture is not the body of the function's one closure", ctx do
      assert effects(ctx, @captured_body) == []

      assert effects(ctx, @closure_body) ==
               [{"run/1", "transaction", "network", ":httpc.request/1"}]
    end
  end
end
