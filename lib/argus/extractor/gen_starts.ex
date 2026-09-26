defmodule Argus.Extractor.GenStarts do
  @moduledoc """
  The behaviour a start names a module the callback module of.

  `gen_server:start_link({local, inet_db}, inet_db, [], [])` runs
  `inet_db`'s `init/1`, `handle_call/3` and `terminate/2` in the process
  it starts, whether or not `inet_db` declares `-behaviour(gen_server)`:
  OTP's kernel starts `inet_db` and `pg` so, and ejabberd its
  `ejabberd_sql_sup` and `ejabberd_tmp_sup` with `supervisor:start_link/3`.
  A start, or an `enter_loop` that turns the running process into one,
  is a witness of the behaviour as the attribute is: the behaviour's
  machinery calls the module's callbacks either way.

  Read at each call whose callback-module argument resolves to a literal
  module (`?MODULE`, `__MODULE__` included); a module a caller hands a
  wrapper is not followed. `Supervisor.start_link/2` and
  `DynamicSupervisor.start_link/2` count only when their first argument
  is a module, not a child list or options. `gen:start/5,6` counts for
  the behaviours whose start it is (gen_server, gen_statem); a
  `proc_lib` start names a function to run, not a behaviour, and is
  none.
  """

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Resolve

  # {module, function, arity} => {behaviour, the register holding the
  # callback module}. The behaviour is the one the module would declare.
  @starts %{
    {:gen_server, :start, 3} => {:gen_server, 0},
    {:gen_server, :start, 4} => {:gen_server, 1},
    {:gen_server, :start_link, 3} => {:gen_server, 0},
    {:gen_server, :start_link, 4} => {:gen_server, 1},
    {:gen_server, :start_monitor, 3} => {:gen_server, 0},
    {:gen_server, :start_monitor, 4} => {:gen_server, 1},
    {:gen_server, :enter_loop, 3} => {:gen_server, 0},
    {:gen_server, :enter_loop, 4} => {:gen_server, 0},
    {:gen_server, :enter_loop, 5} => {:gen_server, 0},
    {:gen_statem, :start, 3} => {:gen_statem, 0},
    {:gen_statem, :start, 4} => {:gen_statem, 1},
    {:gen_statem, :start_link, 3} => {:gen_statem, 0},
    {:gen_statem, :start_link, 4} => {:gen_statem, 1},
    {:gen_statem, :start_monitor, 3} => {:gen_statem, 0},
    {:gen_statem, :start_monitor, 4} => {:gen_statem, 1},
    {:gen_statem, :enter_loop, 4} => {:gen_statem, 0},
    {:gen_statem, :enter_loop, 5} => {:gen_statem, 0},
    {:gen_statem, :enter_loop, 6} => {:gen_statem, 0},
    {:supervisor, :start_link, 2} => {:supervisor, 0},
    {:supervisor, :start_link, 3} => {:supervisor, 1},
    {:supervisor_bridge, :start_link, 2} => {:supervisor_bridge, 0},
    {:supervisor_bridge, :start_link, 3} => {:supervisor_bridge, 1},
    {GenServer, :start, 2} => {GenServer, 0},
    {GenServer, :start, 3} => {GenServer, 0},
    {GenServer, :start_link, 2} => {GenServer, 0},
    {GenServer, :start_link, 3} => {GenServer, 0},
    {GenStateMachine, :start, 2} => {GenStateMachine, 0},
    {GenStateMachine, :start, 3} => {GenStateMachine, 0},
    {GenStateMachine, :start_link, 2} => {GenStateMachine, 0},
    {GenStateMachine, :start_link, 3} => {GenStateMachine, 0},
    {GenStage, :start, 2} => {GenStage, 0},
    {GenStage, :start, 3} => {GenStage, 0},
    {GenStage, :start_link, 2} => {GenStage, 0},
    {GenStage, :start_link, 3} => {GenStage, 0},
    {Supervisor, :start_link, 2} => {Supervisor, 0},
    {Supervisor, :start_link, 3} => {Supervisor, 0},
    {DynamicSupervisor, :start_link, 2} => {DynamicSupervisor, 0},
    {DynamicSupervisor, :start_link, 3} => {DynamicSupervisor, 0}
  }

  # gen:start(GenMod, LinkP, Mod, Args, Opts) and
  # gen:start(GenMod, LinkP, Name, Mod, Args, Opts): the register holding
  # the callback module; GenMod, in x0, is the behaviour.
  @gen_start %{{:gen, :start, 5} => 2, {:gen, :start, 6} => 3}
  @gen_behaviours [:gen_server, :gen_statem]

  @typedoc "A callback module and the behaviour a start names it for."
  @type started :: {module(), module()}

  @doc """
  Every `{callback module, behaviour}` a start or an `enter_loop` in
  `module_data`'s functions names, sorted.
  """
  @spec callback_modules(map()) :: [started()]
  def callback_modules(module_data) do
    module_data
    |> CallSites.for_module()
    |> Enum.flat_map(&started/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The behaviours a start in `module_data`'s own functions names its own
  module for (`gen_statem:start(?MODULE, ...)`): what an extractor that
  reads one module's code alone can know of a behaviour it does not
  declare.
  """
  @spec own_behaviours(map()) :: [module()]
  def own_behaviours(%{module: mod} = module_data) do
    for {^mod, behaviour} <- callback_modules(module_data), do: behaviour
  end

  def own_behaviours(_module_data), do: []

  defp started(%{mfa: mfa, instrs: instrs, idx: idx}) do
    case {Map.fetch(@starts, mfa), Map.fetch(@gen_start, mfa)} do
      {{:ok, {behaviour, pos}}, _} ->
        for mod <- module_at(instrs, idx, pos), do: {mod, behaviour}

      {_, {:ok, pos}} ->
        with [behaviour] when behaviour in @gen_behaviours <- module_at(instrs, idx, 0),
             [mod] <- module_at(instrs, idx, pos),
             do: [{mod, behaviour}],
             else: (_ -> [])

      _ ->
        []
    end
  end

  # The module a register holds at the call, when it resolves to one: an
  # atom, not a list of children, options or the unknown.
  defp module_at(instrs, idx, pos) do
    case Resolve.resolve_register(instrs, idx, {:x, pos}) do
      {:ok, mod} when is_atom(mod) and mod not in [nil, :dynamic, true, false] -> [mod]
      _ -> []
    end
  end
end
