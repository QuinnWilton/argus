defmodule Argus.Extractor.Argv do
  @moduledoc """
  What an argument list is on every path to the call it is handed to:
  whether it is literal through and through (`literal?/4`), and which
  literals it can start with (`heads/4`).

  `Argus.Extractor.Resolve.resolve_register/3` answers the one value
  every path agrees on, and `["compile"] ++ if(force, do: ["--force"],
  else: [])` has none: it is one of two lists. Each is literal, though,
  and a shell handed either runs only what the program wrote. The walk
  here asks every path instead: a join is literal when each way into it
  is, a cons cell when its head and tail are, an append (`++`) when both
  operands are, and an element taken out of a literal is literal.

  A scope says how far the walk may look. `function/1` is one function's
  body, all a function-local extractor sees; `module/1` is the module's,
  where a local call's result is literal when every way the callee
  returns hands back a literal (a `return`, or a tail call to a local
  function or to `++`; a raising tail call returns nothing), and a
  parameter of a function the module neither exports nor captures as a
  fun is what each of its callers passes there: they are all in the
  module, at its local calls.

  A list starts as its first cons cell's head does, or as a literal list
  does; `left ++ right` starts as `left` does, or as `right` does where
  `left` is empty. So `["credo" | opts] ++ more` starts with `"credo"`
  whatever `opts` and `more` are.

  Whatever the walk cannot follow (a parameter of a function with callers
  outside the module, a remote call's result, a function outside the
  scope, a cycle met again while it is still being answered) is not
  literal and starts with nothing known: the quiet direction for a
  sanitizer, since a call handed an unknown list stays a finding.
  """

  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Instr
  alias Argus.Instr.Reaching

  @typedoc "A function in a scope: `{name, arity}`, or `:self` in `function/1`'s."
  @type key :: {atom(), arity()} | :self

  @typedoc """
  The functions a walk may read (`functions`), the module whose local
  calls it follows into them (`nil` for none), and, for each function
  whose every caller the scope sees, its call sites (`callers`).
  """
  @type scope :: %{
          module: module() | nil,
          functions: %{key() => [tuple()]},
          callers: %{key() => [{key(), non_neg_integer()}]}
        }

  @typedoc "How a list starts: with a literal element, or empty."
  @type head :: {:value, term()} | :empty

  @appends [erlang: :++, lists: :append]

  # More first elements than this and a list starts with nothing known.
  @max_heads 64

  # Calls that never return: a tail call to one hands back no value.
  @raising [error: 1, error: 2, exit: 1, throw: 1, raise: 3, nif_error: 1]

  @memo :argus_argv_memo

  @doc "One function's body, as `:self`: no local call is followed."
  @spec function([tuple()]) :: {scope(), key()}
  def function(instrs), do: {%{module: nil, functions: %{self: instrs}, callers: %{}}, :self}

  @doc """
  The module's functions, each under `{name, arity}`, with the local call
  sites of each that has callers, none of them outside the module: one
  the module does not export, and does not make a fun of (`&helper/1`
  can be called from anywhere it is handed).
  """
  @spec module(map()) :: scope()
  def module(%{module: mod, functions: functions} = data) do
    open =
      MapSet.new(
        Enum.map(Map.get(data, :exports, []), &export_key/1) ++
          for(
            {:function, _, _, _, instrs} <- functions,
            {:make_fun3, {^mod, f, a}, _index, _uniq, _dst, _env} <- instrs,
            do: {f, a}
          )
      )

    callers =
      for {:function, name, arity, _, instrs} <- functions,
          {instr, idx} <- Enum.with_index(instrs),
          {:ok, ^mod, f, a} <- [Helpers.match_local_call(instr)],
          not MapSet.member?(open, {f, a}),
          reduce: %{} do
        acc -> Map.update(acc, {f, a}, [{{name, arity}, idx}], &[{{name, arity}, idx} | &1])
      end

    %{
      module: mod,
      functions:
        Map.new(functions, fn {:function, name, arity, _, instrs} -> {{name, arity}, instrs} end),
      callers: Map.new(callers, fn {key, sites} -> {key, Enum.reverse(sites)} end)
    }
  end

  defp export_key({name, arity, _label}), do: {name, arity}
  defp export_key({:atom, name, arity, _label}), do: {name, arity}

  @doc """
  Whether `register` holds a literal at `idx` in the function `key`, on
  every path there.
  """
  @spec literal?(scope(), key(), non_neg_integer(), Resolve.register()) :: boolean()
  def literal?(scope, key, idx, register),
    do: walk(fn -> literal(scope, key, idx, Instr.register(register)) end)

  defp literal(scope, key, idx, reg) do
    step({:literal, key, idx, reg}, false, fn ->
      instrs = Map.fetch!(scope.functions, key)

      case Resolve.writers(instrs, idx, reg) do
        [] -> false
        writers -> Enum.all?(writers, &written_literal?(scope, key, instrs, &1))
      end
    end)
  end

  # Copies are followed by `Resolve.writers/3`: a writer here made the
  # value, or is the parameter it came in as.
  defp written_literal?(scope, key, _instrs, {:param, k}) do
    case Map.fetch(scope.callers, key) do
      {:ok, sites} ->
        Enum.all?(sites, fn {caller, idx} -> literal(scope, caller, idx, {:x, k}) end)

      :error ->
        false
    end
  end

  defp written_literal?(scope, key, instrs, at) do
    case Reaching.at(instrs, at) do
      {op, src, _dst} when op in [:move, :fmove] ->
        operand_literal?(scope, key, at, src)

      {:put_list, head, tail, _dst} ->
        operand_literal?(scope, key, at, head) and operand_literal?(scope, key, at, tail)

      {:put_tuple2, _dst, {:list, elements}} ->
        Enum.all?(elements, &operand_literal?(scope, key, at, &1))

      {:get_tuple_element, src, _index, _dst} ->
        operand_literal?(scope, key, at, src)

      {:get_hd, src, _dst} ->
        operand_literal?(scope, key, at, src)

      {:get_tl, src, _dst} ->
        operand_literal?(scope, key, at, src)

      {:get_list, src, _head, _tail} ->
        operand_literal?(scope, key, at, src)

      instr ->
        call_literal?(scope, key, at, instr)
    end
  end

  # A call wrote `x0`: an append of literals, or a local function's result.
  defp call_literal?(scope, key, at, instr) do
    case {Helpers.match_remote_call(instr), local_target(scope, instr)} do
      {{:ok, m, f, 2}, _local} when {m, f} in @appends ->
        literal(scope, key, at, {:x, 0}) and literal(scope, key, at, {:x, 1})

      {_remote, {:ok, callee}} ->
        returns_literal?(scope, callee)

      _other ->
        false
    end
  end

  defp operand_literal?(scope, key, at, operand) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] -> literal(scope, key, at, reg)
      nil -> true
      {kind, _} when kind in [:atom, :literal, :integer, :float] -> true
      _other -> false
    end
  end

  # Every way out of `callee` hands back a literal.
  defp returns_literal?(scope, callee) do
    step({:returns_literal, callee}, false, fn ->
      case Map.fetch(scope.functions, callee) do
        {:ok, instrs} ->
          instrs
          |> exits(scope)
          |> Enum.all?(fn
            {:return, idx} ->
              literal(scope, callee, idx, {:x, 0})

            {:tail, next} ->
              returns_literal?(scope, next)

            {:append, idx} ->
              literal(scope, callee, idx, {:x, 0}) and literal(scope, callee, idx, {:x, 1})

            :raises ->
              true

            :unknown ->
              false
          end)

        :error ->
          false
      end
    end)
  end

  @doc """
  The values the list in `register` at `idx` in the function `key` can
  start with, on every path there: `{:value, term}` for a literal first
  element, `:empty` for the empty list. `:unknown` when some path's
  list starts with something the walk cannot read, or when there are
  more than #{@max_heads} of them.
  """
  @spec heads(scope(), key(), non_neg_integer(), Resolve.register()) :: {:ok, [head()]} | :unknown
  def heads(scope, key, idx, register),
    do: walk(fn -> list_heads(scope, key, idx, Instr.register(register)) end)

  defp list_heads(scope, key, idx, reg) do
    step({:heads, key, idx, reg}, :unknown, fn ->
      instrs = Map.fetch!(scope.functions, key)

      case Resolve.writers(instrs, idx, reg) do
        [] -> :unknown
        writers -> union(writers, &written_heads(scope, key, instrs, &1))
      end
    end)
  end

  defp written_heads(scope, key, _instrs, {:param, k}),
    do: at_callers(scope, key, &list_heads(scope, &1, &2, {:x, k}))

  defp written_heads(scope, key, instrs, at) do
    case Reaching.at(instrs, at) do
      {op, src, _dst} when op in [:move, :fmove] ->
        case literal_value(src) do
          {:ok, [head | _]} -> {:ok, [{:value, head}]}
          {:ok, []} -> {:ok, [:empty]}
          _other -> :unknown
        end

      {:put_list, head, _tail, _dst} ->
        with {:ok, values} <- element_values(scope, key, at, head),
             do: {:ok, Enum.map(values, &{:value, &1})}

      instr ->
        call_heads(scope, key, at, instr)
    end
  end

  defp call_heads(scope, key, at, instr) do
    case {Helpers.match_remote_call(instr), local_target(scope, instr)} do
      {{:ok, m, f, 2}, _local} when {m, f} in @appends ->
        append_heads(scope, key, at)

      {_remote, {:ok, callee}} ->
        returns_heads(scope, callee)

      _other ->
        :unknown
    end
  end

  # `left ++ right` starts as `left` does, or as `right` does where
  # `left` is empty.
  defp append_heads(scope, key, at) do
    case list_heads(scope, key, at, {:x, 0}) do
      {:ok, left} ->
        if :empty in left,
          do: union([{:ok, left -- [:empty]}, list_heads(scope, key, at, {:x, 1})], & &1),
          else: {:ok, left}

      :unknown ->
        :unknown
    end
  end

  defp returns_heads(scope, callee) do
    step({:returns_heads, callee}, :unknown, fn ->
      case Map.fetch(scope.functions, callee) do
        {:ok, instrs} ->
          instrs
          |> exits(scope)
          |> union(fn
            {:return, idx} -> list_heads(scope, callee, idx, {:x, 0})
            {:tail, next} -> returns_heads(scope, next)
            {:append, idx} -> append_heads(scope, callee, idx)
            :raises -> {:ok, []}
            :unknown -> :unknown
          end)

        :error ->
          :unknown
      end
    end)
  end

  # The literal values an element can be on every path: a literal, or a
  # register every writer of which copies one in.
  defp element_values(scope, key, at, operand) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] -> register_values(scope, key, at, reg)
      _literal -> literal_values(operand)
    end
  end

  defp register_values(scope, key, idx, reg) do
    step({:values, key, idx, reg}, :unknown, fn ->
      instrs = Map.fetch!(scope.functions, key)

      case Resolve.writers(instrs, idx, reg) do
        [] ->
          :unknown

        writers ->
          union(writers, &written_values(scope, key, instrs, &1))
      end
    end)
  end

  defp written_values(scope, key, _instrs, {:param, k}),
    do: at_callers(scope, key, &register_values(scope, &1, &2, {:x, k}))

  defp written_values(_scope, _key, instrs, at) do
    case Reaching.at(instrs, at) do
      {op, src, _dst} when op in [:move, :fmove] -> literal_values(src)
      _other -> :unknown
    end
  end

  defp literal_values(operand) do
    case literal_value(operand) do
      {:ok, value} -> {:ok, [value]}
      :unknown -> :unknown
    end
  end

  defp literal_value(operand) do
    case Instr.register(operand) do
      nil -> {:ok, []}
      {kind, value} when kind in [:atom, :literal, :integer, :float] -> {:ok, value}
      _other -> :unknown
    end
  end

  # The union of what each item answers, or `:unknown` when one does, or
  # when the union outgrows `@max_heads`.
  defp union(items, answer) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case answer.(item) do
        {:ok, more} ->
          set = Enum.uniq(more ++ acc)
          if length(set) > @max_heads, do: {:halt, :unknown}, else: {:cont, {:ok, set}}

        _unknown ->
          {:halt, :unknown}
      end
    end)
    |> case do
      {:ok, set} -> {:ok, Enum.sort(set)}
      :unknown -> :unknown
    end
  end

  # What every caller of `key` answers at its call: none when the scope
  # cannot see them all.
  defp at_callers(scope, key, answer) do
    case Map.fetch(scope.callers, key) do
      {:ok, sites} -> union(sites, fn {caller, idx} -> answer.(caller, idx) end)
      :error -> :unknown
    end
  end

  # How a function hands back a value: a `return` of `x0`, a tail call to
  # a local function or to an append (whose operands are `x0` and `x1`
  # there), a raising tail call (no value), or another tail call, whose
  # result the walk cannot read.
  defp exits(instrs, scope) do
    instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {:return, idx} ->
        [{:return, idx}]

      {instr, idx} ->
        if Instr.tail_call?(instr), do: [tail_exit(scope, instr, idx)], else: []
    end)
  end

  defp tail_exit(scope, instr, idx) do
    case {Helpers.match_remote_call(instr), local_target(scope, instr)} do
      {{:ok, m, f, 2}, _local} when {m, f} in @appends -> {:append, idx}
      {{:ok, :erlang, f, a}, _local} when {f, a} in @raising -> :raises
      {_remote, {:ok, callee}} -> {:tail, callee}
      _other -> :unknown
    end
  end

  defp local_target(%{module: mod}, instr) when mod != nil do
    case Helpers.match_local_call(instr) do
      {:ok, ^mod, f, a} -> {:ok, {f, a}}
      _other -> :none
    end
  end

  defp local_target(_scope, _instr), do: :none

  # Each question is memoized for the length of one walk, which keeps a
  # chain of joins from multiplying its paths and breaks the cycles that
  # loops and recursion make: a step met again while it is still being
  # answered answers `none`.
  defp walk(fun) do
    outer = Process.get(@memo)
    Process.put(@memo, %{})

    try do
      fun.()
    after
      if outer, do: Process.put(@memo, outer), else: Process.delete(@memo)
    end
  end

  defp step(question, none, compute) do
    memo = Process.get(@memo, %{})

    case Map.fetch(memo, question) do
      {:ok, :in_progress} ->
        none

      {:ok, answer} ->
        answer

      :error ->
        Process.put(@memo, Map.put(memo, question, :in_progress))
        answer = compute.()
        Process.put(@memo, Map.put(Process.get(@memo, %{}), question, answer))
        answer
    end
  end
end
