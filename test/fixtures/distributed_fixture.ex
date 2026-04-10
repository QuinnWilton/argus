defmodule Argus.Test.Fixtures.RpcCaller do
  @moduledoc false

  def call_no_timeout(node, mod, func, args) do
    :rpc.call(node, mod, func, args)
  end

  def call_with_timeout(node, mod, func, args) do
    :rpc.call(node, mod, func, args, 5000)
  end

  def multicall(nodes, mod, func, args) do
    :rpc.multicall(nodes, mod, func, args)
  end
end

defmodule Argus.Test.Fixtures.GlobalRegisterModule do
  @moduledoc false

  def register(name, pid) do
    :global.register_name(name, pid)
  end

  def register_with_resolve(name, pid) do
    :global.register_name(name, pid, &:global.random_exit_name/3)
  end
end

defmodule Argus.Test.Fixtures.GlobalLockModule do
  @moduledoc false

  # :global.set_lock/2 — defaults to :infinity retries → blocking.
  def lock_default(key, nodes), do: :global.set_lock({key, self()}, nodes)

  # :global.set_lock/3 with explicit 0 retries → non-blocking.
  def try_lock_once(key, nodes), do: :global.set_lock({key, self()}, nodes, 0)

  # :global.set_lock/3 with explicit infinity retries → blocking.
  def lock_infinity(key, nodes), do: :global.set_lock({key, self()}, nodes, :infinity)

  # :global.set_lock/3 with positive integer retries → blocking with backoff.
  def lock_with_retries(key, nodes), do: :global.set_lock({key, self()}, nodes, 5)

  def trans_default(key, fun), do: :global.trans({key, self()}, fun)

  def trans_zero_retries(key, fun, nodes),
    do: :global.trans({key, self()}, fun, nodes, 0)

  def del(key, nodes), do: :global.del_lock({key, self()}, nodes)
  def whereis(name), do: :global.whereis_name(name)
end

defmodule Argus.Test.Fixtures.NodeOperationsModule do
  @moduledoc false

  def connect(node), do: Node.connect(node)
  def disconnect(node), do: Node.disconnect(node)
  def ping(node), do: Node.ping(node)
  def list_nodes, do: Node.list()
end

defmodule Argus.Test.Fixtures.MnesiaModule do
  @moduledoc false

  def read_in_transaction(table, key) do
    :mnesia.transaction(fn -> :mnesia.read(table, key) end)
  end

  def read_outside_transaction(table, key) do
    :mnesia.read(table, key)
  end

  def dirty_read(table, key) do
    :mnesia.dirty_read(table, key)
  end

  def write(table, record) do
    :mnesia.write(table, record, :write)
  end
end
