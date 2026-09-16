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
  - `whereis_call(id, func, name, checked)` — `Process.whereis/1`,
    `:erlang.whereis/1`; `checked` says whether the result is tested
    against nil before use
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
  def relations,
    do: [
      :named_process,
      :process_register,
      :whereis_call
    ]

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
    checked = if nil_checked?(ctx.instrs, ctx.idx), do: "checked", else: "unchecked"

    facts
    |> track_dynamic(name, ctx, :whereis_target, :whereis_call)
    |> add_fact(:whereis_call, [id, ctx.func_id, name, checked])
  end

  # The result lands in x0. Along the straight-line code after the call,
  # a comparison of it against nil/:undefined, a type test on it, or a
  # select over it that lists nil means the caller handles the
  # missing-process case; any other use of the value first, or reaching
  # a label, call or return, means it does not.
  @nil_atoms [{:atom, nil}, {:atom, :undefined}]
  @equality_tests [:is_eq_exact, :is_ne_exact, :is_eq, :is_ne]
  @type_tests [:is_atom, :is_pid, :is_port]

  defp nil_checked?(instrs, idx) do
    instrs |> Enum.drop(idx + 1) |> checked_walk([{:x, 0}])
  end

  defp checked_walk([], _regs), do: false
  defp checked_walk([{:line, _} | rest], regs), do: checked_walk(rest, regs)
  defp checked_walk([{:test_heap, _, _} | rest], regs), do: checked_walk(rest, regs)
  defp checked_walk([{:allocate, _, _} | rest], regs), do: checked_walk(rest, regs)
  defp checked_walk([{:init_yregs, _} | rest], regs), do: checked_walk(rest, regs)

  defp checked_walk([{:move, src, dst} | rest], regs) do
    src = strip_type(src)
    dst = strip_type(dst)

    cond do
      src in regs -> checked_walk(rest, Enum.uniq([dst | regs]))
      dst in regs -> checked_walk(rest, List.delete(regs, dst))
      true -> checked_walk(rest, regs)
    end
  end

  defp checked_walk([{:test, op, _fail, args} | _rest], regs) when op in @equality_tests do
    args = Enum.map(args, &strip_type/1)
    Enum.any?(args, &(&1 in regs)) and Enum.any?(args, &(&1 in @nil_atoms))
  end

  defp checked_walk([{:test, op, _fail, [reg | _]} | _rest], regs) when op in @type_tests do
    strip_type(reg) in regs
  end

  defp checked_walk([{:select_val, reg, _fail, {:list, cases}} | _rest], regs) do
    strip_type(reg) in regs and Enum.any?(cases, &(&1 in @nil_atoms))
  end

  defp checked_walk([instr | rest], regs) do
    if uses_register?(instr, regs), do: false, else: checked_walk(rest, regs)
  end

  defp uses_register?(term, regs) when is_tuple(term) do
    stripped = strip_type(term)

    if stripped in regs,
      do: true,
      else: term |> Tuple.to_list() |> Enum.any?(&uses_register?(&1, regs))
  end

  defp uses_register?(term, regs) when is_list(term),
    do: Enum.any?(term, &uses_register?(&1, regs))

  defp uses_register?(_term, _regs), do: false

  defp strip_type({:tr, reg, _type}), do: reg
  defp strip_type(other), do: other

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
