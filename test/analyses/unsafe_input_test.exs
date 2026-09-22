defmodule Argus.Analyses.UnsafeInputTest do
  use ExUnit.Case

  alias Argus.Analyses.UnsafeInput
  alias Argus.Souffle
  alias Argus.Test.Fixtures.RequestSurface
  alias Argus.Test.Fixtures.UnboundedChildren, as: U

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :unsafe_input)
    results
  end

  defp local(results, sink),
    do: for([_id, func, api, ^sink] <- results["sink_without_request_path"], do: {func, api})

  describe "sinks no request reaches" do
    test "flags dynamic atom creation reachable from an export, not to_existing_atom" do
      skip_without_souffle()
      rows = local(analyze([Argus.Test.Fixtures.UnsafeAtomCreation]), "atom")
      funcs = Enum.map(rows, &elem(&1, 0))
      apis = Enum.map(rows, &elem(&1, 1))
      # String.to_atom/1 compiles down to the :erlang.binary_to_atom BIF.
      assert Enum.any?(funcs, &String.contains?(&1, "to_atom_from_input"))
      assert Enum.any?(apis, &String.contains?(&1, "binary_to_atom"))
      assert Enum.any?(apis, &String.contains?(&1, "list_to_atom"))
      refute Enum.any?(apis, &String.contains?(&1, "existing"))
    end

    test "[:safe] downgrades a deserialization but does not clear it" do
      skip_without_souffle()
      rows = local(analyze([Argus.Test.Fixtures.UnsafeDeserialization]), "deserialization")
      funcs = Enum.map(rows, &elem(&1, 0))
      assert Enum.any?(funcs, &String.contains?(&1, "decode_unsafe"))
      # Paginator CVE-2020-15150 is remote code execution THROUGH `[:safe]`.
      assert Enum.any?(funcs, &String.contains?(&1, "decode_atoms_only"))
      refute Enum.any?(funcs, &String.contains?(&1, "decode_validated"))
    end

    test "flags eval and shell-out APIs, not a fully-literal System.cmd" do
      skip_without_souffle()

      funcs =
        analyze([Argus.Test.Fixtures.CodeExecution]) |> local("code") |> Enum.map(&elem(&1, 0))

      assert Enum.any?(funcs, &String.contains?(&1, "eval"))
      assert Enum.any?(funcs, &String.contains?(&1, "os_cmd"))
      assert Enum.any?(funcs, &String.contains?(&1, "system_cmd"))
      refute Enum.any?(funcs, &String.contains?(&1, "static_system_cmd"))
    end

    test "a module using only safe APIs produces no findings" do
      skip_without_souffle()
      results = analyze([Argus.Test.Fixtures.SafeModule])
      assert results["sink_without_request_path"] == []
      assert results["sink_reachable"] == []
    end
  end

  defp atom_rows(modules) do
    for [id, func, api, "atom", entry, kind, prox] <- analyze(modules)["sink_reachable"],
        do: [id, func, api, entry, kind, prox]
  end

  defp proximity_for(rows, func_fragment) do
    for [_id, func, _api, _entry, _kind, prox] <- rows,
        String.contains?(func, func_fragment),
        uniq: true,
        do: prox
  end

  describe "request surfaces" do
    test "a behaviour callback is an entry point; a bare exported function is not" do
      skip_without_souffle()
      results = analyze([RequestSurface.DirectPlug, RequestSurface.NotAnEntryPoint])

      rows =
        for [id, func, api, "atom", entry, kind, prox] <- results["sink_reachable"],
            do: [id, func, api, entry, kind, prox]

      assert proximity_for(rows, "DirectPlug") != []
      assert proximity_for(rows, "NotAnEntryPoint") == []
      # The identical unsafe call with no request path is reported once, as live code.
      assert [{func, _}] =
               local(results, "atom")
               |> Enum.filter(&String.contains?(elem(&1, 0), "NotAnEntryPoint"))

      assert func =~ "NotAnEntryPoint"
    end

    test "a sink reachable from a request is not also reported as export-reachable" do
      skip_without_souffle()
      results = analyze([RequestSurface.DirectPlug])
      assert results["sink_reachable"] != []
      assert results["sink_without_request_path"] == []
    end

    test "a safe conversion in a callback is not flagged" do
      skip_without_souffle()
      assert proximity_for(atom_rows([RequestSurface.SafeCallback]), "SafeCallback") == []
    end

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
      rows = atom_rows([RequestSurface.DirectPlug, RequestSurface.AdjacentLiveView])
      assert proximity_for(rows, "DirectPlug") == ["direct"]
      assert proximity_for(rows, "order_by") == ["adjacent"]
    end
  end

  describe "severity" do
    test "tracks proximity rather than sink type" do
      row = fn prox -> ["i", "M:f/1", "String.to_atom/1", "atom", "E:call/2", "plug", prox] end
      assert %{severity: :error} = UnsafeInput.finding(:sink_reachable, row.("direct"))
      assert %{severity: :warning} = UnsafeInput.finding(:sink_reachable, row.("adjacent"))
      assert %{severity: :info} = UnsafeInput.finding(:sink_reachable, row.("transitive"))
    end

    test "the message names the surface, so triage does not need the code" do
      finding =
        UnsafeInput.finding(
          :sink_reachable,
          [
            "i",
            "M:decode/1",
            ":erlang.binary_to_term/1",
            "deserialization",
            "W:handle_in/3",
            "channel",
            "direct"
          ]
        )

      assert finding.severity == :error
      assert finding.title =~ "websocket"
      assert finding.detail =~ "M:decode/1"
      assert finding.detail =~ "W:handle_in/3"
    end

    test "a sink no request reaches keeps its own severity" do
      assert %{severity: :warning} =
               UnsafeInput.finding(:sink_without_request_path, ["i", "M:f/1", "a", "atom"])

      assert %{severity: :error} =
               UnsafeInput.finding(:sink_without_request_path, [
                 "i",
                 "M:f/1",
                 "a",
                 "deserialization"
               ])

      assert %{severity: :error} =
               UnsafeInput.finding(:sink_without_request_path, ["i", "M:f/1", "a", "code"])
    end
  end

  describe "sink_endpoint" do
    test "names the HTTP method and path rather than the callback" do
      f = UnsafeInput.finding(:sink_endpoint, ["M:f/1#3", "get", "/public/x/:id", "W.Controller"])
      assert f.severity == :info
      assert f.title =~ "GET /public/x/:id"
      assert f.detail =~ "does NOT say whether the route is authenticated"
      assert f.detail =~ "Nor does it establish taint"
    end
  end

  describe "unbounded children" do
    @all [U.Worker, U.UncappedSup, U.CappedSup, U.PublicLive, U.CappedLive, U.Internal]

    defp callers do
      analyze(@all)["unbounded_children_from_request"]
      |> Enum.map(fn [_s, _c, via, _k] -> via end)
      |> Enum.sort()
    end

    defp named?(list, f), do: Enum.any?(list, &String.contains?(&1, f))

    test "an uncapped supervisor driven by a request is reported; a ceiling discharges it" do
      skip_without_souffle()
      callers = callers()
      assert named?(callers, "PublicLive")
      refute named?(callers, "CappedLive"), "max_children is the whole fix"
      refute named?(callers, "Internal")
    end

    test "the finding names the entry surface it came from" do
      skip_without_souffle()

      assert [[sup, child, _via, kind]] =
               Enum.filter(analyze(@all)["unbounded_children_from_request"], fn [_s, _c, v, _k] ->
                 v =~ "PublicLive"
               end)

      assert sup =~ "UncappedSup"
      assert child =~ "Worker"
      assert kind == "live_view"
    end
  end
end
