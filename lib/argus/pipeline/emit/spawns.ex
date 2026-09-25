defmodule Argus.Pipeline.Emit.Spawns do
  @moduledoc """
  The `spawn_call` rows of one function: every call that starts a
  process running a function it names in its arguments, and what that
  function is.

  A spawn names what the new process runs in one of two ways: a fun
  (`spawn(fun)`, `:proc_lib.spawn_link(fun)`, `:erlang.spawn_opt(fun,
  opts)`), or a module, function and argument list (`spawn(M, F, args)`,
  `:proc_lib.start_link(M, F, args)`), either after a node for the
  node-qualified forms. The row says, in `source`, how far the arguments
  resolve:

    * `"closure"` — the fun is a `make_fun3` lifted to `mod:func/arity`,
      the arity counting the captured variables;
    * `"fun"` — the fun is a literal external fun, `&Mod.f/0`;
    * `"param"` — the fun is the calling function's parameter `param`,
      which its callers choose;
    * `"mfa"` — the module and function are literal; `arity` is the
      argument list's length when its cons cells show it, -1 otherwise;
    * `"dynamic"` — none of these. A literal module or function name
      among the M, F arguments is still in `mod` or `func`.

  `variant` is how the new process is tied to the caller: `"spawn"`,
  `"spawn_link"` or `"spawn_monitor"`, read from the function's name or
  from a literal options list (`:link`, `:monitor`, `{:monitor, opts}`;
  a link is the stronger tie and wins), and `"spawn_opt"` when the
  options are not literal. `proc_lib:start/3,4,5` is `"start"`: no link
  and no monitor, but the caller waits for the new process's
  `init_ack/1` and learns from it whether the start failed, and the
  process, being proc_lib's, reports its own crash. `start_link` is a
  linked start and `start_monitor` a monitored one. `api` is the
  spawning function, `Mod.fun/n`; `args` is the register the argument
  list arrives in for the module-function forms (-1 for a fun).
  """

  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Extractor.Terms
  @typep form :: {:fun, non_neg_integer()} | {:mfa, non_neg_integer()}
  @typep tie ::
           :spawn
           | :spawn_link
           | :spawn_monitor
           | :start
           | {:opts, non_neg_integer()}
           | {:start_opts, non_neg_integer()}

  # {mod, fun, arity} => {what runs, and where; how the process is tied}.
  @spawns (for {mod, names} <- [
                 {:erlang, [:spawn, :spawn_link, :spawn_monitor]},
                 {:proc_lib, [:spawn, :spawn_link]}
               ],
               name <- names,
               {arity, form} <- [{1, {:fun, 0}}, {2, {:fun, 1}}, {3, {:mfa, 0}}, {4, {:mfa, 1}}],
               # erlang's node-qualified spawn_monitor/2 and /4 exist
               # since OTP 23; proc_lib has no spawn_monitor.
               into: %{} do
             {{mod, name, arity}, {form, name}}
           end)
          |> Map.merge(%{
            {:erlang, :spawn_opt, 2} => {{:fun, 0}, {:opts, 1}},
            {:erlang, :spawn_opt, 3} => {{:fun, 1}, {:opts, 2}},
            {:erlang, :spawn_opt, 4} => {{:mfa, 0}, {:opts, 3}},
            {:erlang, :spawn_opt, 5} => {{:mfa, 1}, {:opts, 4}},
            {:proc_lib, :spawn_opt, 2} => {{:fun, 0}, {:opts, 1}},
            {:proc_lib, :spawn_opt, 3} => {{:fun, 1}, {:opts, 2}},
            {:proc_lib, :spawn_opt, 4} => {{:mfa, 0}, {:opts, 3}},
            {:proc_lib, :spawn_opt, 5} => {{:mfa, 1}, {:opts, 4}},
            {:proc_lib, :start, 3} => {{:mfa, 0}, :start},
            {:proc_lib, :start, 4} => {{:mfa, 0}, :start},
            {:proc_lib, :start, 5} => {{:mfa, 0}, {:start_opts, 4}},
            {:proc_lib, :start_link, 3} => {{:mfa, 0}, :spawn_link},
            {:proc_lib, :start_link, 4} => {{:mfa, 0}, :spawn_link},
            {:proc_lib, :start_link, 5} => {{:mfa, 0}, :spawn_link},
            {:proc_lib, :start_monitor, 3} => {{:mfa, 0}, :spawn_monitor},
            {:proc_lib, :start_monitor, 4} => {{:mfa, 0}, :spawn_monitor},
            {:proc_lib, :start_monitor, 5} => {{:mfa, 0}, :spawn_monitor},
            # Inlined to :erlang.spawn_opt by the Elixir compiler, but a
            # capture or an apply reaches the function itself.
            {Process, :spawn, 2} => {{:fun, 0}, {:opts, 1}},
            {Process, :spawn, 4} => {{:mfa, 0}, {:opts, 3}}
          })

  @doc "The `{mod, fun, arity}` calls this module records as spawns."
  @spec apis() :: [{module(), atom(), arity()}]
  def apis, do: @spawns |> Map.keys() |> Enum.sort()

  @doc """
  One `spawn_call` row per spawning call in `normalized`, the function's
  `{id, instruction}` pairs, as the schema orders the columns.
  """
  @spec rows(String.t(), [{String.t(), tuple() | atom()}]) :: [[String.t()]]
  def rows(func_id, normalized) do
    instrs = Enum.map(normalized, fn {_id, instr} -> instr end)

    normalized
    |> Enum.with_index()
    |> Enum.flat_map(fn {{id, instr}, idx} ->
      with {:ok, m, f, a} <- Helpers.match_remote_call(instr),
           mfa = {m, f, a},
           {:ok, {form, tie}} <- Map.fetch(@spawns, mfa) do
        [row(id, func_id, instrs, idx, mfa, form, tie)]
      else
        _ -> []
      end
    end)
  end

  @spec row(String.t(), String.t(), list(), non_neg_integer(), tuple(), form(), tie()) ::
          [String.t()]
  defp row(id, func_id, instrs, idx, {m, f, a}, form, tie) do
    {source, mod, func, arity, param} = runs(instrs, idx, form)
    args = if match?({:mfa, _}, form), do: elem(form, 1) + 2, else: -1

    [
      id,
      func_id,
      mod,
      func,
      to_string(arity),
      variant(instrs, idx, tie),
      "#{inspect(m)}.#{f}/#{a}",
      source,
      to_string(param),
      to_string(args)
    ]
  end

  # {source, mod, func, arity, param}.
  defp runs(instrs, idx, {:fun, n}) do
    case Resolve.fun_origin(instrs, idx, {:x, n}) do
      {:closure, {mod, fun, arity}} -> {"closure", inspect(mod), to_string(fun), arity, -1}
      {:external, {mod, fun, arity}} -> {"fun", inspect(mod), to_string(fun), arity, -1}
      {:param, k} -> {"param", "dynamic", "dynamic", -1, k}
      nil -> {"dynamic", "dynamic", "dynamic", -1, -1}
    end
  end

  defp runs(instrs, idx, {:mfa, n}) do
    mod = literal_atom(instrs, idx, n)
    fun = literal_atom(instrs, idx, n + 1)

    case {mod, fun} do
      {{:ok, mod}, {:ok, fun}} ->
        arity = Resolve.list_length(instrs, idx, {:x, n + 2}) || -1
        {"mfa", inspect(mod), to_string(fun), arity, -1}

      _ ->
        {"dynamic", spelled(mod, &inspect/1), spelled(fun, &to_string/1), -1, -1}
    end
  end

  defp literal_atom(instrs, idx, n) do
    case Resolve.resolve_register(instrs, idx, {:x, n}) do
      {:ok, atom} when is_atom(atom) and atom != :dynamic -> {:ok, atom}
      _ -> :error
    end
  end

  defp spelled({:ok, atom}, spell), do: spell.(atom)
  defp spelled(:error, _spell), do: "dynamic"

  defp variant(_instrs, _idx, tie) when is_atom(tie), do: to_string(tie)

  defp variant(instrs, idx, {:opts, n}), do: opts_variant(instrs, idx, n, "spawn")

  # proc_lib:start/5's spawn options: with neither a link nor a monitor
  # it is the synchronous start its /3 and /4 are.
  defp variant(instrs, idx, {:start_opts, n}), do: opts_variant(instrs, idx, n, "start")

  defp opts_variant(instrs, idx, n, untied) do
    case Resolve.resolve_register(instrs, idx, {:x, n}) do
      {:ok, opts} when is_list(opts) ->
        if Terms.proper_list?(opts), do: tie_of(opts, untied), else: "spawn_opt"

      _ ->
        "spawn_opt"
    end
  end

  defp tie_of(opts, untied) do
    cond do
      :link in opts -> "spawn_link"
      :monitor in opts or Enum.any?(opts, &match?({:monitor, _}, &1)) -> "spawn_monitor"
      Enum.any?(opts, &(&1 == :dynamic)) -> "spawn_opt"
      true -> untied
    end
  end
end
