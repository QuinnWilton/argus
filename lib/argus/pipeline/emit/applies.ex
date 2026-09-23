defmodule Argus.Pipeline.Emit.Applies do
  @moduledoc """
  The `resolved_apply` rows of one function: the applies whose target
  the values reaching them name.

  Every apply is a `dynamic_call` — at the instruction level its target
  is computed — but the computation is often visible. The compiler turns
  an apply whose module, function and argument count it can see into a
  direct call, so what is left is what it could not fold:

    * the `apply` instruction (`apply(m, f, [a, b])`, argument count
      known): the module in `x(N)` and the function in `x(N+1)`, resolved
      through the writes that reach them;
    * `erlang:apply/3` (argument list of unknown shape): the module and
      function in `x0` and `x1`, the arity the list's cons cells show;
    * `erlang:apply/2`: the function a fun runs, when `x0` holds a
      closure or a literal external fun (`Resolve.fun_origin/3`).

  A resolved apply is a call: the call graph follows it, and the effect
  model classifies its target instead of reporting the apply opaque.
  """

  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.InstrId

  @doc """
  The target of the apply at `idx` of `instrs`, or `:error` when it is
  not an apply or its target does not resolve.
  """
  @spec resolve([tuple() | atom()], non_neg_integer(), tuple() | atom()) ::
          {:ok, {module(), atom(), arity()}} | :error
  def resolve(instrs, idx, {:apply, n}), do: module_function(instrs, idx, n, n)
  def resolve(instrs, idx, {:apply_last, n, _dealloc}), do: module_function(instrs, idx, n, n)

  def resolve(instrs, idx, instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, :erlang, :apply, 3} ->
        case Resolve.list_length(instrs, idx, {:x, 2}) do
          n when is_integer(n) -> module_function(instrs, idx, 0, n)
          nil -> :error
        end

      {:ok, :erlang, :apply, 2} ->
        case Resolve.fun_target(instrs, idx, {:x, 0}) do
          {_mod, _fun, _arity} = mfa -> {:ok, mfa}
          nil -> :error
        end

      _ ->
        :error
    end
  end

  @doc """
  One `[id, caller, target]` row per apply in `normalized` (the
  function's `{id, instruction}` pairs) whose target resolves.
  """
  @spec rows(String.t(), [{String.t(), tuple() | atom()}]) :: [[String.t()]]
  def rows(func_id, normalized) do
    instrs = Enum.map(normalized, fn {_id, instr} -> instr end)

    normalized
    |> Enum.with_index()
    |> Enum.flat_map(fn {{id, instr}, idx} ->
      case resolve(instrs, idx, instr) do
        {:ok, {mod, fun, arity}} -> [[id, func_id, InstrId.func_id(mod, fun, arity)]]
        :error -> []
      end
    end)
  end

  # The module in x(first) and the function in x(first + 1).
  defp module_function(instrs, idx, first, arity) do
    with {:ok, mod} when is_atom(mod) and mod != :dynamic <-
           Resolve.resolve_register(instrs, idx, {:x, first}),
         {:ok, fun} when is_atom(fun) and fun != :dynamic <-
           Resolve.resolve_register(instrs, idx, {:x, first + 1}) do
      {:ok, {mod, fun, arity}}
    else
      _ -> :error
    end
  end
end
