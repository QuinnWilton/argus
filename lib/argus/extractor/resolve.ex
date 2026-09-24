defmodule Argus.Extractor.Resolve do
  @moduledoc """
  What a register holds at an instruction, read backwards through the
  writes that reach it (`Argus.Instr.Reaching`): the value itself
  (`resolve_register/3` and the verdicts built on it — `resolve_atom/3`,
  `value_at/3`, `module_target/3`, `timeout_ms/3`, `node_list/3`), whether it is still a
  parameter (`arg_position/3`), the map key or call it came from
  (`map_field_of/3`, `call_result_origin/3`), the fun or list it is
  (`fun_origin/3`, `list_length/3`), and `trace/5` for a question none of
  these asks.
  """

  alias Argus.Extractor.Terms
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId

  @type register :: {:x, non_neg_integer()} | {:y, non_neg_integer()}

  @doc """
  Resolve `{:x, 0}` at the current instruction context, returning the
  inspected atom or `"dynamic"`.

  This is the standard pattern for extracting the target module/atom from
  the first argument of a remote call.
  """
  @spec resolve_callee(Argus.Extractor.Helpers.instr_ctx()) :: String.t()
  def resolve_callee(%{instrs: instrs, idx: idx}) do
    resolve_atom(instrs, idx, {:x, 0})
  end

  @doc """
  Resolve `register` at instruction `idx` and return its inspected atom
  string, or `"dynamic"` if the value cannot be statically determined or
  is not an atom.
  """
  @spec resolve_atom([tuple()], non_neg_integer(), register()) :: String.t()
  def resolve_atom(instrs, idx, register) do
    case resolve_register(instrs, idx, register) do
      {:ok, atom} when is_atom(atom) -> inspect(atom)
      _ -> "dynamic"
    end
  end

  # Apply a whitelisted pure BIF to its resolved arguments. Returns
  # `{:ok, result}` if every argument resolved to a concrete value AND
  # the operation is well-defined; returns `:dynamic` otherwise.
  #
  # Each clause is paranoid about argument shapes: we never call BIFs
  # like `:erlang.element/2` with the wrong types because that raises,
  # which would crash extraction. We bail to `:dynamic` on any mismatch.
  # The whitelist only includes BIFs whose result is fully determined by
  # their arguments — no clock, no process state, no atom-table mutation.
  @pure_bifs [:element, :tuple_size, :map_size, :byte_size, :length, :hd, :tl] ++
               [:atom_to_binary, :++]

  defp apply_pure_bif(:element, [idx, tuple])
       when is_integer(idx) and is_tuple(tuple) and idx > 0 and idx <= tuple_size(tuple) do
    {:ok, elem(tuple, idx - 1)}
  end

  defp apply_pure_bif(:tuple_size, [tuple]) when is_tuple(tuple), do: {:ok, tuple_size(tuple)}
  defp apply_pure_bif(:map_size, [map]) when is_map(map), do: {:ok, map_size(map)}
  defp apply_pure_bif(:byte_size, [bin]) when is_binary(bin), do: {:ok, byte_size(bin)}

  defp apply_pure_bif(:length, [list]) when is_list(list) do
    case proper_length(list) do
      nil -> :dynamic
      n -> {:ok, n}
    end
  end

  defp apply_pure_bif(:hd, [[h | _]]), do: {:ok, h}
  defp apply_pure_bif(:tl, [[_ | t]]), do: {:ok, t}

  defp apply_pure_bif(:atom_to_binary, [atom]) when is_atom(atom) and not is_nil(atom) do
    {:ok, Atom.to_string(atom)}
  end

  # `++` walks its left operand, which must be proper; the right one is
  # only the new tail.
  defp apply_pure_bif(:++, [a, b]) when is_list(a) and is_list(b) do
    if Terms.proper_list?(a), do: {:ok, a ++ b}, else: :dynamic
  end

  defp apply_pure_bif(_op, _args), do: :dynamic

  # --- Backward register resolution ---
  #
  # Every walk below asks `Argus.Instr.Reaching` which instructions can
  # have written a register at a point, and follows the writer: through
  # a copy (move, swap, trim) to what was copied, into the instruction
  # that made the value otherwise. Walking the instruction stream
  # backwards instead read the instruction laid out before a label as its
  # predecessor, and missed writes it had no clause for — a received
  # message, a list's tail — and so answered with another path's value,
  # or the parameter's.
  #
  # Several writers reaching one point is a join, and a walk keeps an
  # answer only when every writer gives it: the fast and slow paths of
  # `map.key` agree on the key, the two arms of a `case` rarely agree on
  # a literal. Each walk memoizes its steps, which keeps a chain of
  # diamonds from multiplying its paths and breaks the cycles loops make:
  # a step met again while it is still being answered answers "unknown",
  # the quiet direction.

  @walk_memo :argus_walk_memo

  defp walk(fun) do
    outer = Process.get(@walk_memo)
    Process.put(@walk_memo, %{})

    try do
      fun.()
    after
      if outer, do: Process.put(@walk_memo, outer), else: Process.delete(@walk_memo)
    end
  end

  defp step(key, none, compute) do
    memo = Process.get(@walk_memo, %{})

    case Map.fetch(memo, key) do
      {:ok, :in_progress} ->
        none

      {:ok, answer} ->
        answer

      :error ->
        Process.put(@walk_memo, Map.put(memo, key, :in_progress))
        answer = compute.()
        Process.put(@walk_memo, Map.put(Process.get(@walk_memo, %{}), key, answer))
        answer
    end
  end

  # The one answer every writer of `reg` at `idx` gives, or `none`.
  defp across(instrs, idx, reg, none, answer) do
    case Reaching.sources(instrs, idx, reg) do
      [] -> none
      [source | sources] -> agree(answer.(source), sources, answer, none)
    end
  end

  defp agree(none, _sources, _answer, none), do: none
  defp agree(first, [], _answer, _none), do: first

  defp agree(first, [source | sources], answer, none) do
    if answer.(source) == first, do: agree(first, sources, answer, none), else: none
  end

  @doc """
  Resolve the value of `register` at instruction index `call_idx` (before
  it runs), following the writes that reach it.

  Handles copies (`move`, `swap`, `trim`), `put_list` chains (cons cell
  construction), `put_tuple2` (tuple construction),
  `put_map_assoc`/`put_map_exact` (map construction), `get_map_elements`
  (map pattern matching), a few pure BIFs, and typed register wrappers
  (`{:tr, reg, type}`). `nil` operands are the empty list, as in BEAM
  assembly. A join resolves only when every path gives the same value.

  Returns `{:ok, term}` with the reconstructed Elixir value, or `:dynamic`
  when the value cannot be statically determined. Partially resolvable
  structures use `:dynamic` as a placeholder for unknown components
  (e.g. `{:ok, {:heir, :dynamic, nil}}`).

  Function parameters and pattern-matched-destructure-of-call-result are
  represented via separate helpers (`arg_position/3` and the
  `{:call_field, mfa, idx}` shape returned for `get_tuple_element` of a
  call result) to keep this function's value contract free of markers.
  """
  @spec resolve_register([term()], non_neg_integer(), register()) :: {:ok, term()} | :dynamic
  def resolve_register(instrs, call_idx, register) do
    case walk(fn -> value(instrs, call_idx, Instr.register(register)) end) do
      # Partial resolution can surface the `:dynamic` placeholder itself as
      # the top-level value (hd of a half-known list, element of a
      # half-known tuple). "Resolved to the unknown marker" is just
      # unresolved — without this, `{:ok, atom}` consumers inspect/1 the
      # placeholder into ":dynamic", which evades every "dynamic" filter
      # downstream. Placeholders nested inside structures still pass
      # through; consumers of partial structures handle them per-field.
      {:ok, :dynamic} ->
        :dynamic

      # An improper list is a value no list operation accepts: every
      # consumer that asks for a list would raise on it, and the call it
      # was built for raises at runtime too. Unresolved is the quiet answer.
      {:ok, list} = resolved when is_list(list) ->
        if Terms.proper_list?(list), do: resolved, else: :dynamic

      other ->
        other
    end
  end

  defp value(instrs, idx, reg) do
    step({:value, idx, reg}, :dynamic, fn ->
      across(instrs, idx, reg, :dynamic, fn
        {:param, _k} -> :dynamic
        at -> made(instrs, at, Reaching.at(instrs, at), reg)
      end)
    end)
  end

  # The value the instruction at `at` wrote into `reg`.
  defp made(instrs, at, instr, reg) do
    case Instr.copy_source(instr, reg) do
      nil -> interpret(instrs, at, instr, reg)
      source -> operand(instrs, at, source)
    end
  end

  defp interpret(instrs, at, {:put_list, head, tail, _dst}, _reg) do
    head = element(instrs, at, head)

    tail =
      case Instr.register(tail) do
        {:literal, list} when is_list(list) -> {:ok, list}
        nil -> {:ok, []}
        {kind, _} = reg when kind in [:x, :y] -> value(instrs, at, reg)
        # A known tail that is not a list makes the list improper, which
        # is no list a consumer can use: the whole value is unknown.
        {:literal, _not_a_list} -> :improper
        {:atom, _} -> :improper
        {:integer, _} -> :improper
        {:float, _} -> :improper
        _ -> :dynamic
      end

    case tail do
      {:ok, list} when is_list(list) -> {:ok, [head | list]}
      :dynamic -> {:ok, [head | [:dynamic]]}
      _ -> :dynamic
    end
  end

  defp interpret(instrs, at, {:put_tuple2, _dst, {:list, elements}}, _reg),
    do: {:ok, elements |> Enum.map(&element(instrs, at, &1)) |> List.to_tuple()}

  defp interpret(instrs, at, {put_map, _fail, src, _dst, _live, {:list, pairs}}, _reg)
       when put_map in [:put_map_assoc, :put_map_exact] do
    base =
      case Instr.register(src) do
        {:literal, map} when is_map(map) -> map
        {kind, _} = reg when kind in [:x, :y] -> element(instrs, at, reg)
        _ -> %{}
      end

    base = if is_map(base), do: base, else: %{}

    resolved =
      pairs
      |> Enum.chunk_every(2)
      |> Enum.reduce(%{}, fn [k, v], acc ->
        Map.put(acc, element(instrs, at, k), element(instrs, at, v))
      end)

    {:ok, Map.merge(base, resolved)}
  end

  defp interpret(instrs, at, {:bif, name, _fail, args, _dst}, _reg) when name in @pure_bifs,
    do: apply_pure_bif(name, Enum.map(args, &element(instrs, at, &1)))

  defp interpret(instrs, at, {:gc_bif, name, _fail, _live, args, _dst}, _reg)
       when name in @pure_bifs,
       do: apply_pure_bif(name, Enum.map(args, &element(instrs, at, &1)))

  defp interpret(instrs, at, {:get_tuple_element, src, idx, _dst}, _reg) do
    case operand(instrs, at, src) do
      # A field of a call's field (`{:ok, {pid, ref}} = start_monitor(...)`)
      # is not an element of the marker that names the outer field.
      {:ok, {:call_field, _mfa, _field}} ->
        :dynamic

      {:ok, tuple} when is_tuple(tuple) and idx < tuple_size(tuple) ->
        {:ok, elem(tuple, idx)}

      _ ->
        # Source isn't a known literal tuple. If a remote call wrote it,
        # surface that as `{:call_field, mfa, idx}` so callers can
        # recognize "this register is field N of <call>'s return". This
        # is the resolution shape that lets pattern-matched destructuring
        # (`{:ok, val} = call()`) be traceable.
        across(instrs, at, Instr.register(src), :dynamic, fn
          {:param, _k} ->
            :dynamic

          writer ->
            case Reaching.at(instrs, writer) do
              {:call_ext, _, {:extfunc, mod, func, arity}} ->
                {:ok, {:call_field, "#{inspect(mod)}:#{func}/#{arity}", idx}}

              _ ->
                :dynamic
            end
        end)
    end
  end

  defp interpret(instrs, at, {:get_hd, src, _dst}, _reg) do
    case operand(instrs, at, src) do
      {:ok, [head | _]} -> {:ok, head}
      _ -> :dynamic
    end
  end

  defp interpret(instrs, at, {:get_tl, src, _dst}, _reg) do
    case operand(instrs, at, src) do
      {:ok, [_ | tail]} -> {:ok, tail}
      _ -> :dynamic
    end
  end

  # A map pattern: the key paired with the destination, looked up in the
  # source map.
  defp interpret(instrs, at, {:get_map_elements, _fail, src, {:list, pairs}}, reg) do
    with {:ok, key} <- find_map_key(pairs, reg),
         {:ok, map} when is_map(map) <- operand(instrs, at, src) do
      map |> Map.get(element(instrs, at, key)) |> ok_or_dynamic()
    else
      _ -> :dynamic
    end
  end

  # Anything else that wrote the register — a call's result, a received
  # message, an arithmetic BIF — made a value this cannot compute.
  defp interpret(_instrs, _at, _instr, _reg), do: :dynamic

  # An operand's value at `at`: a literal is itself (`nil` is the empty
  # list), a register is what reaches it there.
  defp operand(_instrs, _at, {:atom, a}), do: {:ok, a}
  defp operand(_instrs, _at, {:literal, v}), do: {:ok, v}
  defp operand(_instrs, _at, {:integer, n}), do: {:ok, n}
  defp operand(_instrs, _at, {:float, f}), do: {:ok, f}
  defp operand(_instrs, _at, nil), do: {:ok, []}
  defp operand(instrs, at, {:tr, reg, _type}), do: operand(instrs, at, reg)
  defp operand(instrs, at, {kind, _} = reg) when kind in [:x, :y], do: value(instrs, at, reg)
  defp operand(_instrs, _at, _other), do: :dynamic

  # An operand as an element of a structure: its value, or the `:dynamic`
  # placeholder.
  defp element(instrs, at, operand) do
    case operand(instrs, at, operand) do
      {:ok, value} -> value
      :dynamic -> :dynamic
    end
  end

  # Find the key operand paired with a destination register in a
  # get_map_elements pair list. Pairs alternate: [key1, dst1, key2, dst2, ...].
  defp find_map_key([key, dst | rest], reg) do
    if Instr.register(dst) == reg, do: {:ok, key}, else: find_map_key(rest, reg)
  end

  defp find_map_key(_pairs, _reg), do: :none

  defp ok_or_dynamic(nil), do: :dynamic
  defp ok_or_dynamic(val), do: {:ok, val}

  @doc """
  Follow the writes that reach `register` at `idx` for a question the
  walks here do not ask. Copies are followed to what they copied; every
  other writer is handed to `answer` as `{:param, k}` or `{writer_idx,
  instruction}`, along with `follow`, a function of an index and a
  register that goes on from there — through a tuple projection, say.
  Returns the answer every writer gives, or `none`.
  """
  @spec trace(
          [term()],
          non_neg_integer(),
          register(),
          a,
          ({:param, non_neg_integer()}
           | {non_neg_integer(), term()},
           (non_neg_integer(), register() -> a) ->
             a)
        ) :: a
        when a: term()
  def trace(instrs, idx, register, none, answer) do
    walk(fn -> traced(instrs, idx, Instr.register(register), none, answer) end)
  end

  defp traced(instrs, idx, reg, none, answer) do
    step({:trace, answer, idx, reg}, none, fn ->
      follow = fn at, next -> traced(instrs, at, Instr.register(next), none, answer) end

      across(instrs, idx, reg, none, fn
        {:param, _k} = param ->
          answer.(param, follow)

        at ->
          instr = Reaching.at(instrs, at)

          case Instr.copy_source(instr, reg) do
            {kind, _} = source when kind in [:x, :y] -> traced(instrs, at, source, none, answer)
            _ -> answer.({at, instr}, follow)
          end
      end)
    end)
  end

  @typedoc """
  Where a value was read from: `{source, root, path}` — see `access_paths/4`.
  """
  @type access_path :: {String.t(), String.t(), String.t()}

  @doc """
  Everywhere the value in `register` at `idx` may have been read from,
  each as a root and the map keys read on the way down from it:
  `%{forward: t} = tables` and `tables.forward` both read `t` from the
  parameter `tables` under `:forward`, and `state.tables.forward` reads
  it under `:tables`, then `:forward`. Copies are followed, and so is the
  compiler's slow path for `map.key`, which agrees with the fast path at
  their join.

  Each answer is `{source, root, path}`:

  - `{"literal", inspected, ""}` — an atom, binary or integer;
  - `{"param", "N", path}` — read from the function's parameter N;
  - `{"local", instr_id, path}` — given `func_id`, read from the value
    the instruction `instr_id` made: a call's result (`:ets.new/2`'s
    reference), a tuple's element.

  `path` is the keys, each spelled as `map_field_of/3` spells it, joined
  by `"."` (`":tables.:forward"`), and `""` for the root itself.

  Unlike the other walks here, a join keeps every arm's answers: the
  value is one of them, and `cfg.table || @default` is the parameter's
  field or the literal, so both are answers. An arm that cannot be
  followed — a key that is not a literal, a local root without
  `func_id` — contributes nothing, and the answer is `[]` when none can.
  Two operands in one function that share an answer may hold the same
  value; two read from one root under different keys are read from
  different fields, which is how a function tells apart two tables it
  was handed in one map, as `Argus.Extractors.ETS` does for
  `ets_table_path`.
  """
  @spec access_paths([term()], non_neg_integer(), register(), String.t() | nil) ::
          [access_path()]
  def access_paths(instrs, idx, register, func_id \\ nil) do
    walk(fn -> paths(instrs, idx, Instr.register(register), [], func_id) end)
  end

  defp paths(instrs, idx, reg, keys, func_id) do
    step({:paths, idx, reg, keys}, [], fn ->
      instrs
      |> Reaching.sources(idx, reg)
      |> Enum.flat_map(fn
        {:param, k} -> [{"param", to_string(k), Enum.join(keys, ".")}]
        at -> paths_from(instrs, at, Reaching.at(instrs, at), reg, keys, func_id)
      end)
      |> Enum.uniq()
    end)
  end

  defp paths_from(instrs, at, instr, reg, keys, func_id) do
    case {Instr.copy_source(instr, reg), instr} do
      {{kind, _} = source, _instr} when kind in [:x, :y] ->
        paths(instrs, at, source, keys, func_id)

      {nil, {:get_map_elements, _fail, src, {:list, pairs}}} ->
        case find_map_key(pairs, reg) do
          {:ok, {:atom, key}} ->
            paths(instrs, at, Instr.register(src), [inspect(key) | keys], func_id)

          {:ok, {:literal, key}} ->
            paths(instrs, at, Instr.register(src), [Terms.spell(key) | keys], func_id)

          _ ->
            []
        end

      {nil, {:get_tuple_element, src, 1, _dst}} ->
        case slow_path_map(instrs, at, Instr.register(src)) do
          {:ok, map_at, key} -> paths(instrs, map_at, {:x, 0}, [key | keys], func_id)
          :none -> local_root(at, keys, func_id)
        end

      {nil, _instr} ->
        local_root(at, keys, func_id)

      {literal, _instr} when keys == [] ->
        literal_root(literal)

      _literal_with_keys ->
        []
    end
  end

  defp literal_root({:atom, atom}), do: [{"literal", inspect(atom), ""}]
  defp literal_root({:integer, n}), do: [{"literal", inspect(n), ""}]

  defp literal_root({:literal, value}) when is_binary(value),
    do: [{"literal", Terms.spell(value), ""}]

  defp literal_root(_other), do: []

  defp local_root(_at, _keys, nil), do: []

  defp local_root(at, keys, func_id),
    do: [{"local", InstrId.mint(func_id, at), Enum.join(keys, ".")}]

  # The `elixir_erl_pass:no_parens_remote/2` call whose result `reg`
  # holds at `idx` — the slow path of `map.key` — with its key, the map
  # being its `x0` at the call's index.
  defp slow_path_map(instrs, idx, reg) do
    step({:slow_path_map, idx, reg}, :none, fn ->
      across(instrs, idx, reg, :none, fn
        {:param, _k} ->
          :none

        at ->
          case Reaching.at(instrs, at) do
            {:call_ext, 2, {:extfunc, :elixir_erl_pass, :no_parens_remote, 2}} ->
              case value(instrs, at, {:x, 1}) do
                {:ok, key} when is_atom(key) and key != :dynamic -> {:ok, at, inspect(key)}
                _ -> :none
              end

            instr ->
              case Instr.copy_source(instr, reg) do
                {kind, _} = source when kind in [:x, :y] -> slow_path_map(instrs, at, source)
                _ -> :none
              end
          end
      end)
    end)
  end

  @doc """
  The map key `register` was read from at instruction `idx`, following
  copies back to a `get_map_elements` (a `state.timer` read, or a
  `%{timer: ref}` pattern in a clause head) — or to the compiler's slow
  path for `map.key`, a call returning `{:ok, value}` whose element 1 is
  taken, which agrees with the fast path at their join.

  Returns `{:ok, inspected_key}` or `:dynamic`.
  """
  @spec map_field_of([term()], non_neg_integer(), register()) :: {:ok, String.t()} | :dynamic
  def map_field_of(instrs, idx, register) do
    walk(fn -> field(instrs, idx, Instr.register(register)) end)
  end

  defp field(instrs, idx, reg) do
    step({:field, idx, reg}, :dynamic, fn ->
      across(instrs, idx, reg, :dynamic, fn
        {:param, _k} -> :dynamic
        at -> field_from(instrs, at, Reaching.at(instrs, at), reg)
      end)
    end)
  end

  defp field_from(instrs, at, instr, reg) do
    case {Instr.copy_source(instr, reg), instr} do
      {{kind, _} = source, _instr} when kind in [:x, :y] ->
        field(instrs, at, source)

      {nil, {:get_map_elements, _fail, _src, {:list, pairs}}} ->
        case find_map_key(pairs, reg) do
          {:ok, {:atom, key}} -> {:ok, inspect(key)}
          {:ok, {:literal, key}} -> {:ok, Terms.spell(key)}
          _ -> :dynamic
        end

      {nil, {:get_tuple_element, src, 1, _dst}} ->
        slow_path_field(instrs, at, Instr.register(src))

      _ ->
        :dynamic
    end
  end

  defp slow_path_field(instrs, idx, reg) do
    step({:slow_path, idx, reg}, :dynamic, fn ->
      across(instrs, idx, reg, :dynamic, fn
        {:param, _k} ->
          :dynamic

        at ->
          case Reaching.at(instrs, at) do
            {:call_ext, 2, {:extfunc, :elixir_erl_pass, :no_parens_remote, 2}} ->
              case value(instrs, at, {:x, 1}) do
                {:ok, key} when is_atom(key) and key != :dynamic -> {:ok, inspect(key)}
                _ -> :dynamic
              end

            instr ->
              case Instr.copy_source(instr, reg) do
                {kind, _} = source when kind in [:x, :y] -> slow_path_field(instrs, at, source)
                _ -> :dynamic
              end
          end
      end)
    end)
  end

  @doc """
  Trace `register` at instruction `call_idx` back to the call whose
  RESULT it holds, following copies.

  Returns `{:ok, {mod, func, arity}, origin_idx}` where `origin_idx` is
  the absolute instruction index of the originating call — useful for
  resolving that call's own arguments (e.g. mapping an ETS table
  reference back to the `:ets.new/2` site that created it, then reading
  the table name from x0 there), or for stepping into a local `defp`
  helper that produced the value. Both remote (`call_ext`) and local
  (`call`) calls are reported. Returns `:no` when the register holds
  anything else, or when the paths reaching it disagree on the call.
  """
  @spec call_result_origin([term()], non_neg_integer(), register()) ::
          {:ok, {module(), atom(), arity()}, non_neg_integer()} | :no
  def call_result_origin(instrs, call_idx, register) do
    walk(fn -> origin(instrs, call_idx, Instr.register(register)) end)
  end

  defp origin(instrs, idx, reg) do
    step({:origin, idx, reg}, :no, fn ->
      across(instrs, idx, reg, :no, fn
        {:param, _k} ->
          :no

        at ->
          instr = Reaching.at(instrs, at)

          case Instr.copy_source(instr, reg) do
            {kind, _} = source when kind in [:x, :y] ->
              origin(instrs, at, source)

            nil ->
              case call_target_mfa(instr) do
                {:ok, mfa} -> {:ok, mfa, at}
                :none -> :no
              end

            _literal ->
              :no
          end
      end)
    end)
  end

  @doc """
  The instruction that wrote `register` before `idx`, as
  `{:ok, instruction, writer_idx}`, or `:no` — when no instruction did
  (a parameter, or nothing), or when several can have, on different paths.

  Unlike `resolve_register/3` (which reconstructs a *value*), this returns
  the raw writer, so callers can inspect provenance — was it a `put_list`,
  a `put_tuple2`, a `move`, a call? Moves are returned as-is — the caller
  decides whether to keep following the chain.
  """
  @spec recent_writer([term()], non_neg_integer(), register()) ::
          {:ok, term(), non_neg_integer()} | :no
  def recent_writer(instrs, idx, register) do
    case Reaching.sources(instrs, idx, register) do
      [at] when is_integer(at) -> {:ok, Reaching.at(instrs, at), at}
      _ -> :no
    end
  end

  @doc """
  Find the register holding `key`'s value in a keyword list built at
  runtime and pointed to by `list_reg` at instruction `idx`.

  Returns `{:ok, value_register, value_idx}` — the register that holds the
  value and the index where the `{key, value}` pair was constructed — or
  `:no`. This is the provenance hook for reading a runtime option's
  *source*: e.g. a `{DynamicSupervisor, name: some_call(...)}` child spec
  whose `:name` is computed, where you want to trace the value back to the
  call that produced it (via `call_result_origin/3`).

  Walks the cons cells (`put_list`) and pair tuples (`put_tuple2`) of the
  list, following `move` chains. Only pairs whose value is a *register*
  match — a literal value has no register to return (use
  `resolve_register/3` for those).
  """
  @spec keyword_value_register([term()], non_neg_integer(), register(), atom()) ::
          {:ok, register(), non_neg_integer()} | :no
  def keyword_value_register(instrs, idx, list_reg, key) do
    do_keyword_value_register(instrs, idx, Instr.register(list_reg), key)
  end

  defp do_keyword_value_register(instrs, idx, list_reg, key) do
    case recent_writer(instrs, idx, list_reg) do
      {:ok, {:move, src, _}, widx} ->
        do_keyword_value_register(instrs, widx, Instr.register(src), key)

      {:ok, {:put_list, head, tail, _}, widx} ->
        case pair_value_register(instrs, widx, head, key) do
          {:ok, _, _} = hit -> hit
          :no -> follow_kw_tail(instrs, widx, tail, key)
        end

      _ ->
        :no
    end
  end

  # The list tail is another cons register, or `nil`/a literal (list end).
  defp follow_kw_tail(instrs, idx, tail, key) do
    case Instr.register(tail) do
      {kind, _} = reg when kind in [:x, :y] -> do_keyword_value_register(instrs, idx, reg, key)
      _ -> :no
    end
  end

  # A cons head is the `{key, value}` pair. Reachable as a register (a
  # runtime-built tuple) — resolve it to its put_tuple2 and read the value
  # operand when the key matches and the value is itself a register.
  defp pair_value_register(instrs, idx, head, key) do
    case Instr.register(head) do
      {kind, _} = reg when kind in [:x, :y] -> pair_from_reg(instrs, idx, reg, key)
      _ -> :no
    end
  end

  defp pair_from_reg(instrs, idx, reg, key) do
    case recent_writer(instrs, idx, reg) do
      {:ok, {:move, src, _}, widx} ->
        pair_from_reg(instrs, widx, Instr.register(src), key)

      {:ok, {:put_tuple2, _, {:list, [k_elem, v_elem]}}, widx} ->
        if pair_key_matches?(k_elem, key) and value_register(v_elem) do
          {:ok, Instr.register(v_elem), widx}
        else
          :no
        end

      _ ->
        :no
    end
  end

  defp pair_key_matches?({:atom, k}, key), do: k == key
  defp pair_key_matches?({:literal, k}, key), do: k == key
  defp pair_key_matches?(_, _), do: false

  defp value_register(operand),
    do: match?({kind, _} when kind in [:x, :y], Instr.register(operand))

  # Local (intra-module) calls carry a bare `{mod, func, arity}` target. A
  # register holding a local call's result traces to that MFA, so callers
  # can step into the callee (e.g. a `defp helper` that returns the value
  # being tracked).
  defp call_target_mfa({:call_ext, _, {:extfunc, m, f, a}}), do: {:ok, {m, f, a}}
  defp call_target_mfa({:call, _, {m, f, a}}), do: {:ok, {m, f, a}}
  defp call_target_mfa(_), do: :none

  @doc """
  Determine whether `register` is a function parameter at instruction
  index `call_idx`. Returns `{:ok, n}` if it holds the n-th parameter on
  every path to `call_idx` (through copies: `def f(_unused, useful)`
  moves x1 to x0 before the call, and x0 there IS parameter 1), or `:no`.

  This lets extractors distinguish "I don't know" from "this is
  parameter N", which matters for client-API functions like
  `def get(pid), do: GenServer.call(pid, :get)`.
  """
  @spec arg_position([term()], non_neg_integer(), register()) ::
          {:ok, non_neg_integer()} | :no
  def arg_position(instrs, call_idx, register) do
    walk(fn -> arg(instrs, call_idx, Instr.register(register)) end)
  end

  defp arg(instrs, idx, reg) do
    step({:arg, idx, reg}, :no, fn ->
      across(instrs, idx, reg, :no, fn
        {:param, k} ->
          {:ok, k}

        at ->
          case Instr.copy_source(Reaching.at(instrs, at), reg) do
            {kind, _} = source when kind in [:x, :y] -> arg(instrs, at, source)
            _ -> :no
          end
      end)
    end)
  end

  @doc """
  Resolve `register` at instruction `idx` and classify the result as a
  literal atom, a function parameter, or dynamic.

  Returns one of:

  - `{:atom, inspected}` — the register holds a literal atom (the value
    is `inspect/1`'d so it's safe to use as a fact field)
  - `{:arg, n}` — the register is the n-th function parameter
  - `:dynamic` — the value cannot be statically determined

  This is the right helper for extractors that need to distinguish "this
  call goes to a known module" from "this call goes to a parameter we
  could correlate via the call graph" from "we have no idea".
  """
  @spec resolve_to_arg_or_atom([term()], non_neg_integer(), register()) ::
          {:atom, String.t()} | {:arg, non_neg_integer()} | :dynamic
  def resolve_to_arg_or_atom(instrs, idx, register) do
    case resolve_register(instrs, idx, register) do
      {:ok, atom} when is_atom(atom) ->
        {:atom, inspect(atom)}

      _ ->
        case arg_position(instrs, idx, register) do
          {:ok, n} -> {:arg, n}
          :no -> :dynamic
        end
    end
  end

  @doc """
  The function a fun in `register` at `idx` runs: the `{mod, fun, arity}`
  its `make_fun3` was lifted to, or the one a literal external fun
  (`&Mod.f/1`) names, through copies; `nil` otherwise.
  """
  @spec fun_target([term()], non_neg_integer(), register()) :: {module(), atom(), arity()} | nil
  def fun_target(instrs, idx, register) do
    case fun_origin(instrs, idx, register) do
      {kind, mfa} when kind in [:closure, :external] -> mfa
      _ -> nil
    end
  end

  @doc """
  Where the fun in `register` at `idx` comes from, through copies, on
  every path: `{:closure, mfa}`, a `make_fun3` lifted to `mfa` (its arity
  counts the captured variables); `{:external, mfa}`, a literal external
  fun `&Mod.f/1`; `{:param, k}`, the function's parameter `k`, whose value
  its callers choose; or `nil`.
  """
  @spec fun_origin([term()], non_neg_integer(), register()) ::
          {:closure | :external, {module(), atom(), arity()}}
          | {:param, non_neg_integer()}
          | nil
  def fun_origin(instrs, idx, register) do
    walk(fn -> fun_made(instrs, idx, Instr.register(register)) end)
  end

  defp fun_made(instrs, idx, reg) do
    step({:fun, idx, reg}, nil, fn ->
      across(instrs, idx, reg, nil, fn
        {:param, k} ->
          {:param, k}

        at ->
          case Reaching.at(instrs, at) do
            {:make_fun3, {mod, fun, arity}, _index, _uniq, _dst, _env} ->
              {:closure, {mod, fun, arity}}

            {:call_ext, 3, {:extfunc, :erlang, :make_fun, 3}} when reg == {:x, 0} ->
              made_fun(instrs, at)

            instr ->
              case Instr.copy_source(instr, reg) do
                {kind, _} = source when kind in [:x, :y] -> fun_made(instrs, at, source)
                {:literal, fun} when is_function(fun) -> external_fun(fun)
                _ -> nil
              end
          end
      end)
    end)
  end

  # erlang:make_fun(M, F, A) of literals: the external fun `&M.F/A`.
  defp made_fun(instrs, at) do
    with {:ok, mod} when is_atom(mod) and mod != :dynamic <-
           resolve_register(instrs, at, {:x, 0}),
         {:ok, fun} when is_atom(fun) and fun != :dynamic <-
           resolve_register(instrs, at, {:x, 1}),
         {:ok, arity} when is_integer(arity) and arity >= 0 <-
           resolve_register(instrs, at, {:x, 2}) do
      {:external, {mod, fun, arity}}
    else
      _ -> nil
    end
  end

  # A fun in a literal is external: a local fun cannot be a constant.
  defp external_fun(fun) do
    case Function.info(fun, :type) do
      {:type, :external} ->
        {:module, mod} = Function.info(fun, :module)
        {:name, name} = Function.info(fun, :name)
        {:arity, arity} = Function.info(fun, :arity)
        {:external, {mod, name, arity}}

      _ ->
        nil
    end
  end

  @doc """
  The length of the list in `register` at `idx`, counting the cons cells
  that built it: an element that did not resolve still counts, a tail
  that did not (`[x | rest]`) leaves the length unknown, `nil`.
  (`resolve_register/3` cannot say this: it reads an unknown tail as one
  more element.)
  """
  @spec list_length([term()], non_neg_integer(), register()) :: non_neg_integer() | nil
  def list_length(instrs, idx, register) do
    walk(fn -> list_operand_length(instrs, idx, register) end)
  end

  defp list_operand_length(instrs, idx, operand) do
    case Instr.register(operand) do
      nil -> 0
      {:literal, list} when is_list(list) -> proper_length(list)
      {kind, _} = reg when kind in [:x, :y] -> cells(instrs, idx, reg)
      _ -> nil
    end
  end

  defp cells(instrs, idx, reg) do
    step({:cells, idx, reg}, nil, fn ->
      across(instrs, idx, reg, nil, fn
        {:param, _k} ->
          nil

        at ->
          case Reaching.at(instrs, at) do
            {:put_list, _head, tail, _dst} ->
              case list_operand_length(instrs, at, tail) do
                n when is_integer(n) -> n + 1
                nil -> nil
              end

            instr ->
              case Instr.copy_source(instr, reg) do
                nil -> nil
                source -> list_operand_length(instrs, at, source)
              end
          end
      end)
    end)
  end

  defp proper_length(list), do: proper_length(list, 0)
  defp proper_length([], n), do: n
  defp proper_length([_ | tail], n), do: proper_length(tail, n + 1)
  defp proper_length(_improper, _n), do: nil

  @doc """
  What `register` holds at `idx`, in one verdict: a literal, a function
  parameter, the result of a call, or nothing knowable. The resolution
  cascade that four extractors each wrote out.
  """
  @spec value_at([tuple()], non_neg_integer(), register()) ::
          {:literal, term()}
          | {:arg, non_neg_integer()}
          | {:call_result, {module(), atom(), arity()}, non_neg_integer()}
          | :dynamic
  def value_at(instrs, idx, register) do
    case resolve_register(instrs, idx, register) do
      {:ok, value} ->
        {:literal, value}

      :dynamic ->
        case arg_position(instrs, idx, register) do
          {:ok, n} ->
            {:arg, n}

          :no ->
            case call_result_origin(instrs, idx, register) do
              {:ok, mfa, origin} -> {:call_result, mfa, origin}
              :no -> :dynamic
            end
        end
    end
  end

  @doc """
  The process a call is addressed to, as every target column spells it:
  the inspected module atom, `"via:Registry"` for a via tuple naming a
  registry, or `"dynamic"`.
  """
  @spec module_target([tuple()], non_neg_integer(), register()) :: String.t()
  def module_target(instrs, idx, register) do
    case resolve_register(instrs, idx, register) do
      {:ok, atom} when is_atom(atom) and atom != :dynamic ->
        inspect(atom)

      {:ok, {:via, _via_mod, {reg_instance, _key}}}
      when is_atom(reg_instance) and reg_instance != :dynamic ->
        "via:#{inspect(reg_instance)}"

      _ ->
        "dynamic"
    end
  end

  @doc """
  Which nodes a `:global` node-list argument names, as `global_op`
  spells it: `"local"` for a list of only the local node (`[node()]`,
  `[Node.self()]`), `"cluster"` for one that holds the connected nodes
  (`Node.list/0,1` or `:erlang.nodes/0,1`, alone, consed onto, or
  appended with `++`), and `"unknown"` for anything else: a parameter, a
  call's result, a literal list of node names, or paths that disagree.

  The walk reads the list's cells: a cell's head must be the local node
  for the list to stay local, and a tail holding the connected nodes
  makes the list cluster-wide whatever else it holds. `nodes(:this)`
  is the local node alone.
  """
  @spec node_list([tuple()], non_neg_integer(), register()) :: String.t()
  def node_list(instrs, idx, register) do
    answer = fn writer, follow -> nodes_written(instrs, writer, follow) end

    case trace(instrs, idx, register, :unknown, answer) do
      :local -> "local"
      :cluster -> "cluster"
      _ -> "unknown"
    end
  end

  # What a writer put in the register, as a node set: `:self` (the local
  # node's name), `:empty` (`[]`), `:local` (a list of only the local
  # node), `:cluster` (a list holding the connected nodes) or `:unknown`.
  defp nodes_written(_instrs, {:param, _k}, _follow), do: :unknown

  defp nodes_written(_instrs, {_at, {:bif, :node, _fail, [], _dst}}, _follow), do: :self

  defp nodes_written(_instrs, {at, {:put_list, head, tail, _dst}}, follow),
    do: cons(node_operand(at, head, follow), node_operand(at, tail, follow))

  # A literal copied in (a register copy is followed before this).
  defp nodes_written(_instrs, {at, {:move, src, _dst}}, follow),
    do: node_operand(at, src, follow)

  defp nodes_written(instrs, {at, instr}, follow) do
    case call_target_mfa(instr) do
      {:ok, {:erlang, :node, 0}} ->
        :self

      {:ok, {Node, :self, 0}} ->
        :self

      {:ok, {m, f, 0}} when {m, f} in [{:erlang, :nodes}, {Node, :list}] ->
        :cluster

      {:ok, {m, f, 1}} when {m, f} in [{:erlang, :nodes}, {Node, :list}] ->
        nodes_of(instrs, at)

      {:ok, {m, f, 2}} when {m, f} in [{:erlang, :++}, {:lists, :append}] ->
        append(follow.(at, {:x, 0}), follow.(at, {:x, 1}))

      _ ->
        :unknown
    end
  end

  # nodes(:this) and nodes([:this]) are the local node; every other
  # argument names connected nodes, or may.
  defp nodes_of(instrs, at) do
    case value(instrs, at, {:x, 0}) do
      {:ok, :this} -> :local
      {:ok, [:this]} -> :local
      _ -> :cluster
    end
  end

  defp node_operand(at, operand, follow) do
    case Instr.register(operand) do
      nil -> :empty
      {:literal, []} -> :empty
      {kind, _} = reg when kind in [:x, :y] -> follow.(at, reg)
      _ -> :unknown
    end
  end

  defp cons(_head, :cluster), do: :cluster
  defp cons(:self, tail) when tail in [:empty, :local], do: :local
  defp cons(_head, _tail), do: :unknown

  defp append(a, b) when a == :cluster or b == :cluster, do: :cluster
  defp append(:empty, :empty), do: :empty
  defp append(a, b) when a in [:empty, :local] and b in [:empty, :local], do: :local
  defp append(_a, _b), do: :unknown

  @doc """
  A timeout argument as the schema spells it: the milliseconds, `"-1"`
  for `:infinity`, `"0"` when it could not be read. `:gen_statem.call/3`'s
  `{:dirty_timeout, t}` and `{:clean_timeout, t}` are the timeout `t`.
  """
  @spec timeout_ms([tuple()], non_neg_integer(), register()) :: String.t()
  def timeout_ms(instrs, idx, register) do
    case resolve_register(instrs, idx, register) do
      {:ok, {tag, t}} when tag in [:dirty_timeout, :clean_timeout] -> spell_timeout(t)
      {:ok, t} -> spell_timeout(t)
      _ -> "0"
    end
  end

  defp spell_timeout(n) when is_integer(n) and n > 0, do: to_string(n)
  defp spell_timeout(:infinity), do: "-1"
  defp spell_timeout(_unknown), do: "0"
end
