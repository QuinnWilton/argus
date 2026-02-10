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
