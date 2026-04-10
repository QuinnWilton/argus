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

  import Argus.Extractor.Helpers,
    only: [add_fact: 3, match_remote_call: 1, resolve_register: 3, scan_functions: 4]

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
    scan_functions(module_data.module, module_data.functions, %{}, fn facts, ctx, instr ->
      facts
      |> maybe_register_call(ctx, instr)
      |> maybe_via_tuple(ctx, instr)
    end)
  end

  defp maybe_register_call(facts, ctx, instr) do
    case match_remote_call(instr) do
      # Process.register/2 — Process.register(pid, name), name is x1.
      {:ok, Process, :register, 2} ->
        emit_register(facts, ctx, {:x, 1}, "register")

      # :erlang.register/2 — :erlang.register(name, pid), name is x0.
      {:ok, :erlang, :register, 2} ->
        emit_register(facts, ctx, {:x, 0}, "register")

      {:ok, GenServer, :start_link, 3} -> maybe_named_start(facts, ctx, "start_link")
      {:ok, GenServer, :start, 3} -> maybe_named_start(facts, ctx, "start")
      {:ok, :gen_server, :start_link, 4} -> maybe_named_start_erlang(facts, ctx, "start_link")
      {:ok, :gen_server, :start, 4} -> maybe_named_start_erlang(facts, ctx, "start")
      {:ok, Registry, func, arity} -> maybe_registry_op(facts, ctx, func, arity)
      {:ok, Process, :whereis, 1} -> emit_whereis(facts, ctx)
      {:ok, :erlang, :whereis, 1} -> emit_whereis(facts, ctx)
      _ -> facts
    end
  end

  defp emit_register(facts, ctx, name_reg, method) do
    id = "#{ctx.func_id}##{ctx.idx}"
    name = resolve_name(ctx.instrs, ctx.idx, name_reg)
    add_fact(facts, :process_register, [id, ctx.func_id, name, method])
  end

  defp emit_whereis(facts, ctx) do
    id = "#{ctx.func_id}##{ctx.idx}"
    name = resolve_name(ctx.instrs, ctx.idx, {:x, 0})
    add_fact(facts, :whereis_call, [id, ctx.func_id, name])
  end

  # Scan for {:via, Registry, {reg, key}} tuple construction patterns.
  defp maybe_via_tuple(facts, ctx, {:put_tuple2, _, {:list, [{:atom, :via}, reg_op, key_op]}}) do
    id = "#{ctx.func_id}##{ctx.idx}"

    registry =
      case reg_op do
        {:atom, mod} -> inspect(mod)
        {:x, _} = r -> resolve_name(ctx.instrs, ctx.idx, r)
        {:y, _} = r -> resolve_name(ctx.instrs, ctx.idx, r)
        _ -> "dynamic"
      end

    key =
      case key_op do
        {:atom, k} -> inspect(k)
        {:literal, {_reg, k}} when is_atom(k) -> inspect(k)
        {:x, _} = r -> resolve_name(ctx.instrs, ctx.idx, r)
        {:y, _} = r -> resolve_name(ctx.instrs, ctx.idx, r)
        _ -> "dynamic"
      end

    add_fact(facts, :via_tuple, [id, ctx.func_id, registry, key])
  end

  defp maybe_via_tuple(facts, ctx, {:move, {:literal, {:via, registry, {reg, key}}}, _})
       when is_atom(registry) and is_atom(reg) do
    id = "#{ctx.func_id}##{ctx.idx}"
    add_fact(facts, :via_tuple, [id, ctx.func_id, inspect(reg), inspect(key)])
  end

  defp maybe_via_tuple(facts, _ctx, _instr), do: facts

  # GenServer.start_link(mod, args, name: Name) — name in options keyword list (x2).
  defp maybe_named_start(facts, ctx, method) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 2}) do
      {:ok, opts} when is_list(opts) ->
        case Keyword.get(opts, :name) do
          nil ->
            facts

          name when is_atom(name) ->
            id = "#{ctx.func_id}##{ctx.idx}"
            add_fact(facts, :process_register, [id, ctx.func_id, inspect(name), method])

          {:via, _reg, {reg_mod, key}} when is_atom(reg_mod) ->
            id = "#{ctx.func_id}##{ctx.idx}"
            add_fact(facts, :via_tuple, [id, ctx.func_id, inspect(reg_mod), inspect(key)])

          _ ->
            facts
        end

      _ ->
        facts
    end
  end

  # Erlang-style :gen_server.start_link({:local, Name}, mod, args, opts).
  defp maybe_named_start_erlang(facts, ctx, method) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, {kind, name}} when kind in [:local, :global] and is_atom(name) ->
        id = "#{ctx.func_id}##{ctx.idx}"
        add_fact(facts, :process_register, [id, ctx.func_id, inspect(name), method])

      _ ->
        facts
    end
  end

  defp maybe_registry_op(facts, ctx, func, arity) do
    if {func, arity} in @registry_ops do
      id = "#{ctx.func_id}##{ctx.idx}"
      registry = resolve_name(ctx.instrs, ctx.idx, {:x, 0})

      key =
        case func do
          op when op in [:register, :lookup, :dispatch, :unregister] ->
            resolve_name(ctx.instrs, ctx.idx, {:x, 1})

          _ ->
            "dynamic"
        end

      add_fact(facts, :registry_op, [id, ctx.func_id, registry, to_string(func), key])
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
