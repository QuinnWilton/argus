defmodule Argus.Analyses.FailureResourceTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Failure
  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.Handles
  alias Argus.Test.Rows

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    Handles.Sendfile,
    Handles.Connect,
    Handles.Ports,
    Handles.Quiet,
    Handles.Adversarial
  ]

  setup_all do
    %{batch: Batch.solve(:failure, [@batched])}
  end

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  # `{function, api}`, the fixture prefix dropped.
  defp dropped(%{batch: batch}, module) do
    assert {:ok, results} = Batch.analyze(batch, [module])

    for [func, _site, api, _drop] <- Rows.where(results, :failure, "resource_dropped", []) do
      {String.replace(func, "Argus.Test.Fixtures.Handles.", ""), api}
    end
    |> Enum.sort()
  end

  describe "resource_dropped" do
    test "a file opened for sendfile and never closed (thousand_island before 45e7b51)", ctx do
      skip_without_souffle()

      assert dropped(ctx, Handles.Sendfile) == [
               {"Sendfile:ssl/4", ":file.open/2"},
               {"Sendfile:tcp/4", ":file.open/2"}
             ]
    end

    test "a socket left open when the step after the connect fails", ctx do
      skip_without_souffle()

      assert dropped(ctx, Handles.Connect) == [{"Connect:leaky/2", ":gen_tcp.connect/3"}]
    end

    test "a port commanded and dropped; one kept in the state is not", ctx do
      skip_without_souffle()

      assert dropped(ctx, Handles.Ports) == [{"Ports:fire_and_forget/1", ":erlang.open_port/2"}]
    end

    test "the nearest shapes to each quieting condition still lose the handle", ctx do
      skip_without_souffle()

      assert ctx |> dropped(Handles.Adversarial) |> Enum.map(&elem(&1, 0)) == [
               "Adversarial:badmatch_then_return/1",
               "Adversarial:compared/2",
               "Adversarial:early_error/2",
               "Adversarial:inspected/1",
               "Adversarial:logged/1",
               "Adversarial:ok_arm/1",
               "Adversarial:raise_before_open/2",
               "Adversarial:raise_or_return/1",
               "Adversarial:with_else/1"
             ]
    end

    test "a returned answer, a raising path and a send hand nothing to lose", ctx do
      skip_without_souffle()

      assert dropped(ctx, Handles.Quiet) == []
    end
  end

  describe "resource_dropped prose" do
    test "names the opening call in the detail, not the title, and where it is lost" do
      finding =
        Failure.finding(:resource_dropped, ["M:f/2", "M:f/2#4", ":file.open/2", "M:f/2#9"])

      assert finding.severity == :warning
      refute finding.title =~ "file.open"
      assert finding.detail =~ ":file.open/2"
      assert [%{label: "lost here, still open"}] = finding.related
    end
  end
end
