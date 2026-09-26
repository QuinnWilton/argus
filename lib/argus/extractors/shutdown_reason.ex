defmodule Argus.Extractors.ShutdownReason do
  @moduledoc """
  What a function runs, and hands on, when a parameter holds `:shutdown`.

  A supervisor stops a child with `exit(pid, :shutdown)` (supervisor.erl's
  `shutdown/1`, DynamicSupervisor's `terminate_children/2`), so a process
  that traps exits runs its `terminate/2` with the reason `:shutdown`,
  the bare atom. terminate/2 may choose its work by that reason, or hand
  it to a function that does: mnesia's servers call
  `mnesia_monitor:terminate_proc(who, reason, state)`, whose first clause
  (`when R /= shutdown`) reports a fatal error and whose second only logs.
  Which function holds the reason is a question of the whole program, so
  this answers it for every function and every parameter; the shutdown
  analysis follows the reason from terminate/2 through the calls that
  hand it on.

  Every path of a function is walked with the parameter fixed to
  `:shutdown` (`Argus.Extractor.Dispatch.reached_holding/3`): a test on
  it, or on a copy of it, takes only the edge the atom takes, and every
  other instruction both, so a test this does not read keeps what follows
  it.

  ## Emitted facts

  - `shutdown_chooses(func, pos)` — `func` chooses what it runs by its
    parameter `pos`, and when it holds `:shutdown` some call does not
    run: one sits in a clause for other reasons (`terminate(:normal, s)`,
    `terminate_proc(_, r, _) when r != :shutdown`), after a clause that
    took `:shutdown`, or on a branch of a test `:shutdown` does not take.
  - `shutdown_runs(id, func, pos)` — for a function that chooses by `pos`,
    the call (or Erlang `!`) at `id` runs when the parameter holds
    `:shutdown`. A function that does not choose by the parameter runs
    every call whatever it holds, and has no rows.
  - `shutdown_handed(id, func, pos, arg)` — the call at `id`, which runs
    when `func`'s parameter `pos` holds `:shutdown`, hands that value on
    unchanged as the callee's argument `arg`, on every path that reaches
    it: `terminate(reason, s)` calling `cleanup(reason, s)` enters
    `cleanup/2` holding `:shutdown` in its first parameter. A call into
    the runtime (`Argus.Extractor.Runtime`) is left out: its callee has
    no rows to follow.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Dispatch
  alias Argus.Extractor.Runtime
  alias Argus.Instr
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @impl true
  def relations, do: [:shutdown_chooses, :shutdown_runs, :shutdown_handed]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(%{module: mod, functions: functions} = module_data) do
    # The remote and local calls, by function and index: the calls a
    # value can be handed to.
    calls =
      module_data
      |> CallSites.for_module()
      |> Map.new(fn site -> {{site.func_id, site.idx}, site.mfa} end)

    functions
    |> Enum.sort_by(fn {:function, name, arity, _entry, _instrs} -> {name, arity} end)
    |> Enum.reduce(%{}, fn {:function, name, arity, _entry, instrs}, facts ->
      func_id = Normalize.func_id(mod, name, arity)
      sites = sites(instrs)

      if arity == 0 or sites == [],
        do: facts,
        else: Enum.reduce(0..(arity - 1), facts, &emit(&2, func_id, instrs, sites, calls, &1))
    end)
  end

  def extract(_module_data), do: %{}

  # The instructions a rule can name as a call: the calls that return
  # here, the tail calls, and Erlang's `!`.
  defp sites(instrs) do
    for {instr, idx} <- Enum.with_index(instrs),
        Instr.call?(instr) or Instr.tail_call?(instr) or instr == :send,
        do: idx
  end

  defp emit(facts, func_id, instrs, sites, calls, pos) do
    holding = Dispatch.reached_holding(instrs, {:x, pos}, :shutdown)
    running = Enum.filter(sites, &Map.has_key?(holding, &1))

    facts =
      if length(running) < length(sites) do
        running
        |> Enum.reduce(add_fact(facts, :shutdown_chooses, [func_id, to_string(pos)]), fn idx,
                                                                                         acc ->
          add_fact(acc, :shutdown_runs, [InstrId.mint(func_id, idx), func_id, to_string(pos)])
        end)
      else
        facts
      end

    for idx <- running,
        {callee, _f, arity} <- List.wrap(Map.get(calls, {func_id, idx})),
        not Runtime.module?(callee),
        {:x, arg} <- Map.fetch!(holding, idx),
        arg < arity,
        reduce: facts do
      acc ->
        add_fact(acc, :shutdown_handed, [
          InstrId.mint(func_id, idx),
          func_id,
          to_string(pos),
          to_string(arg)
        ])
    end
  end
end
