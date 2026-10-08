defmodule Argus.Extractors.ProcessRegistryTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ProcessRegistry

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  # Rows whose first column is an instruction id, by function: the id is
  # matched against its function rather than spelled, since its index
  # moves with the compiler.
  defp by_function(rows) do
    rows
    |> Enum.map(fn [id, func | rest] ->
      assert id =~ ~r/^#{Regex.escape(func)}#\d+$/
      [func |> String.split(":") |> List.last() | rest]
    end)
    |> Enum.sort()
  end

  describe "extract/1 — process registration" do
    test "Process.register and :erlang.register claim a name for the enclosing module" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.ProcessRegisterer))
      mod = "Argus.Test.Fixtures.ProcessRegisterer"

      assert by_function(facts[:process_register]) == [
               ["erlang_register/1", ":my_erlang_proc", "register"],
               ["register_name/1", ":my_process", "register"]
             ]

      assert Enum.sort(facts[:named_process]) == [
               [mod, ":my_erlang_proc"],
               [mod, ":my_process"]
             ]
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
    test "each lookup, checked where its result is compared against nil or :undefined" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.WhereisModule))

      assert by_function(facts[:name_lookup]) == [
               # A comparison whose boolean is a value checks, as a test does.
               ["alive?/1", "whereis", "", "param", "0", "checked"],
               # The pid survives a call on the stack.
               ["checked_after_call/1", "whereis", "", "param", "0", "checked"],
               ["checked_erlang_whereis/1", "whereis", "", "param", "0", "checked"],
               ["checked_whereis/1", "whereis", "", "param", "0", "checked"],
               # A comparison with self() checks when the pid is not read
               # where they differ; dispatch_by_pid/2 sends to it there,
               # and it may be nil.
               ["dispatch/2", "whereis", "", "param", "0", "checked"],
               ["dispatch_by_pid/2", "whereis", "", "param", "0", "unchecked"],
               ["erlang_whereis/1", "whereis", "", "param", "0", "unchecked"],
               ["find_process/1", "whereis", "", "param", "0", "unchecked"],
               ["registered_self?/1", "whereis", "", "param", "0", "checked"],
               ["started?/1", "whereis", "", "param", "0", "checked"],
               ["unchecked_whereis/1", "whereis", "", "param", "0", "unchecked"]
             ]
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
