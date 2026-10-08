defmodule Argus.Extractors.Quoted do
  @moduledoc """
  Remote calls a quote names: code the program writes as data, which
  runs wherever the quote is expanded, not where the program's beams
  call.

  `phoenix_replay/2` returns a quote whose first line calls
  `PhoenixReplay.Router.__live_sessions__(path, opts)`, at the top of the
  code the macro returns: the call runs in the user's router as it
  compiles, on the options the router's source writes. No beam calls
  `__live_sessions__/2`, and its parameters are not a runtime caller's.
  A call inside a function the quote defines (`def handle_event(e, p,
  s), do: Lib.__event__(p)`) is the opposite: it runs whenever the
  generated function does, on what its caller hands it.

  A quote's constant parts are literals in the bytecode; the parts it
  unquotes are built around them at runtime. Every literal is read for
  calls inside a `def`, `defp`, `defmacro`, `defmacrop`, `fn` or nested
  `quote` it holds. A macro's return value is rebuilt as far as its
  instructions say (`Argus.Extractor.Resolve.resolve_register/3`) and
  read whole, so a call at its top is told from one inside a function
  it defines even when that function's head is unquoted.

  ## Emitted facts

  - `quoted_call(func, mod, name, arity, context)`: `func`'s quote names
    `mod.name/arity` (`-1` when the arguments are unquoted as a list
    this cannot count). `context` is `function` for a call inside a
    function or nested quote the quote defines, or `expansion` for one
    at the top of the code a macro returns, which runs wherever the
    macro expands. A call at the top of a quote a function builds for
    some other use is neither and is not emitted: where it runs depends
    on where that quote ends up. An `expansion` row needs a known arity.

  The module is the call's literal: an atom, or an alias as the quote
  expanded it. A call on `__MODULE__` or on an unquoted module names the
  expansion site's module and is not emitted.
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Facts, only: [add_fact: 3]

  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.InstrId

  @function_forms [:def, :defp, :defmacro, :defmacrop, :fn, :quote]

  @impl true
  def relations, do: [:quoted_call]

  @impl true
  @doc false
  def candidate_instructions?(instructions),
    do: Enum.any?(instructions, fn instr -> instr |> literals() |> Enum.any?(&names_call?/1) end)

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(%{module: mod, functions: functions}) do
    rows =
      for {:function, name, arity, _entry, instrs} <- functions,
          candidate_instructions?(instrs),
          func_id = InstrId.func_id(mod, name, arity),
          {callee_mod, callee, callee_arity, context} <- calls(name, instrs),
          uniq: true,
          do: [func_id, callee_mod, callee, Integer.to_string(callee_arity), context]

    rows
    |> Enum.sort()
    |> Enum.reduce(%{}, &add_fact(&2, :quoted_call, &1))
  end

  # The calls a function's quotes name: those inside a function in any
  # literal, and, for a macro, every one in the code it returns.
  defp calls(name, instrs) do
    in_literals =
      for instr <- instrs,
          literal <- literals(instr),
          {_, _, _, "function"} = call <- walk(literal, :top, false, []),
          do: call

    returned =
      if String.starts_with?(Atom.to_string(name), "MACRO-"),
        do: returned_calls(instrs),
        else: []

    Enum.reject(in_literals ++ returned, &match?({_, _, -1, "expansion"}, &1))
  end

  defp returned_calls(instrs) do
    for {instr, idx} <- Enum.with_index(instrs),
        returns_quote?(instr),
        {:ok, term} <- [Resolve.resolve_register(instrs, idx, {:x, 0})],
        call <- walk(term, :top, true, []),
        do: call
  end

  # A macro returns its quote, or, since Elixir 1.20, hands it to
  # `:elixir_quote.validate_quote/1`, which returns it as it is.
  defp returns_quote?(:return), do: true

  defp returns_quote?(instr),
    do: Helpers.match_remote_call(instr) == {:ok, :elixir_quote, :validate_quote, 1}

  # The literal operands an instruction holds, at any depth.
  defp literals({:literal, term}), do: [term]
  defp literals(instr) when is_tuple(instr), do: instr |> Tuple.to_list() |> literals()
  defp literals(list) when is_list(list), do: Enum.flat_map(list, &literals/1)
  defp literals(_operand), do: []

  # A quoted remote call's `.` node, whose call around it may be built at
  # runtime when its arguments are unquoted.
  defp names_call?({:., meta, [target, fun]}) when is_list(meta) and is_atom(fun),
    do: module(target) != :error or names_call?(target)

  defp names_call?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> names_call?()
  defp names_call?([head | tail]), do: names_call?(head) or names_call?(tail)
  defp names_call?(_leaf), do: false

  # The calls a quoted term names, as {mod, name, arity, context}, read
  # from `context` down and added to `acc`. `rebuilt` says the term came
  # back from `resolve_register/3`, whose `:dynamic` stands for a part it
  # could not rebuild: a list ending in one has a tail it does not know.
  defp walk({{:., _, [target, fun]}, meta, args}, context, rebuilt, acc)
       when is_atom(fun) and fun != :dynamic and is_list(meta) do
    acc =
      case module(target) do
        {:ok, mod} ->
          [{mod, InstrId.name(fun), arity(args, rebuilt), context_name(context)} | acc]

        :error ->
          acc
      end

    walk(args, context, rebuilt, walk(target, context, rebuilt, acc))
  end

  defp walk({form, meta, args}, _context, rebuilt, acc)
       when form in @function_forms and is_list(meta) and is_list(args),
       do: walk(args, :function, rebuilt, acc)

  defp walk(tuple, context, rebuilt, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> walk(context, rebuilt, acc)

  defp walk([head | tail], context, rebuilt, acc),
    do: walk(tail, context, rebuilt, walk(head, context, rebuilt, acc))

  defp walk(_leaf, _context, _rebuilt, acc), do: acc

  defp context_name(:top), do: "expansion"
  defp context_name(:function), do: "function"

  defp arity(args, rebuilt) do
    case proper_length(args, 0) do
      {:ok, n} -> if rebuilt and List.last(args) == :dynamic, do: -1, else: n
      :error -> -1
    end
  end

  defp proper_length([], n), do: {:ok, n}
  defp proper_length([_ | tail], n), do: proper_length(tail, n + 1)
  defp proper_length(_not_a_list, _n), do: :error

  # The module a call's target names: an atom, or an alias (`alias:` is
  # the module the quote expanded it to; `false` leaves it as written).
  # Not `:dynamic`, the placeholder for a part that was not rebuilt.
  defp module(mod) when is_atom(mod) and mod not in [nil, true, false, :dynamic],
    do: {:ok, inspect(mod)}

  defp module({:__aliases__, meta, [_ | _] = parts}) when is_list(meta) do
    with true <- Enum.all?(parts, &is_atom/1),
         {:ok, expanded} <- alias_meta(meta) do
      {:ok, inspect(expanded || Module.concat(parts))}
    else
      _ -> :error
    end
  end

  defp module(_target), do: :error

  # The `alias:` an alias's metadata records: the module, or nil for
  # `false` or none.
  defp alias_meta([{:alias, false} | _]), do: {:ok, nil}
  defp alias_meta([{:alias, mod} | _]) when is_atom(mod), do: {:ok, mod}
  defp alias_meta([{:alias, _other} | _]), do: :error
  defp alias_meta([_ | rest]), do: alias_meta(rest)
  defp alias_meta(_end), do: {:ok, nil}
end
