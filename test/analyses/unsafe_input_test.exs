defmodule Argus.Analyses.UnsafeInputTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.UnsafeInput
  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.RequestSurface
  alias Argus.Test.Fixtures.Taint
  alias Argus.Test.Fixtures.UnboundedChildren, as: U
  alias Argus.Test.Memo

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    U.Worker,
    U.UncappedSup,
    U.CappedSup,
    U.PublicLive,
    U.CappedLive,
    U.Internal,
    U.TaskLive,
    U.StreamLive,
    Argus.Test.Fixtures.UnsafeAtomCreation,
    Argus.Test.Fixtures.UnsafeDeserialization,
    Argus.Test.Fixtures.CodeExecution,
    Argus.Test.Fixtures.SafeModule,
    RequestSurface.DirectPlug,
    RequestSurface.SafeCallback,
    Taint.StoreSourcedPlug,
    Taint.StoreSourcedAdjacent,
    Taint.StoreSourcedWorker,
    Taint.FlowLiveView,
    Taint.FlowTransitive,
    Taint.FlowClosureEnv,
    Taint.SocketOnly,
    Taint.SessionOnly,
    Taint.LiteralAtom,
    Taint.ExistingAtom,
    Taint.HofElement,
    Taint.GuardAllowlist,
    Taint.BodyAllowlist,
    Taint.SameLine,
    Taint.SameLineMixed,
    Argus.Test.Fixtures.AtomSources,
    Argus.Test.Fixtures.AtomFromMessages,
    Argus.Test.Fixtures.AtomProcessName,
    [Argus.Test.Fixtures.AtomCallerInput, Argus.Test.Fixtures.AtomCallerInput.NameServer]
  ]

  setup_all do
    %{batch: Batch.solve(:unsafe_input, [@batched])}
  end

  # A set that shares a module with another test's is about what the
  # modules do together: it is solved on its own (`:alone`), and the
  # batch holds only disjoint sets.
  defp solve(:alone, modules), do: Memo.analyze(modules, :unsafe_input)
  defp solve(%{batch: batch}, modules), do: Batch.analyze(batch, modules)

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(source, modules) do
    assert {:ok, results} = solve(source, modules)
    results
  end

  defp local(results, sink),
    do: for([_id, func, api, ^sink | _] <- results["sink_without_request_path"], do: {func, api})

  describe "sinks no request reaches" do
    test "flags dynamic atom creation reachable from an export, not to_existing_atom", ctx do
      skip_without_souffle()
      rows = local(analyze(ctx, [Argus.Test.Fixtures.UnsafeAtomCreation]), "atom")
      funcs = Enum.map(rows, &elem(&1, 0))
      apis = Enum.map(rows, &elem(&1, 1))
      # String.to_atom/1 compiles down to the :erlang.binary_to_atom BIF.
      assert Enum.any?(funcs, &String.contains?(&1, "to_atom_from_input"))
      assert Enum.any?(apis, &String.contains?(&1, "binary_to_atom"))
      assert Enum.any?(apis, &String.contains?(&1, "list_to_atom"))
      refute Enum.any?(apis, &String.contains?(&1, "existing"))
    end

    test "[:safe] downgrades a deserialization but does not clear it", ctx do
      skip_without_souffle()
      rows = local(analyze(ctx, [Argus.Test.Fixtures.UnsafeDeserialization]), "deserialization")
      funcs = Enum.map(rows, &elem(&1, 0))
      assert Enum.any?(funcs, &String.contains?(&1, "decode_unsafe"))
      # Paginator CVE-2020-15150 is remote code execution THROUGH `[:safe]`.
      assert Enum.any?(funcs, &String.contains?(&1, "decode_atoms_only"))
      refute Enum.any?(funcs, &String.contains?(&1, "decode_validated"))
    end

    test "the deserialization finding says what the options were, and grades [:safe] down", ctx do
      skip_without_souffle()

      by_func =
        analyze(ctx, [Argus.Test.Fixtures.UnsafeDeserialization])["sink_without_request_path"]
        |> Enum.filter(&(Enum.at(&1, 3) == "deserialization"))
        |> Map.new(fn [_id, func, _api, _sink, safety] = row ->
          {func |> String.split(":") |> List.last(),
           {safety, UnsafeInput.finding(:sink_without_request_path, row)}}
        end)

      assert {"unsafe", unsafe} = by_func["decode_unsafe/1"]
      assert unsafe.title == "binary_to_term without :safe"
      assert unsafe.severity == :error

      assert {"atoms_only", safe} = by_func["decode_atoms_only/1"]
      assert safe.title == "binary_to_term with [:safe] and no shape check"
      assert safe.severity == :warning
      assert safe.detail =~ "CVE-2020-15150"
      assert Enum.any?(safe.help, &(&1 =~ "non_executable_binary_to_term"))
    end

    test "a request-reachable deserialization carries the same class" do
      row = fn safety ->
        [
          "i",
          "M:decode/1",
          ":erlang.binary_to_term/2",
          "deserialization",
          "W:handle_in/3",
          "channel",
          "flow",
          "",
          "0",
          safety
        ]
      end

      safe = UnsafeInput.finding(:sink_reachable, row.("atoms_only"))
      assert safe.title =~ "with [:safe] and no shape check"
      assert safe.severity == :error
      assert safe.detail =~ "with [:safe] and nothing else"

      dynamic = UnsafeInput.finding(:sink_reachable, row.("dynamic"))
      assert dynamic.title =~ "options not known statically"

      unsafe =
        UnsafeInput.finding(:sink_without_request_path, [
          "i",
          "M:decode/1",
          ":erlang.binary_to_term/1",
          "deserialization",
          "dynamic"
        ])

      assert unsafe.title == "binary_to_term with options not known statically" and
               unsafe.severity == :error
    end

    test "flags eval and shell-out APIs, not a fully-literal System.cmd", ctx do
      skip_without_souffle()

      funcs =
        analyze(ctx, [Argus.Test.Fixtures.CodeExecution])
        |> local("code")
        |> Enum.map(&elem(&1, 0))

      assert Enum.any?(funcs, &String.contains?(&1, "eval"))
      assert Enum.any?(funcs, &String.contains?(&1, "os_cmd"))
      assert Enum.any?(funcs, &String.contains?(&1, "system_cmd"))
      refute Enum.any?(funcs, &String.contains?(&1, "static_system_cmd"))
    end

    test "a module using only safe APIs produces no findings", ctx do
      skip_without_souffle()
      results = analyze(ctx, [Argus.Test.Fixtures.SafeModule])
      assert results["sink_without_request_path"] == []
      assert results["sink_reachable"] == []
    end
  end

  defp atom_rows(ctx, modules) do
    for [id, func, api, "atom", entry, kind, prox | _] <- analyze(ctx, modules)["sink_reachable"],
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
      results = analyze(:alone, [RequestSurface.DirectPlug, RequestSurface.NotAnEntryPoint])

      rows =
        for [id, func, api, "atom", entry, kind, prox | _] <- results["sink_reachable"],
            do: [id, func, api, entry, kind, prox]

      assert proximity_for(rows, "DirectPlug") != []
      assert proximity_for(rows, "NotAnEntryPoint") == []
      # The identical unsafe call with no request path is reported once, as live code.
      assert [{func, _}] =
               local(results, "atom")
               |> Enum.filter(&String.contains?(elem(&1, 0), "NotAnEntryPoint"))

      assert func =~ "NotAnEntryPoint"
    end

    # The RequestSurface shapes were calibrated by hand: the plug reads
    # conn.params, the LiveView passes params["order_by"] to a helper, the
    # worker hands job.args down two levels. All three are flows now, so
    # the path proximities are exercised on shapes whose data comes from
    # storage instead.
    test "the calibration shapes are proven flows, at every distance" do
      skip_without_souffle()

      rows =
        atom_rows(:alone, [
          RequestSurface.DirectPlug,
          RequestSurface.AdjacentLiveView,
          RequestSurface.TransitiveWorker
        ])

      assert proximity_for(rows, "DirectPlug") == ["flow"]
      assert proximity_for(rows, "order_by") == ["flow"]
      assert proximity_for(rows, "level_two") == ["flow"]
    end

    test "a sink reachable from a request is not also reported as export-reachable", ctx do
      skip_without_souffle()
      results = analyze(ctx, [RequestSurface.DirectPlug])
      assert results["sink_reachable"] != []
      assert results["sink_without_request_path"] == []
    end

    test "a safe conversion in a callback is not flagged", ctx do
      skip_without_souffle()
      assert proximity_for(atom_rows(ctx, [RequestSurface.SafeCallback]), "SafeCallback") == []
    end

    test "a sink inside the callback is direct", ctx do
      skip_without_souffle()
      rows = atom_rows(ctx, [Taint.StoreSourcedPlug])
      assert proximity_for(rows, "StoreSourcedPlug") == ["direct"]
      assert [[_id, _func, api, entry, "plug", "direct"]] = rows
      assert String.contains?(api, "binary_to_atom")
      assert String.contains?(entry, "call/2")
    end

    test "a sink one call away is adjacent", ctx do
      skip_without_souffle()
      rows = atom_rows(ctx, [Taint.StoreSourcedAdjacent])
      assert proximity_for(rows, "convert") == ["adjacent"]
      assert Enum.all?(rows, fn [_, _, _, _, kind, _] -> kind == "live_view" end)
    end

    test "a sink further down the call graph is transitive", ctx do
      skip_without_souffle()
      rows = atom_rows(ctx, [Taint.StoreSourcedWorker])
      assert proximity_for(rows, "level_two") == ["transitive"]
      assert Enum.all?(rows, fn [_, _, _, _, kind, _] -> kind == "oban_job" end)
    end

    test "direct and adjacent are distinguished within one run" do
      skip_without_souffle()
      rows = atom_rows(:alone, [Taint.StoreSourcedPlug, Taint.StoreSourcedAdjacent])
      assert proximity_for(rows, "StoreSourcedPlug") == ["direct"]
      assert proximity_for(rows, "convert") == ["adjacent"]
    end
  end

  describe "proven flow" do
    test "a head pattern and a helper called from a second clause both carry the params", ctx do
      skip_without_souffle()
      rows = atom_rows(ctx, [Taint.FlowLiveView])
      assert proximity_for(rows, "handle_event") == ["flow"]
      assert proximity_for(rows, "order_by") == ["flow"]
      assert Enum.all?(rows, fn [_, _, _, entry, "live_view", _] -> entry =~ "handle_event" end)
    end

    test "the job's args reach a sink two calls down", ctx do
      skip_without_souffle()
      assert proximity_for(atom_rows(ctx, [Taint.FlowTransitive]), "level_two") == ["flow"]
    end

    test "a captured request value reaches the sink inside the closure", ctx do
      skip_without_souffle()
      rows = atom_rows(ctx, [Taint.FlowClosureEnv])
      assert ["flow"] = proximity_for(rows, "FlowClosureEnv")
    end

    test "a flow replaces the path rows for its site: one row per sink" do
      skip_without_souffle()
      rows = atom_rows(:alone, [Taint.FlowLiveView, Taint.FlowTransitive])
      ids = Enum.map(rows, &hd/1)
      assert ids == Enum.uniq(ids)
      assert Enum.all?(rows, fn [_, _, _, _, _, prox] -> prox == "flow" end)
    end

    test "a flow sink is not also reported as export-reachable", ctx do
      skip_without_souffle()
      assert analyze(ctx, [Taint.FlowLiveView])["sink_without_request_path"] == []
    end

    test "data from storage is a path, never a flow" do
      skip_without_souffle()

      rows =
        atom_rows(:alone, [
          Taint.StoreSourcedPlug,
          Taint.StoreSourcedAdjacent,
          Taint.StoreSourcedWorker
        ])

      refute "flow" in Enum.map(rows, &List.last/1)
    end

    test "the socket, the session and a literal are not the request", ctx do
      skip_without_souffle()
      rows = atom_rows(ctx, [Taint.SocketOnly, Taint.SessionOnly])
      assert Enum.map(rows, &List.last/1) |> Enum.uniq() == ["direct"]

      # A literal is one atom: not a sink at all.
      assert atom_rows(ctx, [Taint.LiteralAtom]) == []
    end

    test "the safe conversion is not a sink", ctx do
      skip_without_souffle()
      assert atom_rows(ctx, [Taint.ExistingAtom]) == []
    end

    # A closure a higher-order call runs takes the collection's element as
    # its first parameter (ParamFlow's element flow).
    test "an element handed to a closure a higher-order call runs is a flow", ctx do
      skip_without_souffle()
      assert proximity_for(atom_rows(ctx, [Taint.HofElement]), "HofElement") == ["flow"]
    end
  end

  describe "bounded input" do
    test "a guard holding the value to literals bounds it: no sink", ctx do
      skip_without_souffle()
      assert atom_rows(ctx, [Taint.GuardAllowlist]) == []
    end

    test "a literal list in the body bounds it, short or long, and what is built of it", ctx do
      skip_without_souffle()
      assert atom_rows(ctx, [Taint.BodyAllowlist]) == []
    end

    test "an allowlist handed in bounds it where every caller hands a literal list" do
      skip_without_souffle()
      {:ok, results} = Memo.analyze([Taint.Allow, Taint.ParamAllowlist], :unsafe_input)
      assert results["sink_reachable"] == []

      {:ok, results} =
        Memo.analyze([Taint.Allow, Taint.ParamAllowlist, Taint.OpenAllowlist], :unsafe_input)

      # One site, reached from both entries.
      assert [[_, func, _, "atom" | _]] = Enum.uniq_by(results["sink_reachable"], &hd/1)
      assert func =~ "Allow:safe_to_atom/2"
    end

    test "two atoms made on one line are one finding", ctx do
      skip_without_souffle()
      assert [_] = atom_rows(ctx, [Taint.SameLine])
    end

    test "two atoms on one line made of different things are two findings", ctx do
      skip_without_souffle()
      assert [_, _] = Enum.uniq_by(atom_rows(ctx, [Taint.SameLineMixed]), &hd/1)
    end
  end

  describe "atom creation no request reaches" do
    test "is reported where a caller's input reaches it: an uncalled export, a closure over one",
         ctx do
      skip_without_souffle()

      funcs =
        ctx
        |> analyze([Argus.Test.Fixtures.AtomSources])
        |> local("atom")
        |> Enum.map(&elem(&1, 0))

      assert Enum.any?(funcs, &(&1 =~ "AtomSources:input/1"))
      assert Enum.any?(funcs, &(&1 =~ "AtomSources:-keys/1-fun-0-/1"))
    end

    test "is reported of an export the program also calls with a literal", ctx do
      skip_without_souffle()

      funcs =
        ctx
        |> analyze([Argus.Test.Fixtures.AtomSources])
        |> local("atom")
        |> Enum.map(&elem(&1, 0))

      # name/1's users can call it with anything; default_name/0's
      # literal does not make it the program's own.
      assert Enum.any?(funcs, &(&1 =~ "AtomSources:name/1"))
    end

    test "is reported through a call no propagator lists, and a server's message", ctx do
      skip_without_souffle()

      funcs =
        ctx
        |> analyze([
          Argus.Test.Fixtures.AtomCallerInput,
          Argus.Test.Fixtures.AtomCallerInput.NameServer
        ])
        |> local("atom")
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      assert funcs == [
               "Argus.Test.Fixtures.AtomCallerInput.NameServer:handle_call/3",
               "Argus.Test.Fixtures.AtomCallerInput:key/1"
             ]
    end

    test "is not reported of the environment, or at compile time", ctx do
      skip_without_souffle()

      funcs =
        ctx
        |> analyze([Argus.Test.Fixtures.AtomSources])
        |> local("atom")
        |> Enum.map(&elem(&1, 0))

      refute Enum.any?(funcs, &(&1 =~ "env_level"))
      refute Enum.any?(funcs, &(&1 =~ "cookie!"))
      refute Enum.any?(funcs, &(&1 =~ "MACRO-field"))
    end

    test "is not reported of a server's own messages or a pipeline's own name", ctx do
      skip_without_souffle()

      assert ctx
             |> analyze([
               Argus.Test.Fixtures.AtomFromMessages,
               Argus.Test.Fixtures.AtomProcessName
             ])
             |> local("atom") == []
    end
  end

  describe "severity" do
    test "tracks proximity rather than sink type" do
      row = fn prox ->
        ["i", "M:f/1", "String.to_atom/1", "atom", "E:call/2", "plug", prox, "", "0", ""]
      end

      assert %{severity: :error} = UnsafeInput.finding(:sink_reachable, row.("flow"))
      assert %{severity: :error} = UnsafeInput.finding(:sink_reachable, row.("direct"))
      assert %{severity: :warning} = UnsafeInput.finding(:sink_reachable, row.("adjacent"))
      assert %{severity: :info} = UnsafeInput.finding(:sink_reachable, row.("transitive"))
    end

    test "a flow says so, anchors the argument and tells the reader what to do" do
      row = [
        "i",
        "M:f/1",
        "String.to_atom/1",
        "atom",
        "E:handle_event/3",
        "live_view",
        "flow",
        "",
        "0",
        ""
      ]

      finding = UnsafeInput.finding(:sink_reachable, row)
      assert finding.title =~ "fed by request data"
      assert finding.detail =~ "a flow rather than a path"
      assert finding.at_label =~ "request data reaches"
      assert Enum.any?(finding.help, &(&1 =~ "to_existing_atom"))

      path = UnsafeInput.finding(:sink_reachable, List.replace_at(row, 6, "adjacent"))
      assert path.at_label == "atom interned from a string here"
      assert path.help == finding.help
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
            "direct",
            "",
            "0",
            "unsafe"
          ]
        )

      assert finding.severity == :error
      assert finding.title =~ "websocket"
      assert finding.detail =~ "M:decode/1"
      assert finding.detail =~ "W:handle_in/3"
    end

    test "a sink no request reaches keeps its own severity" do
      assert %{severity: :warning} =
               UnsafeInput.finding(:sink_without_request_path, ["i", "M:f/1", "a", "atom", ""])

      assert %{severity: :error} =
               UnsafeInput.finding(:sink_without_request_path, [
                 "i",
                 "M:f/1",
                 "a",
                 "deserialization",
                 "unsafe"
               ])

      assert %{severity: :error} =
               UnsafeInput.finding(:sink_without_request_path, ["i", "M:f/1", "a", "code", ""])
    end
  end

  describe "sink_endpoint" do
    test "is a related frame naming the HTTP method and path rather than the callback" do
      frame =
        UnsafeInput.evidence(:sink_endpoint, ["M:f/1#3", "get", "/public/x/:id", "W.Controller"])

      assert frame.label == "reachable from GET /public/x/:id"
      assert frame.module == W.Controller
    end
  end

  describe "unbounded children" do
    @all [
      U.Worker,
      U.UncappedSup,
      U.CappedSup,
      U.PublicLive,
      U.CappedLive,
      U.Internal,
      U.TaskLive,
      U.StreamLive
    ]

    defp callers(ctx) do
      analyze(ctx, @all)["unbounded_children_from_request"]
      |> Enum.map(fn [_s, _c, via, _k] -> via end)
      |> Enum.sort()
    end

    defp named?(list, f), do: Enum.any?(list, &String.contains?(&1, f))

    test "an uncapped supervisor driven by a request is reported; a ceiling discharges it", ctx do
      skip_without_souffle()
      callers = callers(ctx)
      assert named?(callers, "PublicLive")
      refute named?(callers, "CappedLive"), "max_children is the whole fix"
      refute named?(callers, "Internal")
    end

    test "a task a request starts is reported; a stream the request enumerates is not", ctx do
      skip_without_souffle()
      callers = callers(ctx)
      assert named?(callers, "TaskLive")
      refute named?(callers, "StreamLive"), "async_stream lives no longer than its request"
    end

    test "the finding names the entry surface it came from", ctx do
      skip_without_souffle()

      assert [[sup, child, _via, kind]] =
               Enum.filter(analyze(ctx, @all)["unbounded_children_from_request"], fn [
                                                                                       _s,
                                                                                       _c,
                                                                                       v,
                                                                                       _k
                                                                                     ] ->
                 v =~ "PublicLive"
               end)

      assert sup =~ "UncappedSup"
      assert child =~ "Worker"
      assert kind == "live_view"
    end
  end
end
