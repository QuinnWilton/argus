defmodule Argus.FlowLog.PoolTest do
  @moduledoc """
  An engine lives as long as its owner: it stops when the owner exits,
  in use or not, and never otherwise while in use, not even to make
  room under the cap. An engine whose use failed, or whose user exited
  holding it, stops.

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
    %{start: [executable: built.executable, args: built.args, digest: built.digest, workers: 1]}
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

  # A process standing in for a database, alive until told to stop.
  defp owner, do: spawn(fn -> receive(do: (:stop -> :ok)) end)

  test "an owner's engines stop when it exits, and only its own",
       %{peer: peer, start: start} do
    Peer.run(peer, fn ->
      starts = fn -> {:ok, start} end
      {gone, kept} = {owner(), owner()}
      {:ok, a} = Pool.with_engine(:a, gone, starts, &{:ok, &1})
      {:ok, b} = Pool.with_engine(:b, gone, starts, &{:ok, &1})
      {:ok, c} = Pool.with_engine(:c, kept, starts, &{:ok, &1})

      # Unused, they are kept for as long as their owner is alive.
      Process.sleep(200)
      assert Enum.sort(Pool.keys()) == [:a, :b, :c]

      send(gone, :stop)
      assert eventually(fn -> Pool.keys() == [:c] end)
      refute Process.alive?(a)
      refute Process.alive?(b)
      assert Process.alive?(c)
    end)
  end

  test "an owner that keeps no engine has each stop as its use returns",
       %{peer: peer, start: start} do
    Peer.run(peer, fn ->
      starts = fn -> {:ok, start} end
      {once, kept} = {owner(), owner()}
      :ok = Pool.keep(once, false)
      {:ok, a} = Pool.with_engine(:a, once, starts, &{:ok, &1})
      {:ok, c} = Pool.with_engine(:c, kept, starts, &{:ok, &1})

      assert eventually(fn -> Pool.keys() == [:c] end)
      refute Process.alive?(a)
      assert Process.alive?(c)

      # The next use starts another, and keeping is the owner's to set again.
      :ok = Pool.keep(once, true)
      {:ok, b} = Pool.with_engine(:a, once, starts, &{:ok, &1})
      assert b != a
      Process.sleep(200)
      assert Enum.sort(Pool.keys()) == [:a, :c]
    end)
  end

  test "an owner's setting goes with it", %{peer: peer, start: start} do
    Peer.run(peer, fn ->
      once = owner()
      :ok = Pool.keep(once, false)
      send(once, :stop)
      assert eventually(fn -> not Process.alive?(once) end)

      # Another owner keeps its engines, as an owner does by default.
      {:ok, _} = Pool.with_engine(:a, owner(), fn -> {:ok, start} end, &{:ok, &1})
      Process.sleep(200)
      assert Pool.keys() == [:a]
      assert :sys.get_state(Pool).unkept == %{}
    end)
  end

  test "an owner that exits stops its engine mid-use", %{peer: peer, start: start} do
    Peer.run(peer, fn ->
      parent = self()
      db = owner()

      spawn(fn ->
        Pool.with_engine(:a, db, fn -> {:ok, start} end, fn engine ->
          send(parent, {:engine, engine})
          Process.sleep(:infinity)
        end)
      end)

      assert_receive {:engine, engine}, 30_000
      send(db, :stop)
      assert eventually(fn -> not Process.alive?(engine) end)
      assert Pool.keys() == []
    end)
  end

  test "the cap stops the least recently used engines, never one in use",
       %{peer: peer, start: start} do
    Peer.run(peer, fn ->
      limits([{"ARGUS_FLOWLOG_ENGINES", "1"}])
      starts = fn -> {:ok, start} end
      db = owner()

      # :a is in use while :b starts: the pool holds both, over its cap.
      {:ok, {a, b}} =
        Pool.with_engine(:a, db, starts, fn a ->
          Pool.with_engine(:b, db, starts, fn b ->
            assert Enum.sort(Pool.keys()) == [:a, :b]
            {:ok, {a, b}}
          end)
        end)

      # Neither is in use when :c starts: both stop to bring it under.
      {:ok, _} = Pool.with_engine(:c, db, starts, &{:ok, &1})
      assert Pool.keys() == [:c]
      refute Process.alive?(a)
      refute Process.alive?(b)
    end)
  end

  test "a use that fails stops its engine, and the next use starts another",
       %{peer: peer, start: start} do
    Peer.run(peer, fn ->
      starts = fn -> {:ok, start} end
      db = owner()
      {:ok, first} = Pool.with_engine(:a, db, starts, &{:ok, &1})
      assert {:ok, ^first} = Pool.with_engine(:a, db, starts, &{:ok, &1})

      assert {:error, :failed} = Pool.with_engine(:a, db, starts, fn _ -> {:error, :failed} end)
      refute Process.alive?(first)
      assert Pool.keys() == []

      assert_raise RuntimeError, "raised", fn ->
        Pool.with_engine(:a, db, starts, fn _ -> raise "raised" end)
      end

      assert Pool.keys() == []
      {:ok, second} = Pool.with_engine(:a, db, starts, &{:ok, &1})
      assert second != first
    end)
  end

  test "a user that exits holding an engine stops it", %{peer: peer, start: start} do
    Peer.run(peer, fn ->
      parent = self()
      db = owner()

      user =
        spawn(fn ->
          Pool.with_engine(:a, db, fn -> {:ok, start} end, fn engine ->
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
