defmodule Argus.Test.Fixtures.RemotePid do
  @moduledoc false
  # Local-only BIFs (Process.alive?/1, Process.info/1,2) handed a pid
  # that may be another node's (failure's remote_pid_probe).

  # aprs.me's leader election before 37c9ac7: the :global holder of the
  # name is usually on another node, and alive? runs before the node
  # check that comes after it.
  defmodule GlobalAlive do
    @moduledoc false
    def cleanup(name) do
      case :global.whereis_name(name) do
        :undefined ->
          :ok

        pid when is_pid(pid) ->
          if Process.alive?(pid) and node(pid) in [node() | Node.list()],
            do: :ok,
            else: :global.unregister_name(name)
      end
    end
  end

  # The fix: alive? only where the pid is this node's, rpc elsewhere.
  defmodule NodeGuarded do
    @moduledoc false
    def cleanup(name) do
      case :global.whereis_name(name) do
        :undefined ->
          :ok

        pid when is_pid(pid) ->
          if node(pid) == node() do
            Process.alive?(pid)
          else
            :erpc.call(node(pid), Process, :alive?, [pid], 1_000)
          end
      end
    end

    # A node test whose arms join before the probe decides nothing.
    def asked_before(name) do
      pid = :global.whereis_name(name)
      where = if node(pid) == node(), do: :here, else: :there
      {where, Process.alive?(pid)}
    end

    # The test on the wrong arm: these probes run exactly when the pid
    # is another node's.
    def else_arm(name) do
      pid = :global.whereis_name(name)
      if node(pid) == node(), do: :local, else: Process.alive?(pid)
    end

    def unless_local(name) do
      pid = :global.whereis_name(name)
      unless node(pid) == node(), do: Process.alive?(pid)
    end

    def when_remote(name) do
      pid = :global.whereis_name(name)
      if node(pid) != node(), do: Process.info(pid, :memory)
    end

    # An inequality whose other arm, where the nodes are equal, probes.
    def inequality_else(name) do
      pid = :global.whereis_name(name)

      if node(pid) != node(),
        do: :erpc.call(node(pid), Process, :alive?, [pid], 1_000),
        else: Process.alive?(pid)
    end

    # A test of another pid's node guards nothing about this one.
    def other_node(name, other) do
      pid = :global.whereis_name(name)

      if node(other) == node() do
        Process.alive?(pid)
      else
        false
      end
    end
  end

  # A rescue of the ArgumentError takes the remote pid's badarg; a rescue
  # of something else does not.
  defmodule Rescued do
    @moduledoc false
    def alive?(name) do
      pid = :global.whereis_name(name)

      try do
        Process.alive?(pid)
      rescue
        ArgumentError -> false
      end
    end

    # A rescue that re-raises, an `after`, and a rescue around another
    # call take nothing the probe raises.
    def reraises(name) do
      pid = :global.whereis_name(name)

      try do
        Process.alive?(pid)
      rescue
        e in ArgumentError -> reraise e, __STACKTRACE__
      end
    end

    def after_only(name) do
      pid = :global.whereis_name(name)

      try do
        Process.alive?(pid)
      after
        :global.unregister_name(name)
      end
    end

    def other_call(name) do
      pid = :global.whereis_name(name)

      checked =
        try do
          :global.whereis_name(name)
        rescue
          ArgumentError -> nil
        end

      {checked, Process.alive?(pid)}
    end

    def wrong_rescue(name) do
      pid = :global.whereis_name(name)

      try do
        Process.alive?(pid)
      rescue
        KeyError -> false
      end
    end
  end

  # aprs.me before 9212088: a :global conflict resolver is handed the two
  # holders of a name on two nodes.
  defmodule Resolver do
    @moduledoc false
    def register(name), do: :global.register_name(name, self(), &resolve_conflict/3)

    defp resolve_conflict(_name, pid1, pid2) do
      info1 = Process.info(pid1, [:message_queue_len])
      info2 = Process.info(pid2, [:message_queue_len])
      if info1 <= info2, do: pid1, else: pid2
    end

    # Choosing by node, as the fix does, asks no process anything.
    def register_by_node(name), do: :global.register_name(name, self(), &by_node/3)

    defp by_node(_name, pid1, pid2), do: if(node(pid1) <= node(pid2), do: pid1, else: pid2)
  end

  defmodule SynHandler do
    @moduledoc false
    @behaviour :syn_event_handler

    @impl true
    def resolve_registry_conflict(_scope, _name, {pid1, _meta1, _time1}, {pid2, _meta2, _time2}) do
      if Process.alive?(pid1), do: pid1, else: pid2
    end
  end

  # A process group's members are every node's.
  defmodule Members do
    @moduledoc false
    def live(group), do: Enum.filter(:pg.get_members(:scope, group), &Process.alive?/1)

    def sizes(group) do
      for pid <- :pg.get_members(group), do: Process.info(pid, :message_queue_len)
    end

    # This node's members only.
    def local(group), do: Enum.filter(:pg.get_local_members(group), &Process.alive?/1)
  end

  # A helper that probes its parameter: the finding is the caller's, at
  # its call into the helper; a caller with a local pid is quiet.
  defmodule Helper do
    @moduledoc false
    def leader_alive?(name) do
      pid = :global.whereis_name(name)
      alive?(pid)
    end

    def local_alive?(name), do: alive?(Process.whereis(name))

    # A try around the call into the helper takes the badarg.
    def guarded(name) do
      pid = :global.whereis_name(name)

      try do
        alive?(pid)
      rescue
        _ -> false
      end
    end

    defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
    defp alive?(_), do: false
  end

  # phoenix_live_dashboard before 57e8a1f: a process's links may be
  # another node's, and the app tree asked each for its group leader.
  defmodule Links do
    @moduledoc false
    def children(pid, master) do
      case Process.info(pid, :links) do
        {:links, children} ->
          children
          |> Enum.reverse()
          |> Enum.flat_map(fn child -> if has_leader?(child, master), do: [child], else: [] end)

        _ ->
          []
      end
    end

    defp has_leader?(pid, gl), do: Process.info(pid, :group_leader) == {:group_leader, gl}

    # The fix: this node's pids only.
    def local_children(pid, master) do
      case Process.info(pid, :links) do
        {:links, children} -> Enum.filter(children, &local_leader?(&1, master))
        _ -> []
      end
    end

    defp local_leader?(pid, gl),
      do: node(pid) == node() and Process.info(pid, :group_leader) == {:group_leader, gl}
  end

  # A cluster-wide name through GenServer.whereis/1, and a lookup a
  # helper returns; a node-local registry's is quiet.
  defmodule Names do
    @moduledoc false
    def global_info(name), do: Process.info(GenServer.whereis({:global, name}), :memory)

    def leader_info, do: Process.info(leader(), :message_queue_len)

    defp leader, do: :global.whereis_name(:leader)

    def local_info(key),
      do: Process.info(GenServer.whereis({:via, Registry, {__MODULE__.Registry, key}}), :memory)
  end
end
