defmodule Argus.Exclusions.StructureTest do
  @moduledoc """
  Exclusions of the structure analysis that no evaluation program
  exercises (census 2026-09-26). The test pins what one negated atom
  keeps quiet, beside a twin the analysis does report. The census is
  docs/design/exclusions.md; the fixtures are in
  test/fixtures/exclusions/structure.ex.
  """
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Rows
  alias Excl.Structure, as: S

  @switchable [S.SwitchableSpec.Pipeline, S.SwitchableSpec.App]
  @typeless [S.TypelessSpec.Pipeline, S.TypelessSpec.App]

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against a
  # solve of its own).
  @batched [@switchable, @typeless]

  setup_all do
    %{batch: Batch.solve(:structure, @batched)}
  end

  defp registered_as_worker(%{batch: batch}, set) do
    unless Souffle.available?(), do: flunk("souffle not installed")
    {:ok, results} = Batch.analyze(batch, set)
    Rows.where(results, :structure, "own_spec_registered_as_worker", drop: [:via])
  end

  describe "a supervisor's own child_spec/1" do
    # structure.dl, own_spec_worker: !child_spec_type(child, "supervisor").
    test "a spec that says :supervisor where it starts the tree, beside a typeless :ignore",
         ctx do
      assert registered_as_worker(ctx, @switchable) == []

      assert registered_as_worker(ctx, @typeless) ==
               [["Excl.Structure.TypelessSpec.Pipeline", "Excl.Structure.TypelessSpec.App"]]
    end
  end
end
