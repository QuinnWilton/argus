defmodule Argus.Analyses.EtsStartTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.EtsStart, as: F

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against a
  # solve of its own).
  @batched [
    [F.InStart],
    [F.InHelper],
    [F.InSupervisorStart],
    [F.InInit],
    [F.AsksFirst],
    [F.Rescues],
    [F.HelperRescues],
    [F.RescuesElsewhere],
    [F.GivesAway],
    [F.Unnamed],
    [F.Temporary],
    [F.NotAServer]
  ]

  setup_all do
    %{batch: Batch.solve(:ets, @batched)}
  end

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  # {table, module, start} for each row of the set.
  defp created(%{batch: batch}, modules) do
    {:ok, results} = Batch.analyze(batch, modules)

    rows =
      for [name, mod, _site, start] <- results["ets_created_in_start"],
          do: {name, short(mod), start |> String.split(":") |> List.last()}

    Enum.sort(rows)
  end

  defp short(module), do: module |> String.split(".") |> List.last()

  describe "a named table a server's start_link creates" do
    test "in start_link itself (ex_uid2's Dsp)", ctx do
      skip_without_souffle()
      assert created(ctx, [F.InStart]) == [{":in_start_keys", "InStart", "start_link/1"}]
    end

    test "through a helper start_link calls", ctx do
      skip_without_souffle()
      assert created(ctx, [F.InHelper]) == [{":in_helper_cache", "InHelper", "start_link/1"}]
    end

    test "in a supervisor's own start_link", ctx do
      skip_without_souffle()

      assert created(ctx, [F.InSupervisorStart]) ==
               [{":in_supervisor_start", "InSupervisorStart", "start_link/1"}]
    end

    test "through a helper, with a rescue around other code in start_link", ctx do
      skip_without_souffle()

      assert created(ctx, [F.RescuesElsewhere]) ==
               [{":rescues_elsewhere_cache", "RescuesElsewhere", "start_link/1"}]
    end
  end

  describe "quiet" do
    test "made in init/1, in the server's process", ctx do
      skip_without_souffle()
      assert created(ctx, [F.InInit]) == []
    end

    test "made only when :ets.whereis/1 does not find it", ctx do
      skip_without_souffle()
      assert created(ctx, [F.AsksFirst]) == []
    end

    test "made under a rescue of the ArgumentError", ctx do
      skip_without_souffle()
      assert created(ctx, [F.Rescues]) == []
    end

    test "made in a helper whose call a rescue of the ArgumentError covers", ctx do
      skip_without_souffle()
      assert created(ctx, [F.HelperRescues]) == []
    end

    test "given away to the server it starts", ctx do
      skip_without_souffle()
      assert created(ctx, [F.GivesAway]) == []
    end

    test "an unnamed table", ctx do
      skip_without_souffle()
      assert created(ctx, [F.Unnamed]) == []
    end

    test "a temporary child, never restarted", ctx do
      skip_without_souffle()
      assert created(ctx, [F.Temporary]) == []
    end

    test "a plain module's start_link, which starts no server", ctx do
      skip_without_souffle()
      assert created(ctx, [F.NotAServer]) == []
    end
  end
end
