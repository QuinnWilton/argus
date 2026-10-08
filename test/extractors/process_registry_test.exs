defmodule Argus.Extractors.ProcessRegistryTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ProcessRegistry

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  describe "extract/1 — process registration" do
    test "detects Process.register" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.ProcessRegisterer))

      assert Map.has_key?(facts, :process_register)
      rows = facts[:process_register]

      assert Enum.any?(rows, fn [_, _, name, method] ->
               name == ":my_process" and method == "register"
             end)
    end

    test "detects :erlang.register" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.ProcessRegisterer))

      rows = facts[:process_register]

      assert Enum.any?(rows, fn [_, _, name, method] ->
               name == ":my_erlang_proc" and method == "register"
             end)
    end
  end

  describe "extract/1 — named Agent starts" do
    test "the name in an Agent start's options is claimed, by the module that starts it" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.NamedAgents))

      registered =
        for [_id, func, name, method] <- facts[:process_register],
            do: {func |> String.split(":") |> List.last(), name, method}

      assert Enum.sort(registered) == [
               {"start_named/1", ":named_agent", "start_link"},
               {"start_named_mfa/0", ":named_mfa_agent", "start_link"},
               {"start_unlinked/1", ":unlinked_agent", "start"}
             ]

      mod = "Argus.Test.Fixtures.NamedAgents"

      assert Enum.sort(facts[:named_process]) == [
               [mod, ":named_agent"],
               [mod, ":named_mfa_agent"],
               [mod, ":unlinked_agent"]
             ]

      created =
        for [_id, func, api, "", source, key] <- facts[:creating_op],
            do: {func |> String.split(":") |> List.last(), api, source, key}

      assert Enum.sort(created) == [
               {"start_named/1", "start_link", "literal", ":named_agent"},
               {"start_named_mfa/0", "start_link", "literal", ":named_mfa_agent"},
               {"start_unlinked/1", "start", "literal", ":unlinked_agent"}
             ]
    end
  end

  describe "extract/1 — named starts" do
    test "gen_statem, supervisor and event manager starts claim their names; a global name is its own" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.NamedStarts))

      registered =
        for [_id, func, name, _method] <- facts[:process_register],
            do: {func |> String.split(":") |> List.last(), name}

      assert Enum.sort(registered) == [
               {"children/0", ":sup_children"},
               {"events/0", ":events"},
               {"global/0", "{:global, :g_elixir}"},
               {"global_erlang/0", "{:global, :g_erlang}"},
               {"statem/0", ":statem_local"},
               {"sup/0", ":sup_named"},
               {"sup_erlang/0", ":sup_erlang"}
             ]

      server = "Argus.Test.Fixtures.NamedGenServer"

      # The module-less starts (a children list, an event manager) name no
      # module's process.
      assert Enum.sort(facts[:named_process]) ==
               Enum.sort([
                 [server, "{:global, :g_elixir}"],
                 [server, "{:global, :g_erlang}"],
                 [server, ":statem_local"],
                 [server, ":sup_named"],
                 [server, ":sup_erlang"]
               ])

      keys = for [_id, _func, _api, "", "literal", key] <- facts[:creating_op], do: key
      assert "{:global, :g_erlang}" in keys
      refute ":g_erlang" in keys
    end
  end

  describe "extract/1 — whereis" do
    test "detects Process.whereis" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.WhereisModule))

      assert Map.has_key?(facts, :name_lookup)
      rows = facts[:name_lookup]
      assert rows != []

      assert Enum.all?(rows, fn [_id, _func, api, "", _source, _key, _checked] ->
               api == "whereis"
             end)
    end

    test "detects :erlang.whereis" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.WhereisModule))

      rows = facts[:name_lookup]
      assert length(rows) >= 2
    end

    test "marks a result compared against nil or :undefined as checked" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.WhereisModule))

      by_func =
        Map.new(facts[:name_lookup], fn [_id, func, _api, _scope, _source, _key, checked] ->
          {func |> String.split(":") |> List.last(), checked}
        end)

      assert by_func["checked_whereis/1"] == "checked"
      assert by_func["checked_erlang_whereis/1"] == "checked"
      assert by_func["checked_after_call/1"] == "checked"
      assert by_func["unchecked_whereis/1"] == "unchecked"
      assert by_func["find_process/1"] == "unchecked"
    end

    test "a comparison whose boolean is a value checks, as a test does" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.WhereisModule))

      by_func =
        Map.new(facts[:name_lookup], fn [_id, func, _api, _scope, _source, _key, checked] ->
          {func |> String.split(":") |> List.last(), checked}
        end)

      assert by_func["started?/1"] == "checked"
      assert by_func["alive?/1"] == "checked"
    end

    test "a comparison with self() checks when the pid is not read where they differ" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.WhereisModule))

      by_func =
        Map.new(facts[:name_lookup], fn [_id, func, _api, _scope, _source, _key, checked] ->
          {func |> String.split(":") |> List.last(), checked}
        end)

      assert by_func["dispatch/2"] == "checked"
      assert by_func["registered_self?/1"] == "checked"

      assert by_func["dispatch_by_pid/2"] == "unchecked",
             "the branch where the pid is not self() sends to it, and it may be nil"
    end
  end

  describe "extract/1 — registered and unregister" do
    test "Process.registered/0 is a lookup of every name at once" do
      facts =
        ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.CheckThenAct.RegisterIfUnlisted))

      assert [[_id, _func, "registered", "", "any", "", "checked"]] = facts[:name_lookup]
    end

    test ":erlang.registered/0 too" do
      facts = ProcessRegistry.extract(disassemble(:padl2010_registered))
      assert [[_id, _func, "registered", "", "any", "", _]] = facts[:name_lookup]
    end

    test "unregister releases a name, identified like a lookup's" do
      facts =
        ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.CheckThenAct.UnregisterIfPresent))

      assert [[_id, func, "unregister", "param", "0"]] = facts[:name_release]
      assert func =~ "release/1"
      refute Map.has_key?(facts, :creating_op)
    end
  end

  describe "extract/1 — named_process" do
    test "emits named_process for direct register/2 with the enclosing module" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.ProcessRegisterer))

      assert Map.has_key?(facts, :named_process)
      rows = facts[:named_process]

      # Direct Process.register(self(), :my_process) — emit
      # named_process(<enclosing module>, :my_process).
      assert Enum.any?(rows, fn [mod, name] ->
               mod == "Argus.Test.Fixtures.ProcessRegisterer" and name == ":my_process"
             end)
    end

    test "a statically unknowable name records imprecision, never \":dynamic\"" do
      # `name: Keyword.fetch!(opts, :name)` resolves the options list
      # partially — the name slot holds the :dynamic placeholder atom.
      # Inspecting it would forge a ":dynamic" name that evades every
      # `!= "dynamic"` filter in the Datalog rules (seen as bogus
      # coverage_named_process_unreachable rows on phoenix_pubsub).
      Argus.Extractor.Facts.enable_tracing()
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.DynamicNameServer))

      for [_mod, name] <- Map.get(facts, :named_process, []) do
        refute name == ":dynamic"
      end

      for [_id, _func, name, _method] <- Map.get(facts, :process_register, []) do
        refute name == ":dynamic"
      end

      assert Enum.any?(Map.get(facts, :imprecision, []), fn
               [category, func, _relation, _reason] ->
                 category == "gen_server_start_name" and func =~ "DynamicNameServer"
             end)
    end
  end
end
