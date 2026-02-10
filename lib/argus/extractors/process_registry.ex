defmodule Argus.Extractors.ProcessRegistry do
  @moduledoc """
  Process registry and naming extractor.

  Detects process name registration, Registry operations, `{:via, ...}` tuple
  construction, and `Process.whereis/1` calls. Enriches the existing OTP
  analysis suite with naming information to catch registration collisions,
  TOCTOU races on `whereis`, and unreachable named processes.

  ## Emitted facts

  - `process_register(id, func, name, method)` — direct registration and GenServer `name:` option
  - `registry_op(id, func, registry, op, key)` — `Registry.register/lookup/dispatch`
  - `via_tuple(id, func, registry, key)` — `{:via, Registry, {reg, key}}` tuple construction
  - `whereis_call(id, func, name)` — `Process.whereis/1`, `:erlang.whereis/1`
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers, only: [add_fact: 3, match_remote_call: 1, resolve_register: 3]

  alias Argus.Normalize

  # Registry operations to detect, mapped to arity.
  @registry_ops [
    {:register, 3},
    {:lookup, 2},
    {:dispatch, 3},
    {:dispatch, 4},
    {:unregister, 2},
    {:unregister_match, 3},
    {:match, 3},
    {:keys, 2},
    {:values, 2},
    {:count, 1},
    {:count_match, 3},
    {:select, 2},
    {:meta, 2},
    {:put_meta, 3}
  ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Emitter.facts()
  def extract(module_data) do
    mod = module_data.module
    functions = module_data.functions

    Enum.reduce(functions, %{}, fn {:function, name, arity, _entry, instrs}, facts ->
      func_id = Normalize.func_id(mod, name, arity)
      scan_instructions(facts, func_id, instrs)
    end)
  end

  defp scan_instructions(facts, func_id, instrs) do
    facts
    |> scan_remote_calls(func_id, instrs)
    |> scan_via_tuples(func_id, instrs)
  end

  defp scan_remote_calls(facts, func_id, instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn {instr, idx}, acc ->
      case match_remote_call(instr) do
        # Process.register/2 — Process.register(pid, name), name is x1.
        {:ok, Process, :register, 2} ->
          id = "#{func_id}##{idx}"
          name = resolve_name(instrs, idx, {:x, 1})
          add_fact(acc, :process_register, [id, func_id, name, "register"])

        # :erlang.register/2 — :erlang.register(name, pid), name is x0.
        {:ok, :erlang, :register, 2} ->
          id = "#{func_id}##{idx}"
          name = resolve_name(instrs, idx, {:x, 0})
          add_fact(acc, :process_register, [id, func_id, name, "register"])

        # GenServer.start_link/3 with name option.
        {:ok, GenServer, :start_link, 3} ->
          maybe_named_start(acc, func_id, instrs, idx, "start_link")

        {:ok, GenServer, :start, 3} ->
          maybe_named_start(acc, func_id, instrs, idx, "start")

        {:ok, :gen_server, :start_link, 4} ->
          maybe_named_start_erlang(acc, func_id, instrs, idx, "start_link")

        {:ok, :gen_server, :start, 4} ->
          maybe_named_start_erlang(acc, func_id, instrs, idx, "start")

        # Registry operations.
        {:ok, Registry, func, arity} ->
          maybe_registry_op(acc, func_id, instrs, idx, func, arity)

        # Process.whereis/1.
        {:ok, Process, :whereis, 1} ->
          id = "#{func_id}##{idx}"
          name = resolve_name(instrs, idx, {:x, 0})
          add_fact(acc, :whereis_call, [id, func_id, name])

        # :erlang.whereis/1.
        {:ok, :erlang, :whereis, 1} ->
          id = "#{func_id}##{idx}"
          name = resolve_name(instrs, idx, {:x, 0})
          add_fact(acc, :whereis_call, [id, func_id, name])

        _ ->
          acc
      end
    end)
  end

  # Scan for {:via, Registry, {reg, key}} tuple construction.
  defp scan_via_tuples(facts, func_id, instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn
      {{:put_tuple2, _, {:list, [{:atom, :via}, _, _] = elements}}, idx}, acc ->
        maybe_via_tuple(acc, func_id, instrs, idx, elements)

      {{:move, {:literal, {:via, registry, {reg, key}}}, _}, idx}, acc
      when is_atom(registry) and is_atom(reg) ->
        id = "#{func_id}##{idx}"
        add_fact(acc, :via_tuple, [id, func_id, inspect(reg), inspect(key)])

      _, acc ->
        acc
    end)
  end

  defp maybe_via_tuple(facts, func_id, instrs, idx, [{:atom, :via}, reg_op, key_op]) do
    id = "#{func_id}##{idx}"

    registry =
      case reg_op do
        {:atom, mod} -> inspect(mod)
        {:x, _} = r -> resolve_name(instrs, idx, r)
        {:y, _} = r -> resolve_name(instrs, idx, r)
        _ -> "dynamic"
      end

    key =
      case key_op do
        {:atom, k} -> inspect(k)
        {:literal, {_reg, k}} when is_atom(k) -> inspect(k)
        {:x, _} = r -> resolve_name(instrs, idx, r)
        {:y, _} = r -> resolve_name(instrs, idx, r)
        _ -> "dynamic"
      end

    add_fact(facts, :via_tuple, [id, func_id, registry, key])
  end

  # GenServer.start_link(mod, args, name: Name) — name in options keyword list (x2).
  defp maybe_named_start(facts, func_id, instrs, idx, method) do
    case resolve_register(instrs, idx, {:x, 2}) do
      {:ok, opts} when is_list(opts) ->
        case Keyword.get(opts, :name) do
          nil ->
            facts

          name when is_atom(name) ->
            id = "#{func_id}##{idx}"
            add_fact(facts, :process_register, [id, func_id, inspect(name), method])

          {:via, _reg, {reg_mod, key}} when is_atom(reg_mod) ->
            id = "#{func_id}##{idx}"
            add_fact(facts, :via_tuple, [id, func_id, inspect(reg_mod), inspect(key)])

          _ ->
            facts
        end

      _ ->
        facts
    end
  end

  # Erlang-style :gen_server.start_link({:local, Name}, mod, args, opts).
  defp maybe_named_start_erlang(facts, func_id, instrs, idx, method) do
    case resolve_register(instrs, idx, {:x, 0}) do
      {:ok, {:local, name}} when is_atom(name) ->
        id = "#{func_id}##{idx}"
        add_fact(facts, :process_register, [id, func_id, inspect(name), method])

      {:ok, {:global, name}} when is_atom(name) ->
        id = "#{func_id}##{idx}"
        add_fact(facts, :process_register, [id, func_id, inspect(name), method])

      _ ->
        facts
    end
  end

  defp maybe_registry_op(facts, func_id, instrs, idx, func, arity) do
    if {func, arity} in @registry_ops do
      id = "#{func_id}##{idx}"
      registry = resolve_name(instrs, idx, {:x, 0})

      key =
        case func do
          # register/3: registry, key, value — key is x1.
          :register -> resolve_name(instrs, idx, {:x, 1})
          # lookup/2: registry, key — key is x1.
          :lookup -> resolve_name(instrs, idx, {:x, 1})
          # dispatch/3,4: registry, key, ... — key is x1.
          :dispatch -> resolve_name(instrs, idx, {:x, 1})
          # unregister/2: registry, key — key is x1.
          :unregister -> resolve_name(instrs, idx, {:x, 1})
          # Other ops: key extraction varies; use dynamic.
          _ -> "dynamic"
        end

      add_fact(facts, :registry_op, [id, func_id, registry, to_string(func), key])
    else
      facts
    end
  end

  defp resolve_name(instrs, idx, register) do
    case resolve_register(instrs, idx, register) do
      {:ok, atom} when is_atom(atom) -> inspect(atom)
      {:ok, val} when is_binary(val) -> val
      _ -> "dynamic"
    end
  end
end
