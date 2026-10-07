defmodule Argus.FlowLog.PoolTest do
  @moduledoc """
  The pool never stops an engine in use: not when it outlives the idle
  time, not to make room under the cap. An engine whose use failed, or
  whose user exited holding it, stops.

  The pool reads its limits once per VM, as it starts: each test runs in
  a peer of its own (`Argus.Test.Peer`), its limits set before first use.
  """
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.FlowLog.Pool
  alias Argus.Test.Peer

  @moduletag :flowlog
  @moduletag :tmp_dir

  @program """
  .decl edge(a: symbol, b: symbol) mutable
  .input edge(filename="edge.facts")
  .decl node(a: symbol)
  .output node(filename="node.facts")
  node(a) :- edge(a, _).
  """

  setup_all do
    dir = Path.join(System.tmp_dir!(), "argus_pool_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "pool.dl")
    File.write!(path, @program)
    {:ok, built} = Argus.FlowLog.engine(path, progress: false)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{start: [executable: built.executable, digest: built.digest, workers: 1]}
  end

  setup do
    %{peer: Peer.start!()}
  end

  # In the peer: the pool's limits, set before its first use.
  defp limits(env), do: Enum.each(env, fn {name, value} -> System.put_env(name, value) end)

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  test "an engine in use outlives the idle time, and stops once unused",
       %{peer: peer, start: start} do
    Peer.run(peer, fn ->
      limits([{"ARGUS_FLOWLOG_IDLE_MS", "100"}])

      {:ok, engine} =
        Pool.with_engine(:a, fn -> {:ok, start} end, fn engine ->
          Process.sleep(400)
          assert Process.alive?(engine)
          assert Pool.keys() == [:a]
          {:ok, engine}
        end)

      assert eventually(fn -> Pool.keys() == [] end)
      refute Process.alive?(engine)
    end)
  end

  test "the cap stops the least recently used engines, never one in use",
       %{peer: peer, start: start} do
    Peer.run(peer, fn ->
      limits([{"ARGUS_FLOWLOG_ENGINES", "1"}])
      starts = fn -> {:ok, start} end

      # :a is in use while :b starts: the pool holds both, over its cap.
      {:ok, {a, b}} =
        Pool.with_engine(:a, starts, fn a ->
          Pool.with_engine(:b, starts, fn b ->
            assert Enum.sort(Pool.keys()) == [:a, :b]
            {:ok, {a, b}}
          end)
        end)

      # Neither is in use when :c starts: both stop to bring it under.
      {:ok, _} = Pool.with_engine(:c, starts, &{:ok, &1})
      assert Pool.keys() == [:c]
      refute Process.alive?(a)
      refute Process.alive?(b)
    end)
  end

  test "a use that fails stops its engine, and the next use starts another",
       %{peer: peer, start: start} do
    Peer.run(peer, fn ->
      starts = fn -> {:ok, start} end
      {:ok, first} = Pool.with_engine(:a, starts, &{:ok, &1})
      assert {:ok, ^first} = Pool.with_engine(:a, starts, &{:ok, &1})

      assert {:error, :failed} = Pool.with_engine(:a, starts, fn _ -> {:error, :failed} end)
      refute Process.alive?(first)
      assert Pool.keys() == []

      assert_raise RuntimeError, "raised", fn ->
        Pool.with_engine(:a, starts, fn _ -> raise "raised" end)
      end

      assert Pool.keys() == []
      {:ok, second} = Pool.with_engine(:a, starts, &{:ok, &1})
      assert second != first
    end)
  end

  test "a user that exits holding an engine stops it", %{peer: peer, start: start} do
    Peer.run(peer, fn ->
      parent = self()

      user =
        spawn(fn ->
          Pool.with_engine(:a, fn -> {:ok, start} end, fn engine ->
            send(parent, {:engine, engine})
            Process.sleep(:infinity)
          end)
        end)

      assert_receive {:engine, engine}, 30_000
      Process.exit(user, :kill)
      assert eventually(fn -> not Process.alive?(engine) end)
      assert Pool.keys() == []
    end)
  end
end
