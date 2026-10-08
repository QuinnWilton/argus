defmodule Argus.Analyses.UnsafeInputTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Analyses.UnsafeInput
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.Decompression, as: D
  alias Argus.Test.Fixtures.RequestSurface
  alias Argus.Test.Fixtures.Taint
  alias Argus.Test.Fixtures.Template
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
    U.WaitsLive,
    Argus.Test.Fixtures.UnsafeAtomCreation,
    Argus.Test.Fixtures.UnsafeDeserialization,
    Argus.Test.Fixtures.CodeExecution,
    Argus.Test.Fixtures.CommandLiteralJoin,
    Argus.Test.Fixtures.CommandDynamicJoin,
    Argus.Test.Fixtures.CommandLiteralHelper,
    Argus.Test.Fixtures.CommandDynamicHelper,
    Argus.Test.Fixtures.CommandMixTask,
    Argus.Test.Fixtures.CommandMixHelper,
    Argus.Test.Fixtures.CommandMixWrapper,
    Argus.Test.Fixtures.CommandMixCode,
    Argus.Test.Fixtures.CommandMixTestWrapper,
    Argus.Test.Fixtures.CommandOpenWrapper,
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
    Taint.Controller,
    Taint.CookieController,
    Taint.AdminConfigController,
    [Template.ScopesView, Template.OAuthController],
    Taint.PlainPlugHelpers,
    Argus.Test.Fixtures.AtomSources,
    Argus.Test.Fixtures.AtomBounds,
    Argus.Test.Fixtures.AtomFromMessages,
    Argus.Test.Fixtures.AtomProcessName,
    D.FrameHandler,
    D.BoundedFrameHandler,
    D.GzipBodyPlug,
    D.ClientMiddleware,
    D.OwnData,
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

  defp analyze(source, modules) do
    assert {:ok, results} = solve(source, modules)
    results
  end

  defp local(results, sink),
    do: for([_id, func, api, ^sink | _] <- results["sink_without_request_path"], do: {func, api})

  describe "sinks no request reaches" do
    test "flags dynamic atom creation reachable from an export, not to_existing_atom", ctx do
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
      rows = local(analyze(ctx, [Argus.Test.Fixtures.UnsafeDeserialization]), "deserialization")
      funcs = Enum.map(rows, &elem(&1, 0))
      assert Enum.any?(funcs, &String.contains?(&1, "decode_unsafe"))
      # Paginator CVE-2020-15150 is remote code execution THROUGH `[:safe]`.
      assert Enum.any?(funcs, &String.contains?(&1, "decode_atoms_only"))
      refute Enum.any?(funcs, &String.contains?(&1, "decode_validated"))
    end

    test "the deserialization finding says what the options were, and grades [:safe] down", ctx do
      by_func =
        analyze(ctx, [Argus.Test.Fixtures.UnsafeDeserialization])["sink_without_request_path"]
        |> Enum.filter(&(Enum.at(&1, 3) == "deserialization"))
        |> Map.new(fn [_id, func, _api, _sink, _source, _p, safety] = row ->
          {func |> String.split(":") |> List.last(),
           {safety, UnsafeInput.finding(:sink_without_request_path, row)}}
        end)

      assert {"unsafe", unsafe} = by_func["decode_unsafe/1"]
      assert unsafe.title == "binary_to_term without :safe"
      assert unsafe.severity == :error

      assert {"atoms_only", safe} = by_func["decode_atoms_only/1"]
      assert safe.title == "binary_to_term with [:safe] may admit executable terms"
      assert safe.severity == :warning
      assert safe.detail =~ "CVE-2020-15150"
      assert safe.detail =~ "no supported complete validation is proven here"
      refute safe.detail =~ "with [:safe] and nothing else"
      assert Enum.any?(safe.help, &(&1 =~ "non_executable_binary_to_term"))
    end

    @tag flowlog: false
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
      assert safe.title =~ "with [:safe] may admit executable terms"
      assert safe.severity == :error
      assert safe.detail =~ "with a literal [:safe] option"
      assert safe.detail =~ "does not establish that a decoded function reaches an execution site"

      dynamic = UnsafeInput.finding(:sink_reachable, row.("dynamic"))
      assert dynamic.title =~ "options not known statically"

      unsafe =
        UnsafeInput.finding(:sink_without_request_path, [
          "i",
          "M:decode/1",
          ":erlang.binary_to_term/1",
          "deserialization",
          "",
          "0",
          "dynamic"
        ])

      assert unsafe.title == "binary_to_term with options not known statically" and
               unsafe.severity == :error
    end

    test "flags eval and dynamic commands, leaving literal commands quiet", ctx do
      funcs =
        analyze(ctx, [Argus.Test.Fixtures.CodeExecution])
        |> local("code")
        |> Enum.map(&elem(&1, 0))

      assert Enum.any?(funcs, &String.contains?(&1, "eval"))
      assert Enum.any?(funcs, &String.contains?(&1, "os_cmd"))
      assert Enum.any?(funcs, &String.contains?(&1, "system_cmd"))
      refute Enum.any?(funcs, &String.contains?(&1, "static_system_cmd"))

      for quiet <- [:literal_os_cmd, :literal_os_cmd_options, :literal_shell] do
        refute Enum.any?(funcs, &String.contains?(&1, ":#{quiet}/"))
      end

      for dynamic <- [:partial_os_cmd, :nested_os_cmd, :branch_os_cmd, :dynamic_shell] do
        assert Enum.any?(funcs, &String.contains?(&1, ":#{dynamic}/"))
      end

      # A program PATH finds by a literal name is that program; a shell
      # found or named that way, handed a script, is still code execution.
      refute Enum.any?(funcs, &String.contains?(&1, "found_program"))
      assert Enum.any?(funcs, &String.contains?(&1, "found_shell"))
      assert Enum.any?(funcs, &String.contains?(&1, "shell_with_dynamic_script"))
    end

    test "a module using only safe APIs produces no findings", ctx do
      results = analyze(ctx, [Argus.Test.Fixtures.SafeModule])
      assert results["sink_without_request_path"] == []
      assert results["sink_reachable"] == []
    end
  end

  describe "commands" do
    defp commands(ctx, module) do
      ctx
      |> analyze([module])
      |> local("code")
      |> Enum.map(fn {func, _api} -> func |> String.split(":") |> List.last() end)
      |> Enum.sort()
    end

    test "arguments literal on every path, through joins and appends, run no caller code",
         ctx do
      assert commands(ctx, Argus.Test.Fixtures.CommandLiteralJoin) == []
      assert commands(ctx, Argus.Test.Fixtures.CommandDynamicJoin) == ["build/2"]
    end

    test "a local helper that returns only literal lists hands its caller literal arguments",
         ctx do
      assert commands(ctx, Argus.Test.Fixtures.CommandLiteralHelper) == []
      assert commands(ctx, Argus.Test.Fixtures.CommandDynamicHelper) == ["lint/1"]
    end

    test "mix handed a literal task that runs no code runs that task, whatever its options",
         ctx do
      assert commands(ctx, Argus.Test.Fixtures.CommandMixTask) == []
      assert commands(ctx, Argus.Test.Fixtures.CommandMixHelper) == []
      assert commands(ctx, Argus.Test.Fixtures.CommandMixWrapper) == []
    end

    test "mix run, a task the caller names, and a shell's script stay code execution", ctx do
      assert commands(ctx, Argus.Test.Fixtures.CommandMixCode) == ["eval/1", "shell/1", "task/2"]
    end

    test "a wrapper one caller hands mix test, which runs the files named, is reported", ctx do
      assert commands(ctx, Argus.Test.Fixtures.CommandMixTestWrapper) == ["mix/1"]
    end

    test "a wrapper with callers outside the module is not read through its callers", ctx do
      assert commands(ctx, Argus.Test.Fixtures.CommandOpenWrapper) == ["captured_mix/1", "mix/1"]
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
      results = analyze(ctx, [RequestSurface.DirectPlug])
      assert results["sink_reachable"] != []
      assert results["sink_without_request_path"] == []
    end

    test "a safe conversion in a callback is not flagged", ctx do
      assert proximity_for(atom_rows(ctx, [RequestSurface.SafeCallback]), "SafeCallback") == []
    end

    test "a sink inside the callback is direct", ctx do
      rows = atom_rows(ctx, [Taint.StoreSourcedPlug])
      assert proximity_for(rows, "StoreSourcedPlug") == ["direct"]
      assert [[_id, _func, api, entry, "plug", "direct"]] = rows
      assert String.contains?(api, "binary_to_atom")
      assert String.contains?(entry, "call/2")
    end

    test "a sink one call away is adjacent", ctx do
      rows = atom_rows(ctx, [Taint.StoreSourcedAdjacent])
      assert proximity_for(rows, "convert") == ["adjacent"]
      assert Enum.all?(rows, fn [_, _, _, _, kind, _] -> kind == "live_view" end)
    end

    test "a sink further down the call graph is transitive", ctx do
      rows = atom_rows(ctx, [Taint.StoreSourcedWorker])
      assert proximity_for(rows, "level_two") == ["transitive"]
      assert Enum.all?(rows, fn [_, _, _, _, kind, _] -> kind == "oban_job" end)
    end
  end

  describe "proven flow" do
    test "a head pattern and a helper called from a second clause both carry the params", ctx do
      rows = atom_rows(ctx, [Taint.FlowLiveView])
      assert proximity_for(rows, "handle_event") == ["flow"]
      assert proximity_for(rows, "order_by") == ["flow"]
      assert Enum.all?(rows, fn [_, _, _, entry, "live_view", _] -> entry =~ "handle_event" end)
    end

    test "the job's args reach a sink two calls down", ctx do
      assert proximity_for(atom_rows(ctx, [Taint.FlowTransitive]), "level_two") == ["flow"]
    end

    test "a captured request value reaches the sink inside the closure", ctx do
      rows = atom_rows(ctx, [Taint.FlowClosureEnv])
      assert ["flow"] = proximity_for(rows, "FlowClosureEnv")
    end

    test "a controller action is a request entry, though no call reaches it", ctx do
      rows = atom_rows(ctx, [Taint.Controller])
      assert [[_id, func, _api, entry, "controller", "flow"]] = rows
      assert func =~ "show/2"
      assert entry =~ "show/2"
    end

    test "a cookie fetched signed is the server's; one fetched unverified is request data",
         ctx do
      flows =
        for [_id, func, _api, "deserialization", _entry, _kind, "flow" | _] <-
              analyze(ctx, [Taint.CookieController])["sink_reachable"],
            do: func |> String.split(":") |> List.last()

      assert flows == ["prefs/2"]
    end

    test "an admin config action's evaluations: two flows and a path", ctx do
      rows =
        for [_id, func, _api, "code", _entry, "controller", proximity | _] <-
              analyze(ctx, [Taint.AdminConfigController])["sink_reachable"],
            do: {func |> String.split(":") |> List.last(), proximity}

      # A pattern read out of Regex.named_captures/2, and each element of a
      # list inside the closure Enum.map/2 runs, are the request's; the
      # configured script two calls away is a path.
      assert Enum.sort(rows) == [
               {"-args/1-fun-0-/1", "flow"},
               {"configured/0", "transitive"},
               {"regex/1", "flow"}
             ]
    end

    test "an atom made of a template's assigns is rendered, not a bare path", ctx do
      rows =
        for [_id, func, _api, "atom", _entry, kind, proximity | _] <-
              analyze(ctx, [Template.ScopesView, Template.OAuthController])["sink_reachable"],
            uniq: true,
            do: {func |> String.split(":") |> List.last(), kind, proximity}

      # akkoma's OAuth scopes: one per scope the app's row holds, whichever
      # action's render reaches the view (a row per entry, one finding per
      # site). The literal in labels.html is no sink.
      assert [{func, "controller", "rendered"}] = rows
      assert func =~ "_scopes.html/1"

      finding =
        UnsafeInput.finding(:sink_reachable, [
          "i",
          "V:-_scopes.html/1-fun-0-/2",
          "String.to_atom/1",
          "atom",
          "C:authorize/2",
          "controller",
          "rendered",
          "",
          "0",
          ""
        ])

      assert finding.severity == :warning
      assert finding.title =~ "made of a template's assigns"
    end

    test "a plug's exported helper is no action", ctx do
      results = analyze(ctx, [Taint.PlainPlugHelpers])
      assert atom_rows(ctx, [Taint.PlainPlugHelpers]) == []
      assert [[_id, func | _]] = results["sink_without_request_path"]
      assert func =~ "label/2"
    end

    test "a flow replaces the path rows for its site: one row per sink" do
      rows = atom_rows(:alone, [Taint.FlowLiveView, Taint.FlowTransitive])
      ids = Enum.map(rows, &hd/1)
      assert ids == Enum.uniq(ids)
      assert Enum.all?(rows, fn [_, _, _, _, _, prox] -> prox == "flow" end)
    end

    test "a flow sink is not also reported as export-reachable", ctx do
      assert analyze(ctx, [Taint.FlowLiveView])["sink_without_request_path"] == []
    end

    test "data from storage is a path, never a flow", ctx do
      rows =
        atom_rows(ctx, [
          Taint.StoreSourcedPlug,
          Taint.StoreSourcedAdjacent,
          Taint.StoreSourcedWorker
        ])

      refute "flow" in Enum.map(rows, &List.last/1)
    end

    test "the socket, the session and a literal are not the request", ctx do
      rows = atom_rows(ctx, [Taint.SocketOnly, Taint.SessionOnly])
      assert Enum.map(rows, &List.last/1) |> Enum.uniq() == ["direct"]

      # A literal is one atom: not a sink at all.
      assert atom_rows(ctx, [Taint.LiteralAtom]) == []
    end

    test "the safe conversion is not a sink", ctx do
      assert atom_rows(ctx, [Taint.ExistingAtom]) == []
    end

    # A closure a higher-order call runs takes the collection's element as
    # its first parameter (ParamFlow's element flow).
    test "an element handed to a closure a higher-order call runs is a flow", ctx do
      assert proximity_for(atom_rows(ctx, [Taint.HofElement]), "HofElement") == ["flow"]
    end
  end

  describe "bounded input" do
    test "a guard holding the value to literals bounds it: no sink", ctx do
      assert atom_rows(ctx, [Taint.GuardAllowlist]) == []
    end

    test "a literal list in the body bounds it, short or long, and what is built of it", ctx do
      assert atom_rows(ctx, [Taint.BodyAllowlist]) == []
    end

    test "an allowlist handed in bounds it where every caller hands a literal list" do
      {:ok, results} = Memo.analyze([Taint.Allow, Taint.ParamAllowlist], :unsafe_input)
      assert results["sink_reachable"] == []

      {:ok, results} =
        Memo.analyze([Taint.Allow, Taint.ParamAllowlist, Taint.OpenAllowlist], :unsafe_input)

      # One site, reached from both entries.
      assert [[_, func, _, "atom" | _]] = Enum.uniq_by(results["sink_reachable"], &hd/1)
      assert func =~ "Allow:safe_to_atom/2"
    end

    test "two atoms made on one line are one finding", ctx do
      assert [_] = atom_rows(ctx, [Taint.SameLine])
    end

    test "two atoms on one line made of different things are two findings", ctx do
      assert [_, _] = Enum.uniq_by(atom_rows(ctx, [Taint.SameLineMixed]), &hd/1)
    end
  end

  describe "atom creation no request reaches" do
    test "is reported where a caller's input reaches it: an uncalled export, a closure over one",
         ctx do
      funcs =
        ctx
        |> analyze([Argus.Test.Fixtures.AtomSources])
        |> local("atom")
        |> Enum.map(&elem(&1, 0))

      assert Enum.any?(funcs, &(&1 =~ "AtomSources:input/1"))
      assert Enum.any?(funcs, &(&1 =~ "AtomSources:-keys/1-fun-0-/1"))
    end

    test "is reported of an export the program also calls with a literal", ctx do
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
      funcs =
        ctx
        |> analyze([Argus.Test.Fixtures.AtomSources])
        |> local("atom")
        |> Enum.map(&elem(&1, 0))

      refute Enum.any?(funcs, &(&1 =~ "env_level"))
      refute Enum.any?(funcs, &(&1 =~ "cookie!"))
      refute Enum.any?(funcs, &(&1 =~ "MACRO-field"))
    end

    test "is not reported of a close integer range, an atom, or an atom's name", ctx do
      results = analyze(ctx, [Argus.Test.Fixtures.AtomBounds])

      funcs =
        results
        |> local("atom")
        |> Enum.map(fn {func, _api} -> func |> String.split(":") |> List.last() end)
        |> Enum.uniq()
        |> Enum.sort()

      # The twins: a float passes `n >= 1 and n <= 8`, one end bounds
      # nothing, a hundred thousand values are not a bound, an integer
      # beside the atom is unbounded, and an untested name may be a string.
      assert funcs == ["between/1", "from/1", "named/1", "numbered/2", "wide/1"]

      # The atoms bound is a count, not a vetting of the bytes.
      assert [{decode, _}] = local(results, "deserialization")
      assert decode =~ "AtomBounds:decode/1"
    end

    test "is not reported of a server's own messages or a pipeline's own name", ctx do
      assert ctx
             |> analyze([
               Argus.Test.Fixtures.AtomFromMessages,
               Argus.Test.Fixtures.AtomProcessName
             ])
             |> local("atom") == []
    end
  end

  describe "severity" do
    @describetag flowlog: false

    test "tracks proximity rather than sink type" do
      row = fn prox ->
        ["i", "M:f/1", "String.to_atom/1", "atom", "E:call/2", "plug", prox, "", "0", ""]
      end

      assert %{severity: :error} = UnsafeInput.finding(:sink_reachable, row.("flow"))
      assert %{severity: :error} = UnsafeInput.finding(:sink_reachable, row.("direct"))
      assert %{severity: :warning} = UnsafeInput.finding(:sink_reachable, row.("adjacent"))
      assert %{severity: :info} = UnsafeInput.finding(:sink_reachable, row.("transitive"))
    end

    test "code execution a request reaches is never below :warning" do
      row = fn prox, source, p ->
        [
          "i",
          "M:f/1",
          "Code.eval_string/1",
          "code",
          "E:update/2",
          "controller",
          prox,
          source,
          p,
          ""
        ]
      end

      assert %{severity: :error} = UnsafeInput.finding(:sink_reachable, row.("flow", "", "0"))

      assert %{severity: :warning} =
               UnsafeInput.finding(:sink_reachable, row.("adjacent", "", "0"))

      # The tier that is :info for the other sinks.
      assert %{severity: :warning} =
               UnsafeInput.finding(:sink_reachable, row.("transitive", "", "0"))

      # A prior that says the function reads configuration still marks the
      # row heuristic, and leaves it at :warning.
      stepped = UnsafeInput.finding(:sink_reachable, row.("adjacent", "config", "900"))
      assert stepped.severity == :warning and stepped.provenance == :heuristic

      # The atom sink beside it keeps its tiers.
      atom = row.("adjacent", "config", "900") |> List.replace_at(3, "atom")
      assert %{severity: :info} = UnsafeInput.finding(:sink_reachable, atom)

      # Nor does the tooling step take it lower: the floor rides with the
      # row into Build, which drops it once the step is taken.
      assert %{floor: :warning} = stepped

      findings =
        Argus.Findings.build(UnsafeInput, %{
          "sink_reachable" => [row.("transitive", "", "0") |> List.replace_at(0, "M:f/1#3")],
          "tooling" => [["M", "prior", "990"]]
        })

      assert [%{severity: :warning, provenance: :heuristic} = built] = findings
      refute Map.has_key?(built, :floor)
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
               UnsafeInput.finding(:sink_without_request_path, [
                 "i",
                 "M:f/1",
                 "a",
                 "atom",
                 "",
                 "0",
                 ""
               ])

      assert %{severity: :error} =
               UnsafeInput.finding(:sink_without_request_path, [
                 "i",
                 "M:f/1",
                 "a",
                 "deserialization",
                 "",
                 "0",
                 "unsafe"
               ])

      assert %{severity: :error} =
               UnsafeInput.finding(:sink_without_request_path, [
                 "i",
                 "M:f/1",
                 "a",
                 "code",
                 "",
                 "0",
                 ""
               ])
    end

    test "a value the prior is sure is not outside data steps down and says what it is" do
      atom =
        UnsafeInput.finding(:sink_without_request_path, [
          "i",
          "M:f/1",
          "a",
          "atom",
          "configured",
          "930",
          ""
        ])

      assert atom.severity == :info and atom.provenance == :heuristic and atom.confidence == 930

      assert List.last(atom.help) ==
               "heuristic: the string it makes an atom of is a name or setting the operator " <>
                 "configures, not outside data (p=0.93)"

      decode =
        UnsafeInput.finding(:sink_without_request_path, [
          "i",
          "M:f/1",
          "a",
          "deserialization",
          "stored",
          "960",
          "unsafe"
        ])

      assert decode.severity == :warning and decode.provenance == :heuristic
      assert List.last(decode.help) =~ "what it decodes is data the program stored itself"

      code =
        UnsafeInput.finding(:sink_without_request_path, [
          "i",
          "M:f/1",
          "a",
          "code",
          "operator",
          "910",
          ""
        ])

      assert code.severity == :warning and
               code.title == "Dynamic code execution reachable from exports"
    end
  end

  describe "sink_endpoint" do
    @tag flowlog: false
    test "is a related frame naming the HTTP method and path rather than the callback" do
      frame =
        UnsafeInput.evidence(:sink_endpoint, ["M:f/1#3", "get", "/public/x/:id", "W.Controller"])

      assert frame.label == "reachable from GET /public/x/:id"
      assert frame.module == W.Controller
    end
  end

  describe "decompression" do
    defp inflates(ctx, modules) do
      results = analyze(ctx, modules)

      reached =
        for [_id, func, _api, "decompression", _entry, kind, prox | _] <-
              results["sink_reachable"],
            do: {short(func), kind, prox}

      local =
        for [_id, func, _api, "decompression", _source, _p, _s] <-
              results["sink_without_request_path"],
            do: short(func)

      {reached, local}
    end

    defp short(func), do: func |> String.split(".") |> List.last()

    test "a frame a socket handler inflates in one call is fed by the socket's data", ctx do
      assert {[{"FrameHandler:handle_data/3", "socket", "flow"}], []} =
               inflates(ctx, [D.FrameHandler])

      finding =
        UnsafeInput.finding(
          :sink_reachable,
          hd(analyze(ctx, [D.FrameHandler])["sink_reachable"])
        )

      assert finding.title ==
               "Unbounded decompression fed by request data from a ThousandIsland handler (socket data)"

      assert finding.severity == :error
    end

    test "a request body a plug gunzips is a flow", ctx do
      assert {[{"GzipBodyPlug:call/2", "plug", "flow"}], []} = inflates(ctx, [D.GzipBodyPlug])
    end

    test "a body a client middleware's caller hands in is reported with no request path", ctx do
      assert {[], ["ClientMiddleware:decompress/1"]} = inflates(ctx, [D.ClientMiddleware])
    end

    test "inflating in bounded chunks, or data the program wrote, is quiet", ctx do
      assert {[], []} = inflates(ctx, [D.BoundedFrameHandler])
      assert {[], []} = inflates(ctx, [D.OwnData])
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
      U.StreamLive,
      U.WaitsLive
    ]

    defp callers(ctx) do
      analyze(ctx, @all)["unbounded_children_from_request"]
      |> Enum.map(fn [_s, _c, via, _k] -> via end)
      |> Enum.sort()
    end

    test "a child a request starts and leaves running, under no ceiling, exactly", ctx do
      assert callers(ctx) == [
               # An uncapped supervisor a request drives.
               inspect(U.PublicLive) <> ":handle_event/3",
               # A task a request starts.
               inspect(U.TaskLive) <> ":handle_event/3"
             ]

      # Quiet: CappedLive (max_children is the whole fix), Internal (no
      # request drives it), WaitsLive (a start the request then waits
      # out is no child that outlives it), StreamLive (async_stream lives
      # no longer than its request).
    end

    test "the finding names the entry surface it came from", ctx do
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
