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

  describe "extract/1 — whereis" do
    test "detects Process.whereis" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.WhereisModule))

      assert Map.has_key?(facts, :whereis_call)
      rows = facts[:whereis_call]
      assert rows != []
    end

    test "detects :erlang.whereis" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.WhereisModule))

      rows = facts[:whereis_call]
      assert length(rows) >= 2
    end

    test "marks a result compared against nil or :undefined as checked" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.WhereisModule))

      by_func =
        Map.new(facts[:whereis_call], fn [_id, func, _name, checked] ->
          {func |> String.split(":") |> List.last(), checked}
        end)

      assert by_func["checked_whereis/1"] == "checked"
      assert by_func["checked_erlang_whereis/1"] == "checked"
      assert by_func["unchecked_whereis/1"] == "unchecked"
      assert by_func["find_process/1"] == "unchecked"
    end
  end

  describe "extract/1 — clean module" do
    test "returns empty for plain module" do
      facts = ProcessRegistry.extract(disassemble(Argus.Test.Fixtures.PlainModule))
      assert facts == %{}
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
      Argus.Extractor.Helpers.enable_tracing()
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

  describe "integration with extract pipeline" do
    test "extractor is usable via Pipeline.extract/2" do
      assert {:ok, facts} =
               Argus.Pipeline.extract(
                 [Argus.Test.Fixtures.ProcessRegisterer],
                 extractors: [ProcessRegistry]
               )

      assert Map.has_key?(facts, :process_register)
    end
  end
end
