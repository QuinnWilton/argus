defmodule Argus.Extractor.Helpers do
  @moduledoc """
  Shared helpers for domain-specific fact extractors.

  Provides shared capabilities that extractors commonly need:

  - **`add_fact/3`** — accumulate a row into a relation map
  - **`scan_functions/4`** — walk every function and instruction with a handler
  - **`scan_remote_calls/4`** — like `scan_functions/4`, pre-filtered to remote calls
  - **`resolve_callee/1`** — resolve the `{:x, 0}` argument as an atom string
  - **`resolve_atom/3`** — resolve any register as an atom string
  - **`match_remote_call/1`** — recognize `call_ext` variants as `{mod, func, arity}`
  - **`match_local_call/1`** — recognize intra-module `call` variants
  - **`resolve_register/3`** — a register's value at a call site, following
    the writes that reach it (`Argus.Instr.Reaching`); `arg_position/3`,
    `map_field_of/3`, `call_result_origin/3` and `key_identity/4` ask the
    same writes other questions
  - **`get_behaviours/1`** — extract behaviour modules from attributes
  - **`find_function/3`** — look up a function's instructions by name and arity
  """

  alias Argus.Extractor.CallSites
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  @type register :: {:x, non_neg_integer()} | {:y, non_neg_integer()}

  @typedoc """
  Per-instruction context passed to scan handlers. Carries everything an
  extractor needs to call `resolve_register/3` against the surrounding code.
  """
  @type instr_ctx :: %{
          optional(:line_table) => %{pos_integer() => pos_integer()},
          optional(:origins) => origins(),
          required(:func_id) => String.t(),
          required(:instrs) => [tuple()],
          required(:idx) => non_neg_integer()
        }

  # --- Fact accumulation ---

  @doc """
  Append a row to the given relation in a facts map.
  """
  @spec add_fact(Argus.Pipeline.Emit.facts(), atom(), [String.t()]) :: Argus.Pipeline.Emit.facts()
  def add_fact(facts, relation, row) do
    Map.update(facts, relation, [row], &[row | &1])
  end

  # --- Coverage instrumentation ---
  #
  # The `imprecision` Layer 2 fact records every fallback to "dynamic" or
  # an outright skipped emission. The tracking is gated on a process-
  # dictionary flag so non-coverage analyses pay zero cost: every
  # `track_*` call becomes a single sub-microsecond `Process.get/2`.
  #
  # The pipeline runner sets the flag (via `enable_tracing/0`) only when
  # the active analysis is `coverage`, then clears it (via
  # `disable_tracing/0`) on the way out. The state is process-local so
  # concurrent analysis runs from different processes don't interfere.

  @tracing_key :argus_trace_imprecision

  @doc """
  Enable imprecision tracking for the current Erlang process. Subsequent
  `track_imprecision/5` and `track_dynamic/5` calls will record events.
  """
  @spec enable_tracing() :: :ok
  def enable_tracing do
    Process.put(@tracing_key, true)
    :ok
  end

  @doc """
  Disable imprecision tracking for the current Erlang process. Subsequent
  `track_*` calls become no-ops. Always called from the pipeline's
  `try/after` so the flag is cleared even on extractor errors.
  """
  @spec disable_tracing() :: :ok
  def disable_tracing do
    Process.delete(@tracing_key)
    :ok
  end

  @doc """
  Returns whether imprecision tracking is currently enabled for this process.
  Useful in tests; production code should just call the `track_*` helpers
  and rely on them to no-op when tracing is off.
  """
  @spec tracing_enabled?() :: boolean()
  def tracing_enabled? do
    Process.get(@tracing_key, false) == true
  end

  @doc """
  Record an imprecision event explicitly. Use directly when the extractor
  decided to skip a fact emission entirely (the "intentional skip" case
  is still information — the value was missing, not just dynamic).

  No-op unless tracing is enabled for the current process.
  """
  @spec track_imprecision(
          Argus.Pipeline.Emit.facts(),
          instr_ctx(),
          atom(),
          atom(),
          atom() | String.t()
        ) :: Argus.Pipeline.Emit.facts()
  def track_imprecision(facts, ctx, category, relation, reason \\ :dynamic) do
    if tracing_enabled?() do
      add_fact(facts, :imprecision, [
        to_string(category),
        ctx.func_id,
        to_string(relation),
        to_string(reason)
      ])
    else
      facts
    end
  end

  @doc """
  Conditional wrapper around `track_imprecision/5`. When `value` indicates
  a dynamic fallback (the string `"dynamic"` or the atom `:dynamic`),
  records the event. No-op otherwise AND no-op when tracing is disabled.

  This is the right helper for wrapping an existing `resolve_callee` /
  `resolve_atom` call site — the wrapper is essentially free in the
  non-coverage case (a single `Process.get/2`).
  """
  @spec track_dynamic(
          Argus.Pipeline.Emit.facts(),
          term(),
          instr_ctx(),
          atom(),
          atom()
        ) :: Argus.Pipeline.Emit.facts()
  def track_dynamic(facts, value, ctx, category, relation) do
    if tracing_enabled?() and dynamic_value?(value) do
      add_fact(facts, :imprecision, [
        to_string(category),
        ctx.func_id,
        to_string(relation),
        "dynamic"
      ])
    else
      facts
    end
  end

  # Arg-position results like `{:arg, 0}` are NOT dynamic — they carry
  # concrete information about which parameter the value came from.
  defp dynamic_value?("dynamic"), do: true
  defp dynamic_value?(:dynamic), do: true
  defp dynamic_value?({:arg, _}), do: false
  defp dynamic_value?(_), do: false

  # --- Per-instruction scanning ---

  @doc """
  Walk every function in `functions` and every instruction within each
  function, calling `handler.(facts, ctx, instr)` for each instruction.

  `ctx` is a map with `:func_id`, `:instrs`, and `:idx` — everything an
  extractor needs to call `resolve_register/3` on the surrounding code.

  This is the standard outer loop for instruction-driven extractors.
  """
  @spec scan_functions(
          module(),
          [tuple()],
          Argus.Pipeline.Emit.facts(),
          (Argus.Pipeline.Emit.facts(), instr_ctx(), tuple() -> Argus.Pipeline.Emit.facts())
        ) :: Argus.Pipeline.Emit.facts()
  def scan_functions(mod, functions, facts \\ %{}, handler) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      func_id = Normalize.func_id(mod, name, arity)

      instrs
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {instr, idx}, inner ->
        handler.(inner, %{func_id: func_id, instrs: instrs, idx: idx}, instr)
      end)
    end)
  end

  @doc """
  Resolve `{:x, 0}` at the current instruction context, returning the
  inspected atom or `"dynamic"`.

  This is the standard pattern for extracting the target module/atom from
  the first argument of a remote call.
  """
  @spec resolve_callee(instr_ctx()) :: String.t()
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

  # --- Attribute helpers ---

  @doc """
  Extract behaviour modules from a module's attributes.

  Handles both `:behaviour` and `:behavior` spellings.
  """
  @spec get_behaviours(keyword()) :: [module()]
  def get_behaviours(attrs) do
    attribute_values(attrs, :behaviour) ++ attribute_values(attrs, :behavior)
  end

  @doc """
  Every value the attribute `key` holds, across all its entries in a
  module's attribute chunk, nested lists flattened.

  `List.flatten/1` did this and raised on an improper list, which Erlang
  source can store as an attribute's value (`-my_attr([a|b]).`); here an
  improper list is one value.
  """
  @spec attribute_values(keyword(), atom()) :: [term()]
  def attribute_values(attrs, key) do
    for {^key, values} <- attrs, value <- flatten_proper(values, []), do: value
  end

  defp flatten_proper(term, acc) do
    if proper_list?(term),
      do: term |> Enum.reverse() |> Enum.reduce(acc, &flatten_proper/2),
      else: [term | acc]
  end

  @doc """
  A value as every fact column spells it: `inspect/2` without a struct's
  own `Inspect` implementation, and with a digest of the whole term when
  inspect cut the spelling short.

  Never a struct's own implementation, because a spelling must not depend
  on which modules are loaded (scry's compiler has the analyzed code
  loaded, a batch run does not), and an implementation that raises on
  the struct's defaults (sequin's `CircularBuffer`) renders as a
  multi-line `#Inspect.Error<...>`.

  A map prints its keys sorted: a VM iterates a small map with atom keys
  in atom-table order, which depends on which atoms that VM created
  first, so the same beam read by two VMs would otherwise spell the same
  literal two ways.

  inspect/2 stops at 50 elements and 4096 bytes of a string, so two
  values that differ past those bounds spelled the same, and joined as
  one value (one ETS key, one literal). A spelling inspect cut short
  carries ` #` and a digest of the whole term instead. Spelling every
  value in full was measured and rejected: over ecto, absinthe and
  hexpm it doubles the bytes of literal spellings (6.4MB to 12.7MB,
  nearly all of it embedded asset binaries that land in `literal_value`
  and every `move` of them), where the digest adds 0.4% and touches 995
  of 91,640 spellings. The test is for inspect's `...` marker; a small
  value that merely holds three dots gets a digest it did not need,
  which costs nothing.
  """
  @spec spell(term()) :: String.t()
  def spell(value) do
    spelled = inspect(value, structs: false, custom_options: [sort_maps: true])

    if String.contains?(spelled, "...") do
      digest =
        :sha256
        |> :crypto.hash(:erlang.term_to_binary(value, [:deterministic]))
        |> binary_part(0, 12)
        |> Base.encode16(case: :lower)

      spelled <> " #" <> digest
    else
      spelled
    end
  end

  @doc """
  Whether `term` is a proper list: `[]`, or cons cells ending in `[]`.

  A literal in a beam can be improper (`[a | :b]`, Erlang's
  `-attr([a|b]).`, an iolist `["x" | "y"]`), and `Enum`, `length/1`,
  `++`, `Keyword` and `in` all raise on one. Ask this before handing a
  literal or a resolved value to any of them; `is_list/1` is not enough.
  """
  @spec proper_list?(term()) :: boolean()
  def proper_list?([]), do: true
  def proper_list?([_ | tail]), do: proper_list?(tail)
  def proper_list?(_), do: false

  @doc """
  The elements of `term` when it is a proper list, and `[]` otherwise:
  what a walk over a literal list can safely enumerate. An improper list
  is a value the runtime would reject wherever a list is expected, so
  reading nothing from it is the quiet answer.
  """
  @spec list_elements(term()) :: list()
  def list_elements(term), do: if(proper_list?(term), do: term, else: [])

  @doc """
  Whether `pred` holds for any part of an instruction or operand: the
  term itself, then every element of its tuples and lists, improper
  tails included.

  A `{:literal, value}` operand is asked about as a whole but not entered.
  Its value is data, not operands: the literal `{:x, 1}` is not the
  register x1, and a walk that went inside took one for a read of the
  register. Use `value_contains?/2` to search a literal's value. (What an
  instruction reads and writes is `Argus.Instr`'s to say; this is for
  a question about operands it does not answer.)
  """
  @spec mentions?(term(), (term() -> boolean())) :: boolean()
  def mentions?(term, pred) do
    pred.(term) or mentions_within?(term, pred)
  end

  defp mentions_within?({:literal, _value}, _pred), do: false

  defp mentions_within?(term, pred) when is_tuple(term),
    do: term |> Tuple.to_list() |> any_element?(pred, &mentions?/2)

  defp mentions_within?(term, pred) when is_list(term), do: any_element?(term, pred, &mentions?/2)
  defp mentions_within?(_term, _pred), do: false

  @doc """
  Whether `pred` holds for any part of a value — a literal's, or one
  `resolve_register/3` rebuilt: the value itself, then every element of
  its tuples, lists (improper tails included) and maps (keys and values,
  structs included).
  """
  @spec value_contains?(term(), (term() -> boolean())) :: boolean()
  def value_contains?(value, pred) do
    pred.(value) or value_contains_within?(value, pred)
  end

  defp value_contains_within?(value, pred) when is_tuple(value),
    do: value |> Tuple.to_list() |> any_element?(pred, &value_contains?/2)

  defp value_contains_within?(value, pred) when is_list(value),
    do: any_element?(value, pred, &value_contains?/2)

  # Map.to_list/1, not Enum: a struct literal (an `Ecto.Query` built at
  # compile time) is a map that need not implement Enumerable.
  defp value_contains_within?(value, pred) when is_map(value),
    do: value |> Map.to_list() |> any_element?(pred, &value_contains?/2)

  defp value_contains_within?(_value, _pred), do: false

  # Enum.any?/2 raises at an improper tail; this asks the tail itself.
  defp any_element?([], _pred, _ask), do: false

  defp any_element?([head | tail], pred, ask),
    do: ask.(head, pred) or any_element?(tail, pred, ask)

  defp any_element?(tail, pred, ask), do: ask.(tail, pred)

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

  # --- Label scanning ---

  @doc """
  Return instructions starting from a given label number.

  Scans forward through the instruction list for `{:label, label_num}` and
  returns all instructions from that label onward (inclusive). Returns `[]`
  if the label is not found.
  """
  @spec instructions_from_label([term()], non_neg_integer()) :: [term()]
  def instructions_from_label(instrs, label_num) do
    case Enum.drop_while(instrs, fn
           {:label, ^label_num} -> false
           _ -> true
         end) do
      [] -> []
      from_label -> from_label
    end
  end

  # --- Return tuple scanning ---

  # Check whether a put_tuple2 destination register flows to x0 before
  # a return instruction. Handles direct writes to x0 and single-step
  # moves from the destination to x0.
  defp tuple_flows_to_return?(instrs, idx, dst) do
    rest = Enum.drop(instrs, idx + 1)

    case register(dst) do
      {:x, 0} ->
        # Already in x0 — just check that a return follows without
        # another write to x0.
        Enum.any?(rest, fn
          :return -> true
          instr -> Instr.exits?(instr)
        end)

      other_reg ->
        # Look for a move from the dst register to x0 before return.
        Enum.reduce_while(rest, false, fn
          {:move, src, dst}, _acc ->
            if register(dst) == {:x, 0} and register(src) == other_reg,
              do: {:halt, true},
              else: {:cont, false}

          :return, _acc ->
            {:halt, false}

          instr, _acc ->
            if Instr.exits?(instr), do: {:halt, false}, else: {:cont, false}
        end)
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
    if proper_list?(a), do: {:ok, a ++ b}, else: :dynamic
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
    case walk(fn -> value(instrs, call_idx, register(register)) end) do
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
        if proper_list?(list), do: resolved, else: :dynamic

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
      case register(tail) do
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
      case register(src) do
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
        across(instrs, at, register(src), :dynamic, fn
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
    if register(dst) == reg, do: {:ok, key}, else: find_map_key(rest, reg)
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
    walk(fn -> traced(instrs, idx, register(register), none, answer) end)
  end

  defp traced(instrs, idx, reg, none, answer) do
    step({:trace, answer, idx, reg}, none, fn ->
      follow = fn at, next -> traced(instrs, at, register(next), none, answer) end

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
    walk(fn -> field(instrs, idx, register(register)) end)
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
          {:ok, {:literal, key}} -> {:ok, spell(key)}
          _ -> :dynamic
        end

      {nil, {:get_tuple_element, src, 1, _dst}} ->
        slow_path_field(instrs, at, register(src))

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
    walk(fn -> origin(instrs, call_idx, register(register)) end)
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
    do_keyword_value_register(instrs, idx, register(list_reg), key)
  end

  defp do_keyword_value_register(instrs, idx, list_reg, key) do
    case recent_writer(instrs, idx, list_reg) do
      {:ok, {:move, src, _}, widx} ->
        do_keyword_value_register(instrs, widx, register(src), key)

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
    case register(tail) do
      {kind, _} = reg when kind in [:x, :y] -> do_keyword_value_register(instrs, idx, reg, key)
      _ -> :no
    end
  end

  # A cons head is the `{key, value}` pair. Reachable as a register (a
  # runtime-built tuple) — resolve it to its put_tuple2 and read the value
  # operand when the key matches and the value is itself a register.
  defp pair_value_register(instrs, idx, head, key) do
    case register(head) do
      {kind, _} = reg when kind in [:x, :y] -> pair_from_reg(instrs, idx, reg, key)
      _ -> :no
    end
  end

  defp pair_from_reg(instrs, idx, reg, key) do
    case recent_writer(instrs, idx, reg) do
      {:ok, {:move, src, _}, widx} ->
        pair_from_reg(instrs, widx, register(src), key)

      {:ok, {:put_tuple2, _, {:list, [k_elem, v_elem]}}, widx} ->
        if pair_key_matches?(k_elem, key) and value_register(v_elem) do
          {:ok, register(v_elem), widx}
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

  defp value_register(operand), do: match?({kind, _} when kind in [:x, :y], register(operand))

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
    walk(fn -> arg(instrs, call_idx, register(register)) end)
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
    walk(fn -> fun_made(instrs, idx, register(register)) end)
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
    case register(operand) do
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

  # --- Shared readings ---

  @doc """
  Calls `handler.(facts, ctx, {mod, func, arity})` for every remote call
  in the module, from the call-site index the pipeline attached (or one
  built on the spot). `ctx` is the same `instr_ctx()` the per-instruction
  scanners pass, so `resolve_register/3` and friends work unchanged.
  """
  @spec each_remote_call(
          map(),
          Argus.Pipeline.Emit.facts(),
          (Argus.Pipeline.Emit.facts(), instr_ctx(), {module(), atom(), arity()} ->
             Argus.Pipeline.Emit.facts())
        ) :: Argus.Pipeline.Emit.facts()
  def each_remote_call(module_data, facts, handler) do
    module_data
    |> CallSites.for_module()
    |> Enum.reduce(facts, fn
      %{remote?: true, mfa: mfa} = site, acc ->
        handler.(acc, %{func_id: site.func_id, instrs: site.instrs, idx: site.idx}, mfa)

      _site, acc ->
        acc
    end)
  end

  @doc "Like `each_remote_call/3`, for remote and local calls alike."
  @spec each_call(
          map(),
          Argus.Pipeline.Emit.facts(),
          (Argus.Pipeline.Emit.facts(), instr_ctx(), {module(), atom(), arity()} ->
             Argus.Pipeline.Emit.facts())
        ) :: Argus.Pipeline.Emit.facts()
  def each_call(module_data, facts, handler) do
    module_data
    |> CallSites.for_module()
    |> Enum.reduce(facts, fn %{mfa: mfa} = site, acc ->
      handler.(acc, %{func_id: site.func_id, instrs: site.instrs, idx: site.idx}, mfa)
    end)
  end

  @doc """
  The control-flow graph of the function `ctx` is in, from the graphs
  the pipeline attached to `module_data` or built on the spot.
  """
  @spec cfg(map(), atom() | String.t(), arity()) :: Argus.Cfg.Function.t() | nil
  def cfg(%{cfg: cfgs}, name, arity) when is_map(cfgs),
    do: Map.get(cfgs, {to_string(name), arity})

  def cfg(module_data, name, arity) when is_atom(name),
    do: Argus.Cfg.build_for(module_data, name, arity)

  def cfg(module_data, name, arity) when is_binary(name),
    do: cfg(module_data, String.to_atom(name), arity)

  @doc """
  The module's reaching definitions with its parameters as sources
  (`Argus.Dataflow.reaching_uses/2` with `params: true`): the ones the
  pipeline attached to `module_data` (`nil` when it could not compute
  them), or computed on the spot for bare disassembly
  (`Argus.Instr.Reaching.uses/2`).
  """
  @spec reaching(map()) :: MapSet.t(Argus.Dataflow.reaching_use()) | nil
  def reaching(%{reaching: reaching}), do: reaching

  def reaching(%{module: mod, functions: functions}),
    do: Argus.Instr.Reaching.uses(mod, functions)

  @doc """
  The module's decoded Layer-1 facts — the relations
  `Argus.Pipeline.typed_relations/0` names — from the ones the pipeline
  attached to `module_data` or emitted and decoded on the spot. `nil` when the
  facts cannot be decoded — the pipeline records the same `nil`, so an
  extractor that needs them loses only what they provide.
  """
  @spec typed(map()) :: Argus.Facts.t() | nil
  def typed(%{typed: typed}) when is_map(typed), do: typed
  def typed(%{typed: nil}), do: nil

  def typed(%{module: mod, exports: exports, attributes: attributes, functions: functions} = data) do
    mod
    |> Argus.Pipeline.Emit.emit_module(
      exports,
      Map.get(data, :imports, []),
      attributes,
      functions,
      Map.get(data, :line_table, %{})
    )
    |> Map.take(Argus.Pipeline.typed_relations())
    |> Argus.Facts.decode()
  rescue
    _ -> nil
  end

  @doc """
  The module's debug-info chunk as `:beam_lib.chunks/2` decodes it
  (`{:debug_info_v1, backend, data}`), or `:error` when there is none to
  read: the one the pipeline read for the extractors that ask
  (`module_data.debug_info`), or read on the spot from the beam the
  pipeline handed over — or, for bare disassembly, from the code path.
  An Elixir module's chunk holds its whole definition, which is why it is
  read once rather than by each extractor that wants a part of it.
  """
  @spec debug_info(map()) :: {:ok, tuple()} | :error
  def debug_info(%{debug_info: debug_info}), do: debug_info

  def debug_info(module_data) do
    with {:ok, source} <- chunk_source(module_data),
         {:ok, {_module, [debug_info: chunk]}} <- :beam_lib.chunks(source, [:debug_info]) do
      {:ok, chunk}
    else
      _ -> :error
    end
  end

  defp chunk_source(%{beam: beam}) when is_binary(beam) do
    cond do
      BeamSpy.BeamFile.beam_data?(beam) -> {:ok, beam}
      File.regular?(beam) -> {:ok, String.to_charlist(beam)}
      true -> :error
    end
  end

  defp chunk_source(%{module: mod}) do
    case :code.which(mod) do
      path when is_list(path) -> {:ok, path}
      _ -> :error
    end
  end

  @doc """
  What identifies the value in `register` at `idx`, in the vocabulary two
  sites can be joined on: `{"literal", inspected}` for an atom, binary or
  integer; `{"param", "N"}` when it is still the function's parameter N;
  `{"field", key}` when it was read from a map under a literal key; else
  `{"dynamic", ""}`. A lookup and a create that agree on source and key
  name the same thing — the identity-through-a-name idea the timer rules
  use, spelled once.

  Given `origins` (`{origins_index(module_data), func_id}`), a value that
  is none of those can still be `{"local", instr_id}`: the one
  instruction that made it, found through reaching definitions and
  followed back through copies (moves, swaps, trims). Two operands with the same origin hold
  the same value — `key = {name, type}` handed to a read and then to a
  write — although nothing says what it is. Several definitions reaching
  the read (a join) stay dynamic. The instruction ID names a site in one
  function, so a local identity never agrees with anything outside it.
  """
  @spec key_identity([term()], non_neg_integer(), register(), origins() | nil) ::
          {String.t(), String.t()}
  def key_identity(instrs, idx, register, origins \\ nil) do
    case resolve_register(instrs, idx, register) do
      {:ok, value}
      when (is_atom(value) and value != :dynamic) or is_binary(value) or is_integer(value) ->
        {"literal", spell(value)}

      _ ->
        case arg_position(instrs, idx, register) do
          {:ok, pos} ->
            {"param", to_string(pos)}

          :no ->
            case map_field_of(instrs, idx, register) do
              {:ok, key} -> {"field", key}
              :dynamic -> local_identity(instrs, idx, register, origins)
            end
        end
    end
  end

  @typedoc """
  The reaching definitions of one module keyed by the read, and the
  function being asked about: what `key_identity/4` needs to name a value
  by the instruction that made it.
  """
  @type origins :: {%{{String.t(), non_neg_integer(), String.t()} => [term()]}, String.t()}

  @doc """
  The module's reaching definitions (`reaching/1`) indexed by the read,
  `{func_id, idx, reg}`: paired with a function ID, the `origins` that
  `key_identity/4` takes. The pipeline builds it once per module as
  `module_data.origins_index`; this builds it for bare disassembly, and
  is empty when the facts cannot be decoded, which leaves every identity
  as it was without one.
  """
  @spec origins_index(map()) :: %{{String.t(), non_neg_integer(), String.t()} => [term()]}
  def origins_index(%{origins_index: index}), do: index

  def origins_index(module_data) do
    case reaching(module_data) do
      nil ->
        %{}

      reaching ->
        Enum.group_by(
          reaching,
          fn {_source, reg, %InstrId{module: m, func: f, arity: a, idx: idx}} ->
            {InstrId.func_id(m, f, a), idx, reg}
          end,
          fn {source, _reg, _use} -> source end
        )
    end
  end

  # Moves and swaps are followed to what they copy; a chain longer than
  # this is a loop in the definitions (a receive loop), and names nothing.
  @max_move_chain 32

  defp local_identity(instrs, idx, register, origins, depth \\ 0)
  defp local_identity(_instrs, _idx, _register, nil, _depth), do: {"dynamic", ""}

  defp local_identity(_instrs, _idx, _register, _origins, depth) when depth > @max_move_chain,
    do: {"dynamic", ""}

  defp local_identity(instrs, idx, register, {index, func_id} = origins, depth) do
    with {kind, n} when kind in [:x, :y] <- register(register),
         [%InstrId{idx: def_idx}] <- Map.get(index, {func_id, idx, "#{kind}#{n}"}) do
      case Instr.copy_source(Reaching.at(instrs, def_idx), {kind, n}) do
        {skind, _} = reg when skind in [:x, :y] ->
          local_identity(instrs, def_idx, reg, origins, depth + 1)

        nil ->
          {"local", InstrId.mint(func_id, def_idx)}

        _literal ->
          {"dynamic", ""}
      end
    else
      _ -> {"dynamic", ""}
    end
  end

  @doc """
  `key_identity/4` for element `n` of the tuple in `register` at `idx`: an
  ETS object's key, a Mnesia record's table and key. The tuple is built by
  `put_tuple2` on the way to `idx` (through copies), or is one literal;
  when the arms of a `case` each build it, their identities must agree. A
  tuple from anywhere else — a parameter passed straight through, a call
  result — says nothing about its elements, and is `{"dynamic", ""}`:
  resolving the whole tuple would lose WHICH parameter an element was.
  """
  @spec tuple_element_identity(
          [term()],
          non_neg_integer(),
          register(),
          non_neg_integer(),
          origins() | nil
        ) :: {String.t(), String.t()}
  def tuple_element_identity(instrs, idx, register, n, origins \\ nil) do
    walk(fn -> element_of(instrs, idx, register(register), n, origins) end)
  end

  @dynamic_identity {"dynamic", ""}

  defp element_of(instrs, idx, reg, n, origins) do
    step({:element, idx, reg, n}, @dynamic_identity, fn ->
      across(instrs, idx, reg, @dynamic_identity, fn
        {:param, _k} ->
          @dynamic_identity

        at ->
          case Reaching.at(instrs, at) do
            {:put_tuple2, _dst, {:list, elements}} when length(elements) > n ->
              element_identity(instrs, at, Enum.at(elements, n), origins)

            instr ->
              case Instr.copy_source(instr, reg) do
                {:literal, tuple} when is_tuple(tuple) and tuple_size(tuple) > n ->
                  {"literal", spell(elem(tuple, n))}

                {kind, _} = source when kind in [:x, :y] ->
                  element_of(instrs, at, source, n, origins)

                _ ->
                  @dynamic_identity
              end
          end
      end)
    end)
  end

  defp element_identity(_instrs, _idx, {:atom, atom}, _origins), do: {"literal", inspect(atom)}
  defp element_identity(_instrs, _idx, {:integer, n}, _origins), do: {"literal", inspect(n)}

  defp element_identity(_instrs, _idx, {:literal, value}, _origins),
    do: {"literal", spell(value)}

  defp element_identity(instrs, idx, operand, origins) do
    case register(operand) do
      {kind, _n} = reg when kind in [:x, :y] -> key_identity(instrs, idx, reg, origins)
      _other -> {"dynamic", ""}
    end
  end

  @doc """
  The instructions of a module that copy registers — `move`, `fmove`,
  `swap`, `trim`. An extractor that derives
  what an instruction writes from what it reads needs them: a `trim`
  writes each kept slot from one other slot, a `swap` each register from
  the other, and deriving every write from every read mixes them
  (`copy_read/2`). Keyed by instruction ID, as the facts are.
  """
  @spec copies(map()) :: %{InstrId.t() => tuple()}
  def copies(%{module: mod, functions: functions}) do
    for {:function, name, arity, _entry, instrs} <- functions,
        func_id = Normalize.func_id(mod, name, arity),
        {instr, idx} <- Enum.with_index(instrs),
        copy?(instr),
        {:ok, id} = InstrId.parse(InstrId.mint(func_id, idx)),
        into: %{},
        do: {id, instr}
  end

  defp copy?(instr) when is_tuple(instr), do: elem(instr, 0) in [:move, :fmove, :swap, :trim]
  defp copy?(_instr), do: false

  @doc """
  The register, spelled as the facts spell it (`"y3"`), that the copy
  instruction `instr` read the value it wrote into `reg` from — `nil`
  when it wrote a literal, or did not write `reg`.
  """
  @spec copy_read(tuple(), String.t()) :: String.t() | nil
  def copy_read(instr, reg) do
    case Instr.copy_source(instr, parse_reg(reg)) do
      {kind, n} when kind in [:x, :y, :fr] -> "#{kind}#{n}"
      _literal -> nil
    end
  end

  defp parse_reg("fr" <> n), do: {:fr, String.to_integer(n)}
  defp parse_reg("x" <> n), do: {:x, String.to_integer(n)}
  defp parse_reg("y" <> n), do: {:y, String.to_integer(n)}

  @doc "The graph of the function an `instr_ctx()` is in."
  @spec cfg(map(), instr_ctx()) :: Argus.Cfg.Function.t() | nil
  def cfg(module_data, %{func_id: func_id}) do
    {name, arity} = Normalize.func_id_name_arity(func_id)
    cfg(module_data, name, arity)
  end

  @doc """
  A register operand with its type annotation stripped: `{:tr, reg, type}`
  becomes `reg`. Seven extractors carried a copy of this clause.
  """
  @spec register(term()) :: term()
  def register({:tr, reg, _type}), do: reg
  def register(other), do: other

  @doc """
  Every tuple a function returns, as `{index, elements}`: built by
  `put_tuple2` (into `{x,0}`, or into a register moved to `{x,0}` before
  the return), by the pre-OTP-24 `put_tuple`/`put` sequence, or folded by
  the compiler into one literal moved into `{x,0}`. Elements are in the
  instruction vocabulary — `{:atom, a}`, `{:integer, n}`, `{:literal, t}`,
  a register — whatever their source, so a rule reading `[{:atom, :ok} |
  rest]` reads all three shapes.
  """
  @spec return_shapes([tuple()]) :: [{non_neg_integer(), [term()]}]
  def return_shapes(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn
      # Built straight into {x,0}: it is the return only if the return is
      # next. A tuple raised with erlang:error/1 sits in {x,0} too, and a
      # later, unrelated return must not claim it.
      {{:put_tuple2, {:x, 0}, {:list, elements}}, idx} ->
        if returns_next?(instrs, idx + 1), do: [{idx, elements}], else: []

      {{:put_tuple2, {:tr, {:x, 0}, _}, {:list, elements}}, idx} ->
        if returns_next?(instrs, idx + 1), do: [{idx, elements}], else: []

      {{:put_tuple2, dst, {:list, elements}}, idx} ->
        if tuple_flows_to_return?(instrs, idx, dst), do: [{idx, elements}], else: []

      {{:put_tuple, _size, {:x, 0}}, idx} ->
        puts = instrs |> Enum.drop(idx + 1) |> Enum.take_while(&match?({:put, _}, &1))

        if returns_next?(instrs, idx + 1 + length(puts)),
          do: [{idx, Enum.map(puts, fn {:put, element} -> element end)}],
          else: []

      {{:move, {:literal, tuple}, {:x, 0}}, idx} when is_tuple(tuple) and tuple_size(tuple) > 0 ->
        if returns_next?(instrs, idx + 1),
          do: [{idx, tuple |> Tuple.to_list() |> Enum.map(&literal_element/1)}],
          else: []

      _ ->
        []
    end)
  end

  defp literal_element(atom) when is_atom(atom), do: {:atom, atom}
  defp literal_element(int) when is_integer(int), do: {:integer, int}
  defp literal_element(term), do: {:literal, term}

  # Line markers and frame teardown may sit between the tuple and the
  # return. Anything else means the tuple is not what comes back.
  defp returns_next?(instrs, idx) do
    case Enum.at(instrs, idx) do
      :return -> true
      {:line, _} -> returns_next?(instrs, idx + 1)
      {:deallocate, _} -> returns_next?(instrs, idx + 1)
      {:trim, _, _} -> returns_next?(instrs, idx + 1)
      _ -> false
    end
  end

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
