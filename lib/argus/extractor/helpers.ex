defmodule Argus.Extractor.Helpers do
  @moduledoc """
  Shared helpers for domain-specific fact extractors.

  Provides shared capabilities that extractors commonly need:

  - **`add_fact/3`** — accumulate a row into a relation map
  - **`match_remote_call/1`** — recognize `call_ext` variants as `{mod, func, arity}`
  - **`resolve_register/3`** — backward dataflow: determine a register's value
    at a specific call site by walking preceding instructions
  - **`get_behaviours/1`** — extract behaviour modules from attributes
  - **`match_local_call/1`** — recognize intra-module `call` variants as `{mod, func, arity}`
  - **`find_function/3`** — look up a function's instructions by name and arity
  """

  @type register :: {:x, non_neg_integer()} | {:y, non_neg_integer()}

  # --- Fact accumulation ---

  @doc """
  Append a row to the given relation in a facts map.
  """
  @spec add_fact(Argus.Emitter.facts(), atom(), [String.t()]) :: Argus.Emitter.facts()
  def add_fact(facts, relation, row) do
    Map.update(facts, relation, [row], &[row | &1])
  end

  # --- Attribute helpers ---

  @doc """
  Extract behaviour modules from a module's attributes.

  Handles both `:behaviour` and `:behavior` spellings.
  """
  @spec get_behaviours(keyword()) :: [module()]
  def get_behaviours(attrs) do
    (Keyword.get_values(attrs, :behaviour) ++ Keyword.get_values(attrs, :behavior))
    |> List.flatten()
  end

  # --- Remote call matching ---

  @doc """
  Match a BEAM instruction as a remote (external) function call.

  Returns `{:ok, module, function, arity}` for `call_ext`, `call_ext_only`,
  and `call_ext_last` instructions, or `:none` for anything else.
  """
  @spec match_remote_call(term()) :: {:ok, module(), atom(), arity()} | :none
  def match_remote_call({:call_ext, _arity, {:extfunc, mod, func, a}}),
    do: {:ok, mod, func, a}

  def match_remote_call({:call_ext_only, _arity, {:extfunc, mod, func, a}}),
    do: {:ok, mod, func, a}

  def match_remote_call({:call_ext_last, _arity, {:extfunc, mod, func, a}, _deallocate}),
    do: {:ok, mod, func, a}

  def match_remote_call(_), do: :none

  # --- Local call matching ---

  @doc """
  Match a BEAM instruction as a local (intra-module) function call.

  Returns `{:ok, module, function, arity}` for `call`, `call_only`, and
  `call_last` instructions with MFA targets, or `:none` for anything else.
  """
  @spec match_local_call(term()) :: {:ok, module(), atom(), arity()} | :none
  def match_local_call({:call, _arity, {mod, func, a}}), do: {:ok, mod, func, a}
  def match_local_call({:call_only, _arity, {mod, func, a}}), do: {:ok, mod, func, a}
  def match_local_call({:call_last, _arity, {mod, func, a}, _deallocate}), do: {:ok, mod, func, a}
  def match_local_call(_), do: :none

  # --- Function lookup ---

  @doc """
  Find a function's instruction list by name and arity.

  Returns the instruction list, or `nil` if the function is not found.
  """
  @spec find_function([term()], atom(), non_neg_integer()) :: [term()] | nil
  def find_function(functions, name, arity) do
    Enum.find_value(functions, fn
      {:function, ^name, ^arity, _, instrs} -> instrs
      _ -> nil
    end)
  end

  # --- Backward register resolution ---

  @doc """
  Resolve the value of `register` at instruction index `call_idx` by walking
  backward through the instruction list.

  Handles moves (atom, literal, integer, register-to-register), `put_list`
  chains (cons cell construction), `put_tuple2` (tuple construction),
  `put_map_assoc`/`put_map_exact` (map construction),
  `get_map_elements` (map pattern matching), and typed register
  wrappers (`{:tr, reg, type}`).

  Returns `{:ok, term}` with the reconstructed Elixir value, or `:dynamic`
  when the value cannot be statically determined. Partially resolvable
  structures use `:dynamic` as a placeholder for unknown components
  (e.g. `{:ok, {:heir, :dynamic, nil}}`).
  """
  @spec resolve_register([term()], non_neg_integer(), register()) :: {:ok, term()} | :dynamic
  def resolve_register(instrs, call_idx, register) do
    preceding = instrs |> Enum.take(call_idx) |> Enum.reverse()
    do_resolve(preceding, register)
  end

  # Walk the reversed instruction list looking for the most recent write
  # to the target register. Each instruction is consumed once — the tail
  # is passed forward to prevent revisiting.
  #
  # Barrier instructions (return, tail calls) mark execution path
  # boundaries — code before them belongs to a different clause or
  # branch, so any register values found there are stale.
  defp do_resolve([], _reg), do: :dynamic

  defp do_resolve([instr | rest], reg) do
    cond do
      barrier?(instr) -> :dynamic
      writes_to?(instr, reg) -> interpret(instr, rest, reg)
      true -> do_resolve(rest, reg)
    end
  end

  # Control-flow-terminating instructions mark the end of an execution
  # path. In the flat BEAM instruction list, code before a barrier
  # belongs to a different clause or branch — register values from
  # that code are not reachable on the path leading to our call site.
  defp barrier?(:return), do: true
  defp barrier?({:call_only, _, _}), do: true
  defp barrier?({:call_ext_only, _, _}), do: true
  defp barrier?({:call_last, _, _, _}), do: true
  defp barrier?({:call_ext_last, _, _, _}), do: true
  defp barrier?({:apply_last, _}), do: true
  defp barrier?(_), do: false

  # Check whether an instruction writes to the target register,
  # accounting for `{:tr, reg, _type}` wrappers.
  #
  # Instructions with explicit destination registers.
  defp writes_to?({:move, _, dst}, reg), do: reg_matches?(dst, reg)
  defp writes_to?({:put_list, _, _, dst}, reg), do: reg_matches?(dst, reg)
  defp writes_to?({:put_tuple2, dst, _}, reg), do: reg_matches?(dst, reg)
  defp writes_to?({:put_map_assoc, _, _, dst, _, _}, reg), do: reg_matches?(dst, reg)
  defp writes_to?({:put_map_exact, _, _, dst, _, _}, reg), do: reg_matches?(dst, reg)
  defp writes_to?({:bif, _, _, _, dst}, reg), do: reg_matches?(dst, reg)
  defp writes_to?({:gc_bif, _, _, _, _, dst}, reg), do: reg_matches?(dst, reg)
  defp writes_to?({:get_tuple_element, _, _, dst}, reg), do: reg_matches?(dst, reg)
  defp writes_to?({:get_hd, _, dst}, reg), do: reg_matches?(dst, reg)
  defp writes_to?({:get_tl, _, dst}, reg), do: reg_matches?(dst, reg)
  defp writes_to?({:update_record, _, _, _, dst, _}, reg), do: reg_matches?(dst, reg)
  defp writes_to?({:bs_create_bin, _, _, _, _, dst, _}, reg), do: reg_matches?(dst, reg)

  # swap writes to both registers.
  defp writes_to?({:swap, reg_a, reg_b}, reg),
    do: reg_matches?(reg_a, reg) or reg_matches?(reg_b, reg)

  # get_map_elements writes to multiple registers interleaved in the pair list.
  defp writes_to?({:get_map_elements, _, _, {:list, pairs}}, reg) do
    pairs
    |> Enum.drop(1)
    |> Enum.take_every(2)
    |> Enum.any?(&reg_matches?(&1, reg))
  end

  # Call instructions implicitly write their return value to x0.
  defp writes_to?({:call, _, _}, {:x, 0}), do: true
  defp writes_to?({:call_ext, _, _}, {:x, 0}), do: true
  defp writes_to?({:call_fun, _}, {:x, 0}), do: true
  defp writes_to?({:call_fun2, _, _, _}, {:x, 0}), do: true
  defp writes_to?({:apply, _}, {:x, 0}), do: true
  defp writes_to?(_, _), do: false

  defp reg_matches?(reg, reg), do: true
  defp reg_matches?({:tr, reg, _}, reg), do: true
  defp reg_matches?(_, _), do: false

  # Interpret a matched instruction to extract its value.
  # The `reg` parameter is the target register being resolved — most
  # instructions ignore it since they write to a single register, but
  # `get_map_elements` needs it to identify which key/dst pair matched.
  defp interpret({:move, src, _dst}, rest, _reg), do: resolve_source(rest, src)
  defp interpret({:put_list, head, tail, _dst}, rest, _reg), do: resolve_list(rest, head, tail)

  defp interpret({:put_tuple2, _dst, {:list, elements}}, rest, _reg),
    do: resolve_tuple(rest, elements)

  defp interpret({:put_map_assoc, _, src, _dst, _, {:list, pairs}}, rest, _reg),
    do: resolve_map(rest, src, pairs)

  defp interpret({:put_map_exact, _, src, _dst, _, {:list, pairs}}, rest, _reg),
    do: resolve_map(rest, src, pairs)

  # swap exchanges two registers — resolve the other one.
  defp interpret({:swap, reg_a, reg_b}, rest, reg) do
    other = if reg_matches?(reg_a, reg), do: reg_b, else: reg_a
    resolve_source(rest, other)
  end

  defp interpret({:bif, _, _, _, _dst}, _rest, _reg), do: :dynamic
  defp interpret({:gc_bif, _, _, _, _, _dst}, _rest, _reg), do: :dynamic

  defp interpret({:get_tuple_element, src, idx, _dst}, rest, _reg) do
    case resolve_source(rest, src) do
      {:ok, tuple} when is_tuple(tuple) and idx < tuple_size(tuple) ->
        {:ok, elem(tuple, idx)}

      _ ->
        :dynamic
    end
  end

  defp interpret({:get_hd, src, _dst}, rest, _reg) do
    case resolve_source(rest, src) do
      {:ok, [head | _]} -> {:ok, head}
      _ -> :dynamic
    end
  end

  defp interpret({:get_tl, src, _dst}, rest, _reg) do
    case resolve_source(rest, src) do
      {:ok, [_ | tail]} -> {:ok, tail}
      _ -> :dynamic
    end
  end

  # Extract a value from a map pattern match. Finds the key paired with
  # the matched destination register, resolves the source map, and
  # extracts the value.
  defp interpret({:get_map_elements, _, src, {:list, pairs}}, rest, reg) do
    case find_map_key(pairs, reg) do
      {:ok, key_operand} ->
        case resolve_source(rest, src) do
          {:ok, map} when is_map(map) ->
            key = resolve_element(rest, key_operand)
            Map.get(map, key) |> ok_or_dynamic()

          _ ->
            :dynamic
        end

      :none ->
        :dynamic
    end
  end

  defp interpret({:update_record, _, _, _, _dst, _}, _rest, _reg), do: :dynamic
  defp interpret({:bs_create_bin, _, _, _, _, _dst, _}, _rest, _reg), do: :dynamic
  defp interpret({:call, _, _}, _rest, _reg), do: :dynamic
  defp interpret({:call_ext, _, _}, _rest, _reg), do: :dynamic
  defp interpret({:call_fun, _}, _rest, _reg), do: :dynamic
  defp interpret({:call_fun2, _, _, _}, _rest, _reg), do: :dynamic
  defp interpret({:apply, _}, _rest, _reg), do: :dynamic

  # Resolve a move source to its value.
  defp resolve_source(_rest, {:atom, a}), do: {:ok, a}
  defp resolve_source(_rest, {:literal, v}), do: {:ok, v}
  defp resolve_source(_rest, {:integer, n}), do: {:ok, n}
  defp resolve_source(_rest, nil), do: {:ok, nil}
  defp resolve_source(rest, {:x, _} = src_reg), do: do_resolve(rest, src_reg)
  defp resolve_source(rest, {:y, _} = src_reg), do: do_resolve(rest, src_reg)
  defp resolve_source(rest, {:tr, inner_reg, _}), do: do_resolve(rest, inner_reg)
  defp resolve_source(_rest, _), do: :dynamic

  # Resolve a put_list instruction into a proper list.
  defp resolve_list(rest, head, tail) do
    head_val = resolve_element(rest, head)

    tail_val =
      case tail do
        {:literal, list} when is_list(list) -> {:ok, list}
        nil -> {:ok, []}
        {:x, _} = tail_reg -> do_resolve(rest, tail_reg)
        {:y, _} = tail_reg -> do_resolve(rest, tail_reg)
        {:tr, inner_reg, _} -> do_resolve(rest, inner_reg)
        _ -> :dynamic
      end

    case tail_val do
      {:ok, tail_list} when is_list(tail_list) -> {:ok, [head_val | tail_list]}
      :dynamic -> {:ok, [head_val | [:dynamic]]}
      _ -> :dynamic
    end
  end

  # Resolve a single element — used for put_list heads and put_tuple2 elements.
  defp resolve_element(_rest, {:atom, a}), do: a
  defp resolve_element(_rest, {:literal, v}), do: v
  defp resolve_element(_rest, {:integer, n}), do: n
  defp resolve_element(_rest, nil), do: nil

  defp resolve_element(rest, {:x, _} = reg) do
    case do_resolve(rest, reg) do
      {:ok, val} -> val
      :dynamic -> :dynamic
    end
  end

  defp resolve_element(rest, {:y, _} = reg) do
    case do_resolve(rest, reg) do
      {:ok, val} -> val
      :dynamic -> :dynamic
    end
  end

  defp resolve_element(rest, {:tr, inner_reg, _}) do
    case do_resolve(rest, inner_reg) do
      {:ok, val} -> val
      :dynamic -> :dynamic
    end
  end

  defp resolve_element(_rest, _), do: :dynamic

  # Resolve a put_tuple2 instruction into an Elixir tuple.
  defp resolve_tuple(rest, elements) do
    values = Enum.map(elements, &resolve_element(rest, &1))
    {:ok, List.to_tuple(values)}
  end

  # Find the key operand paired with a destination register in a
  # get_map_elements pair list. Pairs alternate: [key1, dst1, key2, dst2, ...].
  defp find_map_key([], _reg), do: :none

  defp find_map_key([key, dst | rest], reg) do
    if reg_matches?(dst, reg), do: {:ok, key}, else: find_map_key(rest, reg)
  end

  defp ok_or_dynamic(nil), do: :dynamic
  defp ok_or_dynamic(val), do: {:ok, val}

  # Resolve a put_map_assoc/put_map_exact into an Elixir map.
  # The source map is the base being extended; pairs is a flat
  # alternating key/value list.
  defp resolve_map(rest, src, pairs) do
    base =
      case src do
        {:literal, map} when is_map(map) -> map
        {:x, _} = reg -> resolve_element(rest, reg)
        {:y, _} = reg -> resolve_element(rest, reg)
        {:tr, inner_reg, _} -> resolve_element(rest, inner_reg)
        _ -> %{}
      end

    base = if is_map(base), do: base, else: %{}

    resolved_pairs =
      pairs
      |> Enum.chunk_every(2)
      |> Enum.reduce(%{}, fn [k, v], acc ->
        Map.put(acc, resolve_element(rest, k), resolve_element(rest, v))
      end)

    {:ok, Map.merge(base, resolved_pairs)}
  end
end
