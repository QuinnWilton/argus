defmodule Argus.Extractors.ProcessRegistry do
  @moduledoc """
  Process registry and naming extractor.

  Detects process name registration, Registry operations, `{:via, ...}` tuple
  construction, and `Process.whereis/1` calls. Enriches the existing OTP
  analysis suite with naming information to catch registration collisions,
  TOCTOU races on `whereis`, and unreachable named processes.

  ## Emitted facts

  - `process_register(id, func, name, method)` — direct registration and the
    name a start claims: the `name:` option of a GenServer, GenStateMachine,
    Supervisor or Agent start, the `{:local, n}` / `{:global, n}` of an
    Erlang `:gen_server`, `:gen_statem`, `:supervisor` or `:gen_event` start.
    A global name is spelled `{:global, :n}` (`PidFlow.name_of/1`), never
    as the local atom
  - `named_process(mod, name)` — module-level: a process implemented by `mod` is registered
    as `name`; for an Agent, which has no module of its own, the module that starts it
  - `name_lookup(id, func, api, scope, source, key, checked)` —
    `Process.whereis/1`, `:erlang.whereis/1` (`api` `whereis`, no scope),
    `Registry.lookup/2` (`api` `registry_lookup`, `scope` the registry)
    and `Process.registered/0`, `:erlang.registered/0` (`api`
    `registered`, `source` `any`: every name at once); `source`/`key`
    identify the name in the vocabulary of `Helpers.key_identity/3`;
    `checked` says whether the result is tested against nil (or `[]`)
    before use
  - `creating_op(id, func, api, scope, source, key)` — a call that claims
    a name or starts a process: `register`, `start_link`/`start` with a
    `name:`, `start_via` (`{:via, Registry, {scope, key}}`),
    `registry_register`, and `start_child`, whose name hides in the child
    spec (`source` `dynamic`)
  - `name_release(id, func, api, source, key)` — `Process.unregister/1`
    or `:erlang.unregister/1`, which raises when the name is no longer
    registered
  - `start_error_compared(func, atom)` — `:already_started` or
    `:already_registered` is compared anywhere in a function holding a
    creating op: the loser's outcome is taken. Over-approximate on
    purpose, so an unrelated comparison keeps the race rule quiet
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.Dispatch
  alias Argus.Extractors.PidFlow
  alias Argus.Instr
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      each_remote_call: 3,
      key_identity: 4,
      keyword_value_register: 4,
      resolve_atom: 3,
      resolve_register: 3,
      spell: 1,
      track_dynamic: 5,
      track_imprecision: 5
    ]

  @impl true
  def relations,
    do: [
      :creating_op,
      :name_lookup,
      :name_release,
      :named_process,
      :process_register,
      :start_error_compared
    ]

  # The calls this extractor reads a name lookup, claim or release from:
  # the shared-state sites `Argus.Extractors.Dependence` follows.
  @sites [
    {Process, :whereis, 1},
    {:erlang, :whereis, 1},
    {Process, :registered, 0},
    {:erlang, :registered, 0},
    {Registry, :lookup, 2},
    {Process, :register, 2},
    {:erlang, :register, 2},
    {Process, :unregister, 1},
    {:erlang, :unregister, 1},
    {Registry, :register, 3},
    {GenServer, :start_link, 3},
    {GenServer, :start, 3},
    {:gen_server, :start_link, 4},
    {:gen_server, :start, 4},
    {GenStateMachine, :start_link, 3},
    {GenStateMachine, :start, 3},
    {:gen_statem, :start_link, 4},
    {:gen_statem, :start, 4},
    {Supervisor, :start_link, 2},
    {Supervisor, :start_link, 3},
    {:supervisor, :start_link, 3},
    {:gen_event, :start_link, 1},
    {:gen_event, :start_link, 2},
    {:gen_event, :start, 1},
    {:gen_event, :start, 2},
    {Agent, :start_link, 2},
    {Agent, :start_link, 4},
    {Agent, :start, 2},
    {Agent, :start, 4},
    {DynamicSupervisor, :start_child, 2},
    {Supervisor, :start_child, 2},
    {ExUnit.Callbacks, :start_supervised, 1},
    {ExUnit.Callbacks, :start_supervised, 2},
    {ExUnit.Callbacks, :start_supervised!, 1},
    {ExUnit.Callbacks, :start_supervised!, 2}
  ]

  @doc "Whether a remote call looks up, claims or releases a name."
  @spec site?(mfa()) :: boolean()
  def site?(mfa), do: mfa in @sites

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod_str = inspect(module_data.module)

    index = Argus.Extractor.Helpers.origins_index(module_data)

    module_data
    |> each_remote_call(%{}, fn facts, ctx, mfa ->
      register_call(facts, mod_str, Map.put(ctx, :origins, {index, ctx.func_id}), mfa)
    end)
    |> emit_start_errors(module_data)
  end

  # ── The loser's outcome ──────────────────────────────────────────

  @start_errors [:already_started, :already_registered]

  # For every function: the start errors it compares against anywhere.
  # The taker may be the creating function's caller, so every function
  # says, not only the ones holding a creating op.
  defp emit_start_errors(facts, module_data) do
    Enum.reduce(module_data.functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      emit_start_errors(acc, Normalize.func_id(module_data.module, name, arity), instrs)
    end)
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

      {mod, func, 3} when mod in [GenServer, GenStateMachine] and func in [:start_link, :start] ->
        maybe_named_start(facts, ctx, Atom.to_string(func), {:x, 2}, {:started, {:x, 0}})

      # Supervisor.start_link(mod, arg, opts), and the module-less
      # Supervisor.start_link(children, opts), whose name belongs to no
      # module of the program.
      {Supervisor, :start_link, 3} ->
        maybe_named_start(facts, ctx, "start_link", {:x, 2}, {:started, {:x, 0}})

      {Supervisor, :start_link, 2} ->
        maybe_named_start(facts, ctx, "start_link", {:x, 1}, :none)

      # Agent.start_link(fun, opts) and Agent.start_link(mod, fun, args, opts),
      # and the unlinked starts: the options are the last argument.
      {Agent, func, arity} when func in [:start_link, :start] and arity in [2, 4] ->
        opts = {:x, arity - 1}
        maybe_named_start(facts, ctx, Atom.to_string(func), opts, {:caller, mod_str})

      _ ->
        erlang_start_call(facts, ctx, mfa)
    end
  end

  # The Erlang starts, whose name comes first as `{:local, n}` or
  # `{:global, n}`.
  defp erlang_start_call(facts, ctx, mfa) do
    case mfa do
      {mod, func, 4} when mod in [:gen_server, :gen_statem] and func in [:start_link, :start] ->
        maybe_named_start_erlang(facts, ctx, Atom.to_string(func))

      {:supervisor, :start_link, 3} ->
        maybe_named_start_erlang(facts, ctx, "start_link")

      # An event manager has no callback module of its own.
      {:gen_event, func, arity} when func in [:start_link, :start] and arity in [1, 2] ->
        maybe_named_start_erlang(facts, ctx, Atom.to_string(func), nil)

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

      {Process, :registered, 0} ->
        emit_registered(facts, ctx)

      {:erlang, :registered, 0} ->
        emit_registered(facts, ctx)

      {Process, :unregister, 1} ->
        emit_release(facts, ctx)

      {:erlang, :unregister, 1} ->
        emit_release(facts, ctx)

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
    {source, key} = key_identity(ctx.instrs, ctx.idx, key_reg, ctx.origins)
    add_creating_op(facts, ctx, api, scope, source, key)
  end

  defp add_creating_op(facts, ctx, api, scope, source, key) do
    id = InstrId.mint(ctx.func_id, ctx.idx)
    add_fact(facts, :creating_op, [id, ctx.func_id, api, scope, source, key])
  end

  defp registry_scope(ctx), do: resolve_atom(ctx.instrs, ctx.idx, {:x, 0})

  # Every registered name at once: whatever decides on the list decides
  # on the name it goes on to register.
  defp emit_registered(facts, ctx) do
    id = InstrId.mint(ctx.func_id, ctx.idx)
    add_fact(facts, :name_lookup, [id, ctx.func_id, "registered", "", "any", "", "checked"])
  end

  defp emit_release(facts, ctx) do
    id = InstrId.mint(ctx.func_id, ctx.idx)
    {source, key} = key_identity(ctx.instrs, ctx.idx, {:x, 0}, ctx.origins)
    add_fact(facts, :name_release, [id, ctx.func_id, "unregister", source, key])
  end

  defp emit_registry_lookup(facts, ctx) do
    id = InstrId.mint(ctx.func_id, ctx.idx)
    scope = registry_scope(ctx)
    {source, key} = key_identity(ctx.instrs, ctx.idx, {:x, 1}, ctx.origins)
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
    {source, key} = key_identity(ctx.instrs, ctx.idx, {:x, 0}, ctx.origins)
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
  # the first comparison against nil/:undefined, type test or select
  # decides: one of the value (nil is also `[]`, so a Registry.lookup
  # result compared against the empty list is checked the same way), a
  # type test on it, or a select over it that lists nil means the caller
  # handles the missing case. Any other use of the value first, or
  # reaching the end of the straight line, means it does not.
  @nil_atoms [{:atom, nil}, {:atom, :undefined}]
  @equality_tests [:is_eq_exact, :is_ne_exact, :is_eq, :is_ne]
  @type_tests [:is_atom, :is_pid, :is_port, :is_nil, :is_list, :is_nonempty_list]

  defp nil_checked?(instrs, idx) do
    instrs |> Enum.drop(idx + 1) |> checked_walk([{:x, 0}])
  end

  # Before the deciding test the value is followed through the registers
  # as `Argus.Instr` reads them: a copy carries it, a write or a call's
  # clobber ends a register's hold on it. The walk gives up where the
  # value is read, where no register holds it any more, and where control
  # does not fall through (a return, a jump, a tail call, a raise).
  defp checked_walk([], _regs), do: false
  defp checked_walk(_instrs, []), do: false

  defp checked_walk([{:test, op, _fail, args} | _rest], regs) when op in @equality_tests do
    args = Enum.map(args, &Instr.register/1)
    Enum.any?(args, &(&1 in regs)) and Enum.any?(args, &(&1 in @nil_atoms))
  end

  defp checked_walk([{:test, op, _fail, [reg | _]} | _rest], regs) when op in @type_tests do
    Instr.register(reg) in regs
  end

  defp checked_walk([{:select_val, reg, _fail, {:list, cases}} | _rest], regs) do
    Instr.register(reg) in regs and Enum.any?(cases, &(&1 in @nil_atoms))
  end

  defp checked_walk([instr | rest], regs) do
    cond do
      not Instr.falls_through?(instr) -> false
      reads?(instr, regs) -> false
      true -> checked_walk(rest, Instr.carry(instr, regs))
    end
  end

  # Whether `instr` reads the value other than to copy it.
  defp reads?(instr, regs) do
    defs = Instr.defs(instr)
    copy? = defs != [] and Enum.all?(defs, &(Instr.copy_source(instr, &1) != nil))
    not copy? and Enum.any?(Instr.uses(instr), &(&1 in regs))
  end

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
            named_start(facts, ctx, method, owner, inspect(name))

          # The global registry is its own namespace: `{:global, :n}` is
          # not the local `:n` (PidFlow.name_of/1 spells both).
          {:global, name} = global when is_atom(name) and name != :dynamic ->
            named_start(facts, ctx, method, owner, PidFlow.name_of(global))

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
        if Instr.tail_call?(Enum.at(ctx.instrs, ctx.idx)) do
          facts
        else
          track_imprecision(facts, ctx, :gen_server_start_name, :process_register, :skipped)
        end
    end
  end

  defp named_start(facts, ctx, method, owner, name) do
    id = InstrId.mint(ctx.func_id, ctx.idx)

    facts
    |> add_fact(:process_register, [id, ctx.func_id, name, method])
    |> maybe_emit_named_process_for_start(ctx, owner, name)
    |> add_creating_op(ctx, method, "", "literal", name)
  end

  defp emit_dynamic_named_start(facts, ctx, method, opts_reg) do
    case keyword_value_register(ctx.instrs, ctx.idx, opts_reg, :name) do
      {:ok, reg, value_idx} ->
        {source, key} = key_identity(ctx.instrs, value_idx, reg, ctx.origins)
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
    do: spell(key)

  defp via_key(_key), do: ""

  # Erlang-style :gen_server.start_link({:local, Name}, mod, args, opts).
  # The module is x1 in the Erlang shape; resolve it to enrich named_process.
  # A `{:global, Name}` is spelled as the global registry's, never as the
  # local atom.
  defp maybe_named_start_erlang(facts, ctx, method, mod_reg \\ {:x, 1}) do
    case resolve_register(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, {kind, name} = tuple}
      when kind in [:local, :global] and is_atom(name) and name != :dynamic ->
        id = InstrId.mint(ctx.func_id, ctx.idx)
        spelled = if kind == :local, do: inspect(name), else: PidFlow.name_of(tuple)

        facts
        |> add_fact(:process_register, [id, ctx.func_id, spelled, method])
        |> maybe_emit_named_process_for_erlang_start(ctx, spelled, mod_reg)
        |> add_creating_op(ctx, method, "", "literal", spelled)

      _ ->
        if Instr.tail_call?(Enum.at(ctx.instrs, ctx.idx)) do
          facts
        else
          track_imprecision(facts, ctx, :gen_server_start_name, :process_register, :skipped)
        end
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

  defp maybe_emit_named_process_for_start(facts, _ctx, :none, _name), do: facts

  # For :gen_server.start_link({:local, name}, mod, ...), the module is x1;
  # an event manager has none.
  defp maybe_emit_named_process_for_erlang_start(facts, _ctx, _name, nil), do: facts

  defp maybe_emit_named_process_for_erlang_start(facts, ctx, name, mod_reg) do
    case resolve_register(ctx.instrs, ctx.idx, mod_reg) do
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
