defmodule Argus.Instr.ReachingRestoreTest do
  use ExUnit.Case, async: true

  alias Argus.Instr.Reaching

  @cache :argus_instr_reaching

  test "restoring the exact installed solution leaves its lookup structures intact" do
    functions = [function(:first, 1)]
    exported = Reaching.export(functions)
    Process.delete(@cache)

    assert :ok = Reaching.restore(functions, exported)
    before = Process.get(@cache)
    assert :ok = Reaching.restore(functions, exported)
    assert :erts_debug.same(before, Process.get(@cache))

    {copied_functions, copied_exported} = copy({functions, exported})
    assert :ok = Reaching.restore(copied_functions, copied_exported)
    assert :erts_debug.same(before, Process.get(@cache))
  end

  test "a changed exported solution replaces the current one for identical instructions" do
    functions = [function(:first, 1)]
    instrs = instructions(hd(functions))
    exported = Reaching.export(functions)

    assert Reaching.sources(instrs, 2, {:x, 0}) == [1]
    assert :ok = Reaching.restore(functions, [%{}])
    assert Reaching.sources(instrs, 2, {:x, 0}) == []
    assert installed_solution().skeleton == nil
    assert :ok = Reaching.restore(functions, exported)
    assert Reaching.sources(instrs, 2, {:x, 0}) == [1]
  end

  test "restored bodies distinguish integer and float literals with the same function name" do
    integer = [function(:first, 1)]
    float = [function(:first, 1.0)]
    exported = Reaching.export(integer)

    for functions <- [integer, float, integer, float] do
      assert :ok = Reaching.restore(functions, exported)
      instrs = instructions(hd(functions))
      assert Reaching.at(instrs, 1) === Enum.at(instrs, 1)
      assert Reaching.sources(instrs, 2, {:x, 0}) == [1]
    end
  end

  test "a changed imported solution is not borrowed by a different body with the same skeleton" do
    first = [function(:first, 1)]
    twin = instructions(function(:first, 2))

    assert :ok = Reaching.restore(first, [%{}])
    assert Reaching.sources(instructions(hd(first)), 2, {:x, 0}) == []
    assert Reaching.sources(twin, 2, {:x, 0}) == [1]
  end

  test "exported incoming sources are compared exactly" do
    functions = [function(:first, 1)]
    instrs = instructions(hd(functions))

    for value <- [1, 1.0, 1] do
      blocks = %{0 => {{0, 1, 2}, %{{:x, 9} => MapSet.new([{:param, value}])}}}
      assert :ok = Reaching.restore(functions, [blocks])
      assert Reaching.sources(instrs, 0, {:x, 9}) === [{:param, value}]
    end
  end

  test "preparing current functions shares their complete solutions" do
    functions = [function(:first, 1)]
    instrs = instructions(hd(functions))
    assert Reaching.sources(instrs, 2, {:x, 0}) == [1]
    original = installed_solution()
    prepared = Reaching.prepare(functions)

    Reaching.export([function(:other, :replacement)])
    assert :ok = Reaching.restore_prepared(prepared)
    restored = installed_solution()

    assert :erts_debug.same(restored, original)
    assert Reaching.at(instrs, 1) === {:move, {:literal, {1}}, {:x, 0}}
    assert Reaching.sources(instrs, 2, {:x, 0}) == [1]

    before = Process.get(@cache)
    assert :ok = Reaching.restore_prepared(prepared)
    assert :erts_debug.same(before, Process.get(@cache))
  end

  test "prepared exported solutions can be reinstalled after interleaved modules" do
    first = [function(:first, 1)]
    second = [function(:second, 2)]
    exported = Reaching.export(first)
    Reaching.export(second)
    before = Process.get(@cache)

    prepared = Reaching.prepare(first, exported)
    assert :erts_debug.same(before, Process.get(@cache))
    assert :ok = Reaching.restore_prepared(prepared)
    original = installed_solution()

    for _ <- 1..3 do
      assert Reaching.at(instructions(hd(second)), 1) === {:move, {:literal, {2}}, {:x, 0}}
      assert :ok = Reaching.restore_prepared(prepared)
      restored = installed_solution()
      assert :erts_debug.same(restored.code, original.code)
      assert :erts_debug.same(restored.block_of, original.block_of)
      assert Reaching.sources(instructions(hd(first)), 2, {:x, 0}) == [1]
    end
  end

  test "prepared solutions replace a different solution of the same body" do
    functions = [function(:first, 1)]
    instrs = instructions(hd(functions))
    prepared = Reaching.prepare(functions)

    assert :ok = Reaching.restore(functions, [%{}])
    assert Reaching.sources(instrs, 2, {:x, 0}) == []
    assert :ok = Reaching.restore_prepared(prepared)
    assert Reaching.sources(instrs, 2, {:x, 0}) == [1]
  end

  test "prepared states keep exact bodies when versions of a function alternate" do
    integer = function(:first, 1)
    float = function(:first, 1.0)
    prepared_integer = Reaching.prepare([integer])
    prepared_float = Reaching.prepare([float])

    for {function, prepared} <- [
          {integer, prepared_integer},
          {float, prepared_float},
          {integer, prepared_integer}
        ] do
      assert :ok = Reaching.restore_prepared(prepared)
      instrs = instructions(function)
      assert Reaching.at(instrs, 1) === Enum.at(instrs, 1)
      assert Reaching.sources(instrs, 2, {:x, 0}) == [1]
    end
  end

  test "empty bodies and truncated exports retain their restore behavior" do
    empty = {:function, :empty, 0, 0, []}
    assert :ok = Reaching.restore([empty], [%{}])
    assert Reaching.sources([], 0, {:x, 0}) == []
    assert :ok = Reaching.restore_prepared(Reaching.prepare([empty]))

    functions = [function(:first, 1), function(:second, 2)]
    [exported] = Reaching.export(Enum.take(functions, 1))
    Process.delete(@cache)

    assert :ok = Reaching.restore(functions, [exported])
    {{:atom, :first}, _} = Process.get(@cache)
    assert :ok = Reaching.restore_prepared(Reaching.prepare(functions, [exported]))
    {{:atom, :first}, _} = Process.get(@cache)
  end

  test "an invalid later export still raises after installing earlier valid functions" do
    first = function(:first, 1)
    [exported] = Reaching.export([first])
    Process.delete(@cache)

    assert_raise Protocol.UndefinedError, fn ->
      Reaching.restore([first, function(:second, 2)], [exported, :invalid])
    end

    {{:atom, :first}, _} = Process.get(@cache)
    assert Reaching.sources(instructions(first), 2, {:x, 0}) == [1]
  end

  defp function(module, value) do
    {:function, :f, 0, 0,
     [
       {:func_info, {:atom, module}, {:atom, :f}, 0},
       {:move, {:literal, {value}}, {:x, 0}},
       :return
     ]}
  end

  defp instructions({:function, _, _, _, instrs}), do: instrs

  defp installed_solution do
    {_module, functions} = Process.get(@cache)
    [[{_instrs, solution} | _]] = Map.values(functions)
    solution
  end

  defp copy(term), do: term |> :erlang.term_to_binary() |> :erlang.binary_to_term()
end
