defmodule Argus.Test.CallCount do
  @moduledoc """
  What a run executed of argus's own code (`code/0`), by counting calls
  into it.

  Counts are VM-wide: every process's calls count, so count in a VM
  doing nothing else (`Argus.Test.Peer.start!(code_path: :this)`). Turning
  counting on costs a fraction of a second; setting the counts back to
  zero, a few milliseconds, so a VM counting several runs turns it on
  once (`counting/1`) and reads each run apart (`calls/1`).
  """

  @doc "The modules counted: argus's code and its libraries', not its tests'."
  @spec code() :: [module()]
  def code do
    for app <- [:argus_beam, :beam_spy, :ctf],
        mod <- Application.spec(app, :modules) || [],
        not String.starts_with?(Atom.to_string(mod), ["Elixir.Argus.Test.", "Elixir.Inspect."]),
        do: mod
  end

  @doc "Runs `fun` with every function of `code/0` counted, and stops counting after."
  @spec counting((-> result)) :: result when result: term()
  def counting(fun) do
    code = code()
    Enum.each(code, &Code.ensure_loaded!/1)
    Enum.each(code, &:erlang.trace_pattern({&1, :_, :_}, true, [:call_count]))

    try do
      fun.()
    after
      Enum.each(code, &:erlang.trace_pattern({&1, :_, :_}, false, [:call_count]))
    end
  end

  @doc """
  Runs `fun`: its value, and the functions of `code/0` it called, with
  how often, among those counted (within `counting/1`, and not stopped
  by `stop/1`): `{value, %{mfa => calls}}`.
  """
  @spec calls((-> result)) :: {result, %{mfa() => pos_integer()}} when result: term()
  def calls(fun) do
    :erlang.trace_pattern({:_, :_, :_}, :restart, [:call_count])
    value = fun.()
    {value, called()}
  end

  defp called do
    for mod <- code(),
        {name, arity} <- mod.module_info(:functions),
        name not in [:module_info, :__info__],
        mfa = {mod, name, arity},
        # A function not counted reads `false`, which compares above
        # every number.
        {:call_count, calls} = :erlang.trace_info(mfa, :call_count),
        is_integer(calls) and calls > 0,
        into: %{},
        do: {mfa, calls}
  end

  @doc "The modules among `calls/1`'s functions."
  @spec modules(%{mfa() => pos_integer()}) :: [module()]
  def modules(calls), do: calls |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  @doc """
  Stops counting `functions` for the rest of `counting/1`: hot functions
  already known to be called, whose counters every worker bumps at once.
  """
  @spec stop([mfa()]) :: :ok
  def stop(functions), do: Enum.each(functions, &:erlang.trace_pattern(&1, false, [:call_count]))
end
