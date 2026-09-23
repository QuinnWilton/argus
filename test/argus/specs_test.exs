defmodule Argus.SpecsTest do
  use ExUnit.Case, async: true

  alias Argus.Specs
  alias Argus.Test.Fixtures.Specs, as: Fixture

  describe "installed/1" do
    test "reads OTP's and Elixir's specs off the code path" do
      ets = Specs.installed(:ets)
      assert ets[{:new, 2}] == [:total]
      assert ets[{:delete, 2}] == [:total, :constant]
      assert ets[{:insert_new, 2}] == [:can_fail]
      assert ets[{:whereis, 1}] == [:can_fail]

      assert Enum.sort(Specs.installed(GenServer)[{:start_link, 3}]) == [:can_fail, :returns_pid]
      assert Specs.installed(Supervisor)[{:stop, 3}] == [:total, :constant]
      assert :can_fail in Specs.installed(Process)[{:whereis, 1}]
    end

    test "a term() return is unknown, not total" do
      refute Map.has_key?(Specs.installed(:gen_server), {:call, 3})
    end

    test "a module shipped without specs is unknown" do
      assert Specs.installed(:mnesia) == :unknown
      assert Specs.installed(:no_such_module_anywhere) == :unknown
    end

    test "answers the same when asked again" do
      assert Specs.installed(:ets) == Specs.installed(:ets)
    end
  end

  describe "installed/2" do
    test "answers from the run's table once a module is in it" do
      memo = :ets.new(:memo, [:set, :public])
      assert Specs.installed(:ets, memo) == Specs.installed(:ets)
      assert :ets.lookup(memo, {:specs, :ets}) == [{{:specs, :ets}, Specs.installed(:ets)}]

      :ets.insert(memo, {{:specs, :ets}, :unknown})
      assert Specs.installed(:ets, memo) == :unknown
    end

    test "is installed/1 without a table" do
      assert Specs.installed(:ets, nil) == Specs.installed(:ets)
    end

    test "reads a beam's own specs through the table as without it" do
      memo = :ets.new(:memo, [:set, :public])
      path = Fixture |> :code.which() |> List.to_string()
      assert Specs.of_beam(path, memo) == Specs.of_beam(path)
    end
  end

  describe "of_beam/1" do
    setup do
      {:ok, returns} = Fixture |> :code.which() |> List.to_string() |> Specs.of_beam()
      %{returns: returns}
    end

    test "resolves local types, parameterized ones included", %{returns: r} do
      assert Enum.sort(r[{:starts, 0}]) == [:can_fail, :returns_pid]
      assert Enum.sort(r[{:wrapped_pid, 0}]) == [:can_fail, :returns_pid]
    end

    test "resolves remote types", %{returns: r} do
      assert Enum.sort(r[{:starts_remote, 0}]) == [:can_fail, :returns_pid]
    end

    test "classifies literals, booleans, nil and no_return", %{returns: r} do
      assert r[{:total, 0}] == [:total, :constant]
      assert r[{:bool, 0}] == [:can_fail]
      assert r[{:maybe_nil, 0}] == [:can_fail]
      assert r[{:halts, 0}] == [:no_return]
      assert r[{:bounded, 1}] == [:total]
    end

    test "has no shape for a term() return or a function without a spec", %{returns: r} do
      refute Map.has_key?(r, {:anything, 0})
      refute Map.has_key?(r, {:unspecced, 0})
    end

    test "reads beam contents as well as a path" do
      binary = Fixture |> :code.which() |> File.read!()
      assert {:ok, %{{:total, 0} => [:total, :constant]}} = Specs.of_beam(binary)
    end

    test "reads what installed/1 reads, from an Elixir or an Erlang beam" do
      for mod <- [GenServer, Supervisor, :ets, :gen_server] do
        assert mod |> :code.which() |> List.to_string() |> Specs.of_beam() ==
                 {:ok, Specs.installed(mod)}
      end
    end

    test "is :error for something that is not a beam" do
      assert Specs.of_beam("/no/such/file.beam") == :error
    end
  end

  describe "of_debug_info/3" do
    test "reads a chunk read once as of_beam/1 reads the beam" do
      for mod <- [Fixture, GenServer, :ets] do
        {:ok, chunk} = Argus.Extractor.Helpers.debug_info(%{module: mod})

        assert Specs.of_debug_info(mod, chunk) ==
                 mod |> :code.which() |> List.to_string() |> Specs.of_beam()
      end
    end

    test "is :error for a chunk that is not debug info" do
      assert Specs.of_debug_info(Fixture, :no_debug_info) == :error
    end
  end

  test "the environment digest is stable within a VM" do
    assert Specs.environment_digest() == Specs.environment_digest()
    assert Specs.environment_digest() =~ ~r/^[0-9a-f]{64}$/
  end

  describe "Argus.Extractors.Specs" do
    setup do
      {:ok, facts} = Argus.Pipeline.extract([Fixture], extractors: [Argus.Extractors.Specs])
      %{rows: MapSet.new(facts[:spec_return] || [])}
    end

    test "emits the module's own specs as analyzed", %{rows: rows} do
      assert ["Argus.Test.Fixtures.Specs:total/0", "total", "analyzed"] in rows
      assert ["Argus.Test.Fixtures.Specs:halts/0", "no_return", "analyzed"] in rows
    end

    test "emits the specs of the remote functions it calls as installed", %{rows: rows} do
      assert [":ets:delete/2", "total", "installed"] in rows
      assert ["GenServer:start_link/3", "can_fail", "installed"] in rows
    end

    test "emits nothing for a callee without specs", %{rows: rows} do
      refute Enum.any?(rows, fn [f | _] -> String.starts_with?(f, ":mnesia:") end)
    end

    test "emits the same rows beside another reader of the chunk", %{rows: rows} do
      # With Generated in the run the pipeline reads the chunk once for both.
      {:ok, facts} =
        Argus.Pipeline.extract([Fixture],
          extractors: [Argus.Extractors.Generated, Argus.Extractors.Specs]
        )

      assert MapSet.new(facts[:spec_return]) == rows
    end
  end
end
