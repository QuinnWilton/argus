defmodule Argus.Extractors.ProcessRegistry do
  @moduledoc """
  Process registry and naming extractor.

  Detects process name registration, Registry operations, `{:via, ...}` tuple
  construction, and `Process.whereis/1` calls. Enriches the existing OTP
  analysis suite with naming information to catch registration collisions,
  TOCTOU races on `whereis`, and unreachable named processes.

  ## Emitted facts

  - `process_register(id, func, name, method)` — direct registration and the `name:`
    option of a GenServer or Agent start
  - `named_process(mod, name)` — module-level: a process implemented by `mod` is registered
    as `name`; for an Agent, which has no module of its own, the module that starts it
  - `name_lookup(id, func, api, scope, source, key, checked)` —
    `Process.whereis/1`, `:erlang.whereis/1` (`api` `whereis`, no scope)
    and `Registry.lookup/2` (`api` `registry_lookup`, `scope` the
    registry); `source`/`key` identify the name in the vocabulary of
    `Helpers.key_identity/3`; `checked` says whether the result is tested
    against nil (or `[]`) before use
  - `creating_op(id, func, api, scope, source, key)` — a call that claims
    a name or starts a process: `register`, `start_link`/`start` with a
    `name:`, `start_via` (`{:via, Registry, {scope, key}}`),
    `registry_register`, and `start_child`, whose name hides in the child
    spec (`source` `dynamic`)
  - `guarded_create(act, check)` — the creating op at `act` runs only
    because of a test on the result of the lookup at `check`, in the same
    function (`Argus.Extractor.Guard`)
  - `start_error_compared(func, atom)` — `:already_started` or
    `:already_registered` is compared anywhere in a function holding a
    creating op: the loser's outcome is taken. Over-approximate on
    purpose, so an unrelated comparison keeps the race rule quiet
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.Dispatch
  alias Argus.Extractor.Guard
  alias Argus.Extractor.Helpers
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      each_remote_call: 3,
      find_function: 3,
      key_identity: 3,
      keyword_value_register: 4,
      resolve_atom: 3,
      resolve_register: 3,
      track_dynamic: 5,
      track_imprecision: 5
    ]

  @impl true
  def relations,
    do: [
      :creating_op,
      :guarded_create,
      :name_lookup,
      :named_process,
      :process_register,
      :start_error_compared
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod_str = inspect(module_data.module)

    module_data
    |> each_remote_call(%{}, fn facts, ctx, mfa -> register_call(facts, mod_str, ctx, mfa) end)
    |> emit_guards(module_data)
  end

  # ── Lookup, then create ──────────────────────────────────────────

  @start_errors [:already_started, :already_registered]

  # Per function: every (lookup, create) pair where the create is decided
  # by a test on the lookup's result; and, for every function, the start
  # errors it compares against anywhere — the taker may be the creating
  # function's caller.
  defp emit_guards(facts, module_data) do
    lookups = sites_by_func(facts, :name_lookup)
    creates = sites_by_func(facts, :creating_op)

    facts =
      Enum.reduce(creates, facts, fn {func_id, create_idxs}, acc ->
        {name, arity} = Normalize.func_id_name_arity(func_id)

        case find_function(module_data.functions, String.to_existing_atom(name), arity) do
          nil ->
            acc

          instrs ->
            emit_guarded_creates(
              acc,
              module_data,
              func_id,
              instrs,
              Map.get(lookups, func_id, []),
              create_idxs
            )
        end
      end)

    Enum.reduce(module_data.functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      emit_start_errors(acc, Normalize.func_id(module_data.module, name, arity), instrs)
    end)
  end

  defp sites_by_func(facts, relation) do
    facts
    |> Map.get(relation, [])
    |> Enum.group_by(fn [_id, func | _] -> func end, fn [id | _] -> index_of(id) end)
  end

  defp index_of(id) do
    {:ok, %InstrId{idx: idx}} = InstrId.parse(id)
    idx
  end

  defp emit_guarded_creates(facts, _module_data, _func_id, _instrs, [], _creates), do: facts

  defp emit_guarded_creates(facts, module_data, func_id, instrs, lookups, creates) do
    {name, arity} = Normalize.func_id_name_arity(func_id)

    case Helpers.cfg(module_data, name, arity) do
      nil ->
        facts

      fun ->
        for check <- lookups,
            {:ok, test} <- [Guard.result_test(instrs, check)],
            act <- creates,
            Guard.decides?(fun, test, act),
            reduce: facts do
          acc ->
            add_fact(acc, :guarded_create, [
              InstrId.mint(func_id, act),
              InstrId.mint(func_id, check)
            ])
        end
    end
  end

  defp emit_start_errors(facts, func_id, instrs) do
    instrs
    |> Dispatch.compared_atoms(:any)
    |> Enum.filter(&(&1 in @start_errors))
    |> Enum.uniq()
    |> Enum.reduce(facts, fn atom, acc ->
      add_fact(acc, :start_error_compared, [func_id, inspect(atom)])
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
        maybe_named_start(facts, ctx, "start_link", {:x, 2}, {:started, {:x, 0}})

      {GenServer, :start, 3} ->
        maybe_named_start(facts, ctx, "start", {:x, 2}, {:started, {:x, 0}})

      # Agent.start_link(fun, opts) and Agent.start_link(mod, fun, args, opts),
      # and the unlinked starts: the options are the last argument.
      {Agent, func, arity} when func in [:start_link, :start] and arity in [2, 4] ->
        opts = {:x, arity - 1}
        maybe_named_start(facts, ctx, Atom.to_string(func), opts, {:caller, mod_str})

      {:gen_server, :start_link, 4} ->
        maybe_named_start_erlang(facts, ctx, "start_link")

      {:gen_server, :start, 4} ->
        maybe_named_start_erlang(facts, ctx, "start")

      _ ->
        lookup_or_create_call(facts, ctx, mfa)
    end
  end

  # The lookups, and the creates that are not registrations of a name the
  # module owns.
  defp lookup_or_create_call(facts, ctx, mfa) do
    case mfa do
      {Process, :whereis, 1} ->
        emit_whereis(facts, ctx)

      {:erlang, :whereis, 1} ->
        emit_whereis(facts, ctx)

      {Registry, :lookup, 2} ->
        emit_registry_lookup(facts, ctx)

      {Registry, :register, 3} ->
        emit_creating_op(facts, ctx, "registry_register", registry_scope(ctx), {:x, 1})

      {DynamicSupervisor, :start_child, 2} ->
        add_creating_op(facts, ctx, "start_child", "", "dynamic", "")

      {Supervisor, :start_child, 2} ->
        add_creating_op(facts, ctx, "start_child", "", "dynamic", "")

      # A test's start_supervised is a start_child on the test supervisor,
      # and the lookup-then-start shape is common in shared test helpers.
      {ExUnit.Callbacks, func, arity}
      when func in [:start_supervised, :start_supervised!] and arity in [1, 2] ->
        add_creating_op(facts, ctx, "start_child", "", "dynamic", "")

      _ ->
        facts
    end
  end

  defp emit_creating_op(facts, ctx, api, scope, key_reg) do
    {source, key} = key_identity(ctx.instrs, ctx.idx, key_reg)
    add_creating_op(facts, ctx, api, scope, source, key)
  end

  defp add_creating_op(facts, ctx, api, scope, source, key) do
    id = InstrId.mint(ctx.func_id, ctx.idx)
    add_fact(facts, :creating_op, [id, ctx.func_id, api, scope, source, key])
  end

  defp registry_scope(ctx), do: resolve_atom(ctx.instrs, ctx.idx, {:x, 0})

  defp emit_registry_lookup(facts, ctx) do
    id = InstrId.mint(ctx.func_id, ctx.idx)
    scope = registry_scope(ctx)
    {source, key} = key_identity(ctx.instrs, ctx.idx, {:x, 1})
    checked = if nil_checked?(ctx.instrs, ctx.idx), do: "checked", else: "unchecked"

    facts
    |> track_dynamic(scope, ctx, :registry_lookup_scope, :name_lookup)
    |> add_fact(:name_lookup, [id, ctx.func_id, "registry_lookup", scope, source, key, checked])
  end

  defp emit_register(facts, mod_str, ctx, name_reg, method) do
    id = InstrId.mint(ctx.func_id, ctx.idx)
    name = resolve_name(ctx.instrs, ctx.idx, name_reg)

    facts
    |> track_dynamic(name, ctx, :process_register_name, :process_register)
    |> add_fact(:process_register, [id, ctx.func_id, name, method])
    |> maybe_emit_named_process(mod_str, name)
    |> emit_creating_op(ctx, method, "", name_reg)
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
    {source, key} = key_identity(ctx.instrs, ctx.idx, {:x, 0})
    checked = if nil_checked?(ctx.instrs, ctx.idx), do: "checked", else: "unchecked"

    facts
    |> track_dynamic(
      if(source == "dynamic", do: "dynamic", else: key),
      ctx,
      :whereis_target,
      :name_lookup
    )
    |> add_fact(:name_lookup, [id, ctx.func_id, "whereis", "", source, key, checked])
  end

  # The result lands in x0. Along the straight-line code after the call,
  # a comparison of it against nil/:undefined (nil is also `[]`, so a
  # Registry.lookup result compared against the empty list is checked the
  # same way), a type test on it, or a select over it that lists nil means
  # the caller handles the missing case; any other use of the value first,
  # or reaching a label, call or return, means it does not.
  @nil_atoms [{:atom, nil}, {:atom, :undefined}]
  @equality_tests [:is_eq_exact, :is_ne_exact, :is_eq, :is_ne]
  @type_tests [:is_atom, :is_pid, :is_port, :is_nil, :is_list, :is_nonempty_list]

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
  # An Agent has no module of its own: the name belongs to the module whose
  # code starts it, as with register/2, so two modules that start Agents
  # under one name are two claimants rather than one "Agent".
  #
  # For tail-called start_links where options don't resolve, suppress the
  # imprecision — the wrapper is just forwarding args from its caller, so
  # the name registration (if any) should be attributed to the call site
  # that builds the options, not this intermediary.
  defp maybe_named_start(facts, ctx, method, opts_reg, owner) do
    case resolve_register(ctx.instrs, ctx.idx, opts_reg) do
      {:ok, opts} when is_list(opts) ->
        case Keyword.get(opts, :name) do
          nil ->
            facts

          # The options list resolved, but the name VALUE inside it is the
          # placeholder — `name: opts[:name]` and friends. Inspecting it
          # would forge a ":dynamic" name that evades the dynamic filters.
          # The register that holds it still says whose name it is — a
          # parameter, a field — which is what a lookup can be joined on.
          :dynamic ->
            facts
            |> track_imprecision(ctx, :gen_server_start_name, :process_register, :dynamic)
            |> emit_dynamic_named_start(ctx, method, opts_reg)

          name when is_atom(name) ->
            id = InstrId.mint(ctx.func_id, ctx.idx)

            facts
            |> add_fact(:process_register, [id, ctx.func_id, inspect(name), method])
            |> maybe_emit_named_process_for_start(ctx, owner, inspect(name))
            |> add_creating_op(ctx, method, "", "literal", inspect(name))

          # A via-registered name is the registry's, not a process_register;
          # for the race it is a create scoped to that registry.
          {:via, registry, key} ->
            add_creating_op(
              facts,
              ctx,
              "start_via",
              via_scope(registry),
              via_source(key),
              via_key(key)
            )

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

  defp emit_dynamic_named_start(facts, ctx, method, opts_reg) do
    case keyword_value_register(ctx.instrs, ctx.idx, opts_reg, :name) do
      {:ok, reg, value_idx} ->
        {source, key} = key_identity(ctx.instrs, value_idx, reg)
        add_creating_op(facts, ctx, method, "", source, key)

      :no ->
        add_creating_op(facts, ctx, method, "", "dynamic", "")
    end
  end

  defp via_scope(registry) when is_atom(registry) and registry != :dynamic, do: inspect(registry)
  defp via_scope(_registry), do: "dynamic"

  defp via_source(key)
       when (is_atom(key) and key != :dynamic) or is_binary(key) or is_integer(key),
       do: "literal"

  defp via_source(_key), do: "dynamic"

  defp via_key(key) when (is_atom(key) and key != :dynamic) or is_binary(key) or is_integer(key),
    do: inspect(key)

  defp via_key(_key), do: ""

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
        |> add_creating_op(ctx, method, "", "literal", inspect(name))

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

  # For GenServer.start_link, the module being started is x0; for an
  # Agent, the enclosing module.
  defp maybe_emit_named_process_for_start(facts, ctx, {:started, mod_reg}, name) do
    case resolve_register(ctx.instrs, ctx.idx, mod_reg) do
      {:ok, mod} when is_atom(mod) -> add_fact(facts, :named_process, [inspect(mod), name])
      _ -> facts
    end
  end

  defp maybe_emit_named_process_for_start(facts, _ctx, {:caller, mod_str}, name),
    do: add_fact(facts, :named_process, [mod_str, name])

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
