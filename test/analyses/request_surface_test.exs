defmodule Argus.Analyses.RequestSurfaceTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Fixtures.RequestSurface

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp atom_rows(modules) do
    assert {:ok, results} = Argus.analyze(modules, :request_surface)
    Map.get(results, "remote_atom_exhaustion", [])
  end

  defp proximity_for(rows, func_fragment) do
    rows
    |> Enum.filter(fn [_id, func, _api, _entry, _kind, _prox] ->
      String.contains?(func, func_fragment)
    end)
    |> Enum.map(fn [_id, _func, _api, _entry, _kind, prox] -> prox end)
    |> Enum.uniq()
  end

  describe "entry points" do
    test "a behaviour callback is an entry point; a bare exported function is not" do
      skip_without_souffle()

      # The whole point of this analysis over atom_safety: `NotAnEntryPoint`
      # makes the identical unsafe call and must stay silent, because
      # nothing about it says an external party can reach it.
      rows = atom_rows([RequestSurface.DirectPlug, RequestSurface.NotAnEntryPoint])

      assert proximity_for(rows, "DirectPlug") != []
      assert proximity_for(rows, "NotAnEntryPoint") == []
    end

    test "a safe conversion in a callback is not flagged" do
      skip_without_souffle()

      rows = atom_rows([RequestSurface.SafeCallback])
      assert proximity_for(rows, "SafeCallback") == []
    end
  end

  describe "proximity" do
    # Proximity is the triage signal and the reason the report is readable,
    # so each tier gets pinned. Reachability is not taint: `transitive` says
    # a path exists, `direct` says the sink is handling the callback's own
    # arguments.

    test "a sink inside the callback is direct" do
      skip_without_souffle()

      rows = atom_rows([RequestSurface.DirectPlug])
      assert proximity_for(rows, "DirectPlug") == ["direct"]

      assert [[_id, _func, api, entry, "plug", "direct"]] = rows
      assert String.contains?(api, "binary_to_atom")
      assert String.contains?(entry, "call/2")
    end

    test "a sink one call away is adjacent" do
      skip_without_souffle()

      rows = atom_rows([RequestSurface.AdjacentLiveView])

      assert proximity_for(rows, "order_by") == ["adjacent"]
      assert Enum.all?(rows, fn [_, _, _, _, kind, _] -> kind == "live_view" end)
    end

    test "a sink further down the call graph is transitive" do
      skip_without_souffle()

      rows = atom_rows([RequestSurface.TransitiveWorker])

      assert proximity_for(rows, "level_two") == ["transitive"]
      assert Enum.all?(rows, fn [_, _, _, _, kind, _] -> kind == "oban_job" end)
    end

    test "direct and adjacent are distinguished within one run" do
      skip_without_souffle()

      # Guards the ordering of the three rules: a single analysis run has
      # to assign each site its own tier rather than collapsing them.
      rows = atom_rows([RequestSurface.DirectPlug, RequestSurface.AdjacentLiveView])

      assert proximity_for(rows, "DirectPlug") == ["direct"]
      assert proximity_for(rows, "order_by") == ["adjacent"]
    end
  end

  describe "severity" do
    test "tracks proximity rather than sink type" do
      # The calibration this analysis rests on: every hand-verified direct
      # finding was real, adjacent was mixed, and transitive never was.
      assert %{severity: :error} =
               Argus.Analyses.RequestSurface.finding(
                 :remote_atom_exhaustion,
                 ["i", "M:f/1", "String.to_atom/1", "E:call/2", "plug", "direct"]
               )

      assert %{severity: :warning} =
               Argus.Analyses.RequestSurface.finding(
                 :remote_atom_exhaustion,
                 ["i", "M:f/1", "String.to_atom/1", "E:call/2", "plug", "adjacent"]
               )

      assert %{severity: :info} =
               Argus.Analyses.RequestSurface.finding(
                 :remote_atom_exhaustion,
                 ["i", "M:f/1", "String.to_atom/1", "E:call/2", "plug", "transitive"]
               )
    end

    test "the message names the surface, so triage does not need the code" do
      finding =
        Argus.Analyses.RequestSurface.finding(
          :remote_unsafe_deserialization,
          ["i", "M:decode/1", ":erlang.binary_to_term/1", "W:handle_in/3", "channel", "direct"]
        )

      assert finding.severity == :error
      assert finding.title =~ "websocket"
      assert finding.detail =~ "M:decode/1"
      assert finding.detail =~ "W:handle_in/3"
    end
  end

  describe "sink_endpoint" do
    test "names the HTTP method and path rather than the callback" do
      mod = Argus.Analyses.RequestSurface

      f = mod.finding(:sink_endpoint, ["M:f/1#3", "get", "/public/x/:id", "W.Controller"])

      assert f.severity == :info
      assert f.title =~ "GET /public/x/:id"

      # Two things it must not be read as claiming. Pipelines are not in the
      # route literal, and reachability is not taint — every transitive path
      # examined while calibrating these analyses carried data from storage
      # or config rather than from the request.
      assert f.detail =~ "does NOT say whether the route is authenticated"
      assert f.detail =~ "Nor does it establish taint"
    end
  end
end
