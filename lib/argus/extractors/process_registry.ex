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
    A global name is spelled `{:global, :n}` (`TermFlow.name_of/1`), never
    as the local atom
  - `named_process(mod, name)` — module-level: a process implemented by `mod` is registered
    as `name`; for an Agent, which has no module of its own, the module that starts it
  - `name_lookup(id, func, api, scope, source, key, checked)` —
    `Process.whereis/1`, `:erlang.whereis/1` (`api` `whereis`, no scope),
    `Registry.lookup/2` (`api` `registry_lookup`, `scope` the registry)
    and `Process.registered/0`, `:erlang.registered/0` (`api`
    `registered`, `source` `any`: every name at once); `source`/`key`
    identify the name in the vocabulary of `Argus.Extractor.Identity.key_identity/4`;
    `checked` says whether the result is tested against nil (or `[]`)
    before use
  - `nil_use(id, func, use, fails)` — for an unchecked whereis, how its
    first uses fail on nil: `error` (a send, a BIF), `exit` (a call),
    `none` (a cast) or `any`; `use` is that call in `func`, or where the
    result reached `func` when the use is no call. A result a private
    function returns is used in its callers (`returns_to/2`), none of it
    by one that tests it against nil
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

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Dispatch
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Extractor.Terms
  alias Argus.Extractors.TermFlow
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId
  import Argus.Extractor.Helpers, only: [each_remote_call: 3]
  import Argus.Extractor.Facts, only: [add_fact: 3, track_dynamic: 5, track_imprecision: 5]
  import Argus.Extractor.Identity, only: [key_identity: 4]

  import Argus.Extractor.Resolve,
    only: [keyword_value_register: 4, resolve_atom: 3, resolve_register: 3]

  import Argus.Extractor.Terms, only: [spell: 1]

  @impl true
  def relations,
    do: [
      :creating_op,
      :name_lookup,
      :name_release,
      :nil_use,
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
  @doc false
  def candidate_instructions?(instructions) do
    Enum.any?(instructions, fn instruction ->
      case Helpers.match_remote_call(instruction) do
        {:ok, m, f, a} -> site?({m, f, a})
        :none -> false
      end
    end) or
      Enum.any?(
        Dispatch.compared_atoms(instructions, :any),
        &(&1 in [:already_started, :already_registered])
      )
  end

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod_str = inspect(module_data.module)

    index = Argus.Extractor.Identity.origins_index(module_data)

    returns =
      Map.get_lazy(module_data, :returns_to, fn ->
        case whereis_functions(module_data) do
          [] -> %{}
          funcs -> returns_to(module_data, funcs)
        end
      end)

    module_data
    |> each_remote_call(%{}, fn facts, ctx, mfa ->
      ctx = ctx |> Map.put(:origins, {index, ctx.func_id}) |> Map.put(:returns, returns)
      register_call(facts, mod_str, ctx, mfa)
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
      emit_start_errors(acc, InstrId.func_id(module_data.module, name, arity), instrs)
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
    |> maybe_nil_use(checked, id, ctx)
  end

  defp maybe_nil_use(facts, "checked", _id, _ctx), do: facts

  defp maybe_nil_use(facts, "unchecked", id, ctx) do
    uses =
      case value_use(ctx.instrs, ctx.idx) do
        :returned -> returned_uses(ctx.func_id, id, ctx.returns, MapSet.new([ctx.func_id]))
        {at, instr} -> [{ctx.func_id, use_site(ctx.func_id, at, instr, id), nil_fails(instr)}]
        nil -> [{ctx.func_id, id, "any"}]
      end

    uses
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(facts, fn {func, use, fails}, acc ->
      add_fact(acc, :nil_use, [id, func, use, fails])
    end)
  end

  # The first uses of a value `func` returns, which reached it at `site`
  # (the lookup, or a call that returned it), as `{func, use, fails}`. A
  # function code outside the module may call hands it to a use nobody
  # here knows (`any`); a private one's callers each check it, use it,
  # or return it on in turn, followed to their callers. `seen` are the
  # functions followed already: a cycle back to one adds no use.
  defp returned_uses(func, site, returns, seen) do
    case Map.get(returns, func, :escapes) do
      :escapes ->
        [{func, site, "any"}]

      callers ->
        seen = MapSet.put(seen, func)

        Enum.flat_map(callers, fn
          {_caller, _call, :checked} ->
            []

          {caller, call, :returned} ->
            if MapSet.member?(seen, caller),
              do: [],
              else: returned_uses(caller, call, returns, seen)

          {caller, _call, {use, fails}} ->
            [{caller, use, fails}]
        end)
    end
  end

  @typedoc """
  A call to a function that returns a value, and what the caller does
  with it: tests it against nil first (`:checked`), returns it in turn
  (`:returned`), or first uses it at `use`, failing `fails` on nil.
  """
  @type returned_to ::
          {caller :: String.t(), call :: String.t(),
           :checked | :returned | {use :: String.t(), fails :: String.t()}}

  @doc """
  What becomes of the values the functions `funcs` return, for them and
  for every function a caller returns one on to: `:escapes` for a
  function code outside the module may call (it is exported, or a fun
  is made of it), else the module's calls to it (`t:returned_to/0`).

  A function-local extraction reads it as `module_data.returns_to`: it
  is the only thing a lookup's function learns of its callers.
  """
  @spec returns_to(Argus.Extractor.module_data(), [String.t()]) :: %{
          String.t() => :escapes | [returned_to()]
        }
  def returns_to(module_data, funcs), do: follow(funcs, local_calls(module_data), %{})

  defp follow([], _local, acc), do: acc

  defp follow([func | rest], local, acc) when is_map_key(acc, func),
    do: follow(rest, local, acc)

  defp follow([func | rest], local, acc) do
    entry =
      if MapSet.member?(local.escaping, func),
        do: :escapes,
        else: local.callers |> Map.get(func, []) |> Enum.map(&caller_use/1) |> Enum.sort()

    more = if entry == :escapes, do: [], else: for({caller, _, :returned} <- entry, do: caller)
    follow(more ++ rest, local, Map.put(acc, func, entry))
  end

  defp caller_use(site) do
    call = InstrId.mint(site.func_id, site.idx)

    use =
      if nil_checked?(site.instrs, site.idx) do
        :checked
      else
        case value_use(site.instrs, site.idx) do
          :returned -> :returned
          {at, instr} -> {use_site(site.func_id, at, instr, call), nil_fails(instr)}
          nil -> {call, "any"}
        end
      end

    {site.func_id, call, use}
  end

  # The functions holding a whereis: the ones whose lookups a whole
  # module's extraction may follow to their callers.
  defp whereis_functions(module_data) do
    module_data
    |> CallSites.for_module()
    |> Enum.filter(&(&1.remote? and &1.mfa in [{Process, :whereis, 1}, {:erlang, :whereis, 1}]))
    |> Enum.map(& &1.func_id)
    |> Enum.uniq()
  end

  # What the value the call at `idx` answers meets first: `:returned`
  # (a tail call, or a return before any use), `{index, instr}` its
  # first use, or nil when the straight line ends or loses it first.
  defp value_use(instrs, idx) do
    if Instr.tail_call?(Enum.at(instrs, idx)) do
      :returned
    else
      case first_use(instrs, idx + 1, [{:x, 0}]) do
        {_at, :return} -> :returned
        use -> use
      end
    end
  end

  # The use is the instruction when it is a call, else `site`.
  defp use_site(func, at, instr, site) do
    if Instr.call?(instr) or Instr.tail_call?(instr), do: InstrId.mint(func, at), else: site
  end

  # The module's local call sites by the function they call, and the
  # functions code outside the module may call: the exported ones, and
  # the ones a fun is made of.
  defp local_calls(module_data) do
    mod = module_data.module

    callers =
      module_data
      |> CallSites.for_module()
      |> Enum.filter(&(not &1.remote? and elem(&1.mfa, 0) == mod))
      |> Enum.group_by(fn %{mfa: {m, f, a}} -> InstrId.func_id(m, f, a) end)

    # Without the exports (a bare disassembly), any function may be one.
    exported =
      case Map.get(module_data, :exports) do
        nil ->
          for {:function, name, arity, _entry, _instrs} <- module_data.functions,
              do: InstrId.func_id(mod, name, arity)

        exports ->
          for export <- exports,
              {name, arity} = export_name(export),
              do: InstrId.func_id(mod, name, arity)
      end

    funs =
      for {:function, _name, _arity, _entry, instrs} <- module_data.functions,
          {:make_fun3, {^mod, name, arity}, _index, _uniq, _dst, _env} <- instrs,
          do: InstrId.func_id(mod, name, arity)

    %{callers: callers, escaping: MapSet.new(exported ++ funs)}
  end

  defp export_name({name, arity, _label}), do: {name, arity}
  defp export_name({:atom, name, arity, _label}), do: {name, arity}

  # The first instruction that reads the result other than to copy it,
  # along the straight line after the lookup: `{index, instr}`, or nil
  # when the line ends or the value is lost first.
  defp first_use(instrs, at, regs) do
    case Enum.at(instrs, at) do
      nil ->
        nil

      _instr when regs == [] ->
        nil

      instr ->
        cond do
          reads?(instr, regs) -> {at, instr}
          not Instr.falls_through?(instr) -> nil
          true -> first_use(instrs, at + 1, Instr.carry(instr, regs))
        end
    end
  end

  # How a use fails on a nil (an unregistered name): a send to it, or a
  # BIF given it, raises badarg (and Elixir's Process functions guard on
  # a pid: FunctionClauseError), a call to it exits with :noproc, a cast
  # drops the message (GenServer.cast and :gen_server.cast catch the
  # send's failure). A monitor of it answers with a :DOWN, and does not
  # fail either.
  @error_bifs [
    :send,
    :process_info,
    :link,
    :unlink,
    :exit,
    :is_process_alive,
    :group_leader,
    :suspend_process,
    :resume_process,
    :register,
    :garbage_collect
  ]
  @elixir_process [:send, :info, :link, :unlink, :exit, :alive?, :group_leader, :register]
  @calls [
    {GenServer, :call},
    {GenServer, :stop},
    {:gen_server, :call},
    {:gen_server, :stop},
    {:gen_statem, :call},
    {:gen_statem, :stop},
    {GenStateMachine, :call},
    {:gen, :call},
    {:proc_lib, :stop},
    {:sys, :get_state},
    {:sys, :get_status},
    {Agent, :get},
    {Agent, :update},
    {Agent, :get_and_update}
  ]
  @casts [
    {GenServer, :cast},
    {:gen_server, :cast},
    {:gen_statem, :cast},
    {GenStateMachine, :cast},
    {Agent, :cast},
    {:erlang, :monitor},
    {Process, :monitor}
  ]

  defp nil_fails(:send), do: "error"
  defp nil_fails({:send}), do: "error"

  defp nil_fails(instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, :erlang, f, _a} -> if f in @error_bifs, do: "error", else: others(:erlang, f)
      {:ok, Process, f, _a} -> if f in @elixir_process, do: "error", else: others(Process, f)
      {:ok, m, f, _a} -> others(m, f)
      :none -> "any"
    end
  end

  defp others(m, f) do
    cond do
      {m, f} in @calls -> "exit"
      {m, f} in @casts -> "none"
      true -> "any"
    end
  end

  # The result lands in x0. Along the straight-line code after the call,
  # the first comparison against nil/:undefined, type test or select
  # decides: one of the value (nil is also `[]`, so a Registry.lookup
  # result compared against the empty list is checked the same way), a
  # type test on it, or a select over it that lists nil means the caller
  # handles the missing case. A comparison in a guard is a test; one
  # whose boolean is a value (`whereis(m) =/= :undefined` returned,
  # `is_pid(Process.whereis(n))`) is a bif, and decides only where the
  # boolean is branched on before the pid is used (decided_by?/3).
  # Any other use of the value first, or reaching the end of the
  # straight line, means it does not.
  #
  # A comparison with a value that is never nil — self(), the group
  # leader, a pid spawn/1 answered, a literal other than nil, wherever it
  # was made (`never_nil?/3`) — asks a question of its own
  # (`whereis(m) == self()`: am I the registered process?) and uses the
  # value in no way nil can break. It decides when the value is not read again where the two
  # differ, the one place it may still be nil: the branch taken when
  # they differ for a test, anywhere after for a bif. That walk gives up
  # as this one does.
  @nil_atoms [{:atom, nil}, {:atom, :undefined}]
  @equality_tests [:is_eq_exact, :is_ne_exact, :is_eq, :is_ne]
  @equality_bifs [:==, :"/=", :"=:=", :"=/="]
  @type_tests [:is_atom, :is_pid, :is_port, :is_nil, :is_list, :is_nonempty_list]
  @type_bifs [:is_atom, :is_pid, :is_port, :is_list]

  defp nil_checked?(instrs, idx) do
    labels = Instr.labels(instrs)
    checked_walk(Enum.drop(instrs, idx + 1), idx + 1, [{:x, 0}], {instrs, labels})
  end

  # Before the deciding test the value is followed through the registers
  # as `Argus.Instr` reads them: a copy carries it, a write or a call's
  # clobber ends a register's hold on it. The walk gives up where the
  # value is read, where no register holds it any more, and where control
  # does not fall through (a return, a jump, a tail call, a raise). `at`
  # is the index of the walk's next instruction.
  defp checked_walk([], _at, _regs, _fun), do: false
  defp checked_walk(_instrs, _at, [], _fun), do: false

  defp checked_walk([{:test, op, fail, args} | rest], at, regs, fun)
       when op in @equality_tests do
    case compared(args, at, regs, fun) do
      nil -> true
      :never_nil -> unread_where_differ(op, fail, rest, regs, fun)
      :other -> false
    end
  end

  defp checked_walk([{:test, op, _fail, [reg | _]} | _rest], _at, regs, _fun)
       when op in @type_tests do
    Instr.register(reg) in regs
  end

  defp checked_walk([{:select_val, reg, _fail, {:list, cases}} | _rest], _at, regs, _fun) do
    Instr.register(reg) in regs and Enum.any?(cases, &(&1 in @nil_atoms))
  end

  defp checked_walk([{:bif, op, _fail, args, dst} = instr | rest], at, regs, fun)
       when op in @equality_bifs do
    case compared(args, at, regs, fun) do
      nil -> decided_by?(rest, Instr.carry(instr, regs), [Instr.register(dst)])
      :never_nil -> unread?(rest, Instr.carry(instr, regs))
      :other -> false
    end
  end

  defp checked_walk([{:bif, op, _fail, [reg], dst} = instr | rest], _at, regs, _fun)
       when op in @type_bifs do
    Instr.register(reg) in regs and
      decided_by?(rest, Instr.carry(instr, regs), [Instr.register(dst)])
  end

  defp checked_walk([instr | rest], at, regs, fun) do
    cond do
      not Instr.falls_through?(instr) -> false
      reads?(instr, regs) -> false
      true -> checked_walk(rest, at + 1, Instr.carry(instr, regs), fun)
    end
  end

  # A comparison whose boolean is a value checks the lookup only where the
  # boolean decides something before the pid is read again: a branch on
  # it (`pid != nil && send(pid, m)`, a `case` on `is_pid(pid)`), or no
  # use of the pid at all (`whereis(m) =/= :undefined` returned as a
  # status). A boolean recorded, sent or stored while the pid is used
  # anyway (`record(pid != nil); send(pid, event)`) checks nothing: the
  # send still takes the nil. `bools` are the registers holding the
  # boolean; a return, when it does not read the pid, ends the function
  # with the pid unused.
  defp decided_by?(_instrs, [], _bools), do: true
  defp decided_by?([], _regs, _bools), do: false

  defp decided_by?([instr | rest], regs, bools) do
    cond do
      reads?(instr, regs) ->
        false

      branches?(instr) and Enum.any?(Instr.uses(instr), &(&1 in bools)) ->
        true

      instr == :return ->
        true

      not Instr.falls_through?(instr) ->
        false

      true ->
        decided_by?(rest, Instr.carry(instr, regs), Instr.carry(instr, bools))
    end
  end

  # What a comparison of the value (at `at`) is with: nil (or
  # :undefined), a value that is never nil, or anything else (another
  # register, or a comparison that does not read the value at all).
  defp compared(args, at, regs, {instrs, _labels}) do
    case Enum.split_with(args, &(Instr.register(&1) in regs)) do
      {[_ | _], [other]} ->
        cond do
          Instr.register(other) in @nil_atoms -> nil
          never_nil?(instrs, at, other) -> :never_nil
          true -> :other
        end

      _ ->
        :other
    end
  end

  # Calls whose answer is never nil: a pid, a port, a reference, a node.
  @never_nil_calls MapSet.new([
                     {:erlang, :self, 0},
                     {:erlang, :group_leader, 0},
                     {Process, :group_leader, 0},
                     {:erlang, :make_ref, 0},
                     {:erlang, :node, 0},
                     {:erlang, :spawn, 1},
                     {:erlang, :spawn, 2},
                     {:erlang, :spawn, 3},
                     {:erlang, :spawn, 4},
                     {:erlang, :spawn_link, 1},
                     {:erlang, :spawn_link, 2},
                     {:erlang, :spawn_link, 3},
                     {:erlang, :spawn_link, 4},
                     {Kernel, :spawn, 1},
                     {Kernel, :spawn, 3},
                     {Kernel, :spawn_link, 1},
                     {Kernel, :spawn_link, 3},
                     {:erlang, :open_port, 2},
                     {Port, :open, 2}
                   ])

  # Types the compiler gives a register that leave nil out.
  @never_nil_types [:pid, :port, :reference]

  # Whether the operand holds a value that is never nil at `at`: a literal
  # other than nil, a register the compiler types as a pid, a port or a
  # reference, or one every write reaching it (copies followed) made
  # never nil — self(), node(), a call in `@never_nil_calls`.
  defp never_nil?(_instrs, _at, {:tr, _reg, type}) when type in @never_nil_types, do: true

  defp never_nil?(instrs, at, operand) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] ->
        case Resolve.writers(instrs, at, reg) do
          [] -> false
          writers -> Enum.all?(writers, &never_nil_writer?(instrs, &1))
        end

      literal ->
        never_nil_literal?(literal)
    end
  end

  defp never_nil_writer?(_instrs, {:param, _k}), do: false

  defp never_nil_writer?(instrs, at) do
    case Reaching.at(instrs, at) do
      {:bif, name, _fail, [], _dst} when name in [:self, :node] ->
        true

      {:move, literal, _dst} ->
        never_nil_literal?(literal)

      instr ->
        case Helpers.match_remote_call(instr) do
          {:ok, m, f, a} -> MapSet.member?(@never_nil_calls, {m, f, a})
          :none -> false
        end
    end
  end

  defp never_nil_literal?({:atom, a}), do: a not in [nil, :undefined]
  defp never_nil_literal?({:integer, _}), do: true
  defp never_nil_literal?({:float, _}), do: true
  defp never_nil_literal?({:literal, l}), do: l not in [nil, :undefined]
  defp never_nil_literal?(_other), do: false

  # Where a test finds the two different: its fail label for an equality
  # test, the next instruction for an inequality.
  defp unread_where_differ(op, {:f, label}, _rest, regs, {instrs, labels})
       when op in [:is_eq_exact, :is_eq] do
    case Map.fetch(labels, label) do
      {:ok, at} -> unread?(Enum.drop(instrs, at + 1), regs)
      :error -> false
    end
  end

  defp unread_where_differ(_op, _fail, rest, regs, _fun), do: unread?(rest, regs)

  # The value is not read again along the straight line: every register
  # holding it is written or clobbered first. A branch, a jump or the
  # end of the line gives up; a return reads x0.
  defp unread?(_instrs, []), do: true
  defp unread?([], _regs), do: false

  defp unread?([instr | rest], regs) do
    cond do
      reads?(instr, regs) -> false
      not Instr.falls_through?(instr) -> false
      branches?(instr) -> false
      true -> unread?(rest, Instr.carry(instr, regs))
    end
  end

  defp branches?(instr) when elem(instr, 0) in [:test, :select_val, :select_tuple_arity], do: true
  defp branches?(_instr), do: false

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
          # No `name:` in options read whole: an unnamed start. In options
          # the reader knows only in part (`[name: n] ++ opts`, `[:x | opts]`,
          # whose unknown tail it reads as a `:dynamic` element) a name may
          # be in the part it cannot read: unknown, not unnamed (issue #4).
          nil ->
            if Terms.value_contains?(opts, &(&1 == :dynamic)) do
              facts
              |> track_imprecision(ctx, :gen_server_start_name, :process_register, :dynamic)
              |> emit_dynamic_named_start(ctx, method, opts_reg)
            else
              facts
            end

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
          # not the local `:n` (TermFlow.name_of/1 spells both).
          {:global, name} = global when is_atom(name) and name != :dynamic ->
            named_start(facts, ctx, method, owner, TermFlow.name_of(global))

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
        spelled = if kind == :local, do: inspect(name), else: TermFlow.name_of(tuple)

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
