defmodule Argus.Extractors.ProcessRegistry do
  @moduledoc """
  Process registry and naming extractor.

  Detects process name registration, Registry operations, `{:via, ...}` tuple
  construction, and `Process.whereis/1` calls. Enriches the existing OTP
  analysis suite with naming information to catch registration collisions,
  TOCTOU races on `whereis`, and unreachable named processes.

  ## Emitted facts

  - `process_register(id, func, name, method)` — direct registration and GenServer `name:` option
  - `named_process(mod, name)` — module-level: a process implemented by `mod` is registered as `name`
  - `whereis_call(id, func, name)` — `Process.whereis/1`, `:erlang.whereis/1`
  """

  @behaviour Argus.Extractor

  alias Argus.InstrId

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      each_remote_call: 3,
      resolve_register: 3,
      track_dynamic: 5,
      track_imprecision: 5
    ]

  # Registry operations to detect, mapped to arity.
  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod_str = inspect(module_data.module)

    each_remote_call(module_data, %{}, fn facts, ctx, mfa ->
      register_call(facts, mod_str, ctx, mfa)
    end)
  end

  defp register_call(facts, mod_str, ctx, mfa) do
    case mfa do
      # Process.register/2 — Process.register(pid, name), name is x1.
      {Process, :register, 2} ->
        emit_register(facts, mod_str, ctx, {:x, 1}, "register")

      # :erlang.register/2 — :erlang.register(name, pid), name is x0.
      {:erlang, :register, 2} ->
        emit_register(facts, mod_str, ctx, {:x, 0}, "register")

      {GenServer, :start_link, 3} ->
        maybe_named_start(facts, ctx, "start_link")

      {GenServer, :start, 3} ->
        maybe_named_start(facts, ctx, "start")

      {:gen_server, :start_link, 4} ->
        maybe_named_start_erlang(facts, ctx, "start_link")

      {:gen_server, :start, 4} ->
        maybe_named_start_erlang(facts, ctx, "start")

      {Process, :whereis, 1} ->
        emit_whereis(facts, ctx)

      {:erlang, :whereis, 1} ->
        emit_whereis(facts, ctx)

      _ ->
        facts
    end
  end

  defp emit_register(facts, mod_str, ctx, name_reg, method) do
    id = InstrId.mint(ctx.func_id, ctx.idx)
    name = resolve_name(ctx.instrs, ctx.idx, name_reg)

    facts
    |> track_dynamic(name, ctx, :process_register_name, :process_register)
    |> add_fact(:process_register, [id, ctx.func_id, name, method])
    |> maybe_emit_named_process(mod_str, name)
  end

  # Direct register/2 calls inside a module's own code typically register
  # `self()` under a name — so the enclosing module owns the name. We
  # can't statically prove the registered pid is `self()`, but the
  # convention is strong enough in practice (Process.register(self(), :foo)
  # is the dominant pattern) that emitting named_process here is more
  # useful than skipping it.
  defp maybe_emit_named_process(facts, _mod_str, "dynamic"), do: facts

  defp maybe_emit_named_process(facts, mod_str, name) do
    add_fact(facts, :named_process, [mod_str, name])
  end

  defp emit_whereis(facts, ctx) do
    id = InstrId.mint(ctx.func_id, ctx.idx)
    name = resolve_name(ctx.instrs, ctx.idx, {:x, 0})

    facts
    |> track_dynamic(name, ctx, :whereis_target, :whereis_call)
    |> add_fact(:whereis_call, [id, ctx.func_id, name])
  end

  # GenServer.start_link(mod, args, name: Name) — name in options keyword list (x2).
  # The first argument (x0) is the module being started; if it resolves to a
  # literal atom we can also emit named_process(mod, name).
  #
  # For tail-called start_links where options don't resolve, suppress the
  # imprecision — the wrapper is just forwarding args from its caller, so
  # the name registration (if any) should be attributed to the call site
  # that builds the options, not this intermediary.
  defp maybe_named_start(facts, ctx, method) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 2}) do
      {:ok, opts} when is_list(opts) ->
        case Keyword.get(opts, :name) do
          nil ->
            facts

          # The options list resolved, but the name VALUE inside it is the
          # placeholder — `name: opts[:name]` and friends. Inspecting it
          # would forge a ":dynamic" name that evades the dynamic filters.
          :dynamic ->
            track_imprecision(facts, ctx, :gen_server_start_name, :process_register, :dynamic)

          name when is_atom(name) ->
            id = InstrId.mint(ctx.func_id, ctx.idx)

            facts
            |> add_fact(:process_register, [id, ctx.func_id, inspect(name), method])
            |> maybe_emit_named_process_for_start(ctx, inspect(name))

          # A via-registered name is the registry's, not a process_register.
          {:via, _reg, _key} ->
            facts

          _ ->
            track_imprecision(facts, ctx, :gen_server_start_name, :process_register, :skipped)
        end

      _ ->
        # Options didn't resolve. If this is a tail call, the wrapper is
        # just forwarding — skip rather than emit imprecision.
        if tail_call?(ctx.instrs, ctx.idx) do
          facts
        else
          track_imprecision(facts, ctx, :gen_server_start_name, :process_register, :skipped)
        end
    end
  end

  # Erlang-style :gen_server.start_link({:local, Name}, mod, args, opts).
  # The module is x1 in the Erlang shape; resolve it to enrich named_process.
  defp maybe_named_start_erlang(facts, ctx, method) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, {kind, name}}
      when kind in [:local, :global] and is_atom(name) and name != :dynamic ->
        id = InstrId.mint(ctx.func_id, ctx.idx)

        facts
        |> add_fact(:process_register, [id, ctx.func_id, inspect(name), method])
        |> maybe_emit_named_process_for_erlang_start(ctx, inspect(name))

      _ ->
        if tail_call?(ctx.instrs, ctx.idx) do
          facts
        else
          track_imprecision(facts, ctx, :gen_server_start_name, :process_register, :skipped)
        end
    end
  end

  # Check whether the instruction at `idx` is a tail call variant.
  defp tail_call?(instrs, idx) do
    case Enum.at(instrs, idx) do
      {:call_ext_only, _, _} -> true
      {:call_ext_last, _, _, _} -> true
      _ -> false
    end
  end

  # For GenServer.start_link, the module being started is x0.
  defp maybe_emit_named_process_for_start(facts, ctx, name) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, mod} when is_atom(mod) -> add_fact(facts, :named_process, [inspect(mod), name])
      _ -> facts
    end
  end

  # For :gen_server.start_link({:local, name}, mod, ...), the module is x1.
  defp maybe_emit_named_process_for_erlang_start(facts, ctx, name) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 1}) do
      {:ok, mod} when is_atom(mod) -> add_fact(facts, :named_process, [inspect(mod), name])
      _ -> facts
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
