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
  - **`resolve_register/3`** — backward dataflow: determine a register's value
    at a specific call site by walking preceding instructions
  - **`get_behaviours/1`** — extract behaviour modules from attributes
  - **`find_function/3`** — look up a function's instructions by name and arity
  """

  alias Argus.Pipeline.Normalize

  @type register :: {:x, non_neg_integer()} | {:y, non_neg_integer()}

  @typedoc """
  Per-instruction context passed to scan handlers. Carries everything an
  extractor needs to call `resolve_register/3` against the surrounding code.
  """
  @type instr_ctx :: %{
          func_id: String.t(),
          instrs: [tuple()],
          idx: non_neg_integer()
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
  Like `scan_functions/4` but only invokes the handler when the instruction
  matches `match_remote_call/1`. The handler receives the resolved
  `{module, function, arity}` tuple in place of the raw instruction.
  """
  @spec scan_remote_calls(
          module(),
          [tuple()],
          Argus.Pipeline.Emit.facts(),
          (Argus.Pipeline.Emit.facts(), instr_ctx(), {module(), atom(), arity()} ->
             Argus.Pipeline.Emit.facts())
        ) :: Argus.Pipeline.Emit.facts()
  def scan_remote_calls(mod, functions, facts \\ %{}, handler) do
    scan_functions(mod, functions, facts, fn inner, ctx, instr ->
      case match_remote_call(instr) do
        {:ok, m, f, a} -> handler.(inner, ctx, {m, f, a})
        :none -> inner
      end
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

  @doc """
  Scan instructions for return value construction patterns.

  Finds `put_tuple2` instructions whose destination flows to `{:x, 0}`
  before a return, indicating constructed return tuples. Returns a list
  of `{index, elements}` pairs where `elements` is the flat element list
  from the `put_tuple2` instruction.

  Used by extractors that need to detect return shapes like `{:next_state, ...}`
  or `{:error, ...}`.
  """
  @spec scan_return_tuples([term()]) :: [{non_neg_integer(), [term()]}]
  def scan_return_tuples(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:put_tuple2, dst, {:list, elements}}, idx} ->
        if tuple_flows_to_return?(instrs, idx, dst), do: [{idx, elements}], else: []

      _ ->
        []
    end)
  end

  # Check whether a put_tuple2 destination register flows to x0 before
  # a return instruction. Handles direct writes to x0 and single-step
  # moves from the destination to x0.
  defp tuple_flows_to_return?(instrs, idx, dst) do
    rest = Enum.drop(instrs, idx + 1)

    case normalize_reg(dst) do
      {:x, 0} ->
        # Already in x0 — just check that a return follows without
        # another write to x0.
        Enum.any?(rest, fn
          :return -> true
          instr -> barrier?(instr)
        end)

      other_reg ->
        # Look for a move from the dst register to x0 before return.
        Enum.reduce_while(rest, false, fn
          {:move, src, {:x, 0}}, _acc ->
            if normalize_reg(src) == other_reg, do: {:halt, true}, else: {:cont, false}

          {:move, src, {:tr, {:x, 0}, _}}, _acc ->
            if normalize_reg(src) == other_reg, do: {:halt, true}, else: {:cont, false}

          :return, _acc ->
            {:halt, false}

          instr, _acc ->
            if barrier?(instr), do: {:halt, false}, else: {:cont, false}
        end)
    end
  end

  defp normalize_reg({:tr, reg, _}), do: reg
  defp normalize_reg(reg), do: reg

  # Walk the (already-reversed) tail looking for the most recent writer of
  # `src_reg`. If it's a remote call, return `{:ok, {:call_field, mfa, idx}}`
  # so the caller can correlate this register with the call's return.
  # Stops at barriers since code past them isn't on the current execution path.
  defp find_call_writer([], _src_reg, _idx), do: :dynamic

  defp find_call_writer([instr | rest], src_reg, idx) do
    cond do
      barrier?(instr) ->
        :dynamic

      writes_to?(instr, src_reg) ->
        case call_target(instr) do
          {:ok, mfa} -> {:ok, {:call_field, mfa, idx}}
          :none -> :dynamic
        end

      true ->
        find_call_writer(rest, src_reg, idx)
    end
  end

  defp call_target({:call_ext, _, {:extfunc, mod, func, arity}}) do
    {:ok, "#{inspect(mod)}:#{func}/#{arity}"}
  end

  defp call_target({:call_ext_only, _, {:extfunc, mod, func, arity}}) do
    {:ok, "#{inspect(mod)}:#{func}/#{arity}"}
  end

  defp call_target({:call_ext_last, _, {:extfunc, mod, func, arity}, _}) do
    {:ok, "#{inspect(mod)}:#{func}/#{arity}"}
  end

  defp call_target(_), do: :none

  # Apply a whitelisted pure BIF to its resolved arguments. Returns
  # `{:ok, result}` if every argument resolved to a concrete value AND
  # the operation is well-defined; returns `:dynamic` otherwise.
  #
  # Each clause is paranoid about argument shapes: we never call BIFs
  # like `:erlang.element/2` with the wrong types because that raises,
  # which would crash extraction. We bail to `:dynamic` on any mismatch.
  defp apply_pure_bif(:element, [idx, tuple])
       when is_integer(idx) and is_tuple(tuple) and idx > 0 and idx <= tuple_size(tuple) do
    {:ok, elem(tuple, idx - 1)}
  end

  defp apply_pure_bif(:tuple_size, [tuple]) when is_tuple(tuple), do: {:ok, tuple_size(tuple)}
  defp apply_pure_bif(:map_size, [map]) when is_map(map), do: {:ok, map_size(map)}
  defp apply_pure_bif(:byte_size, [bin]) when is_binary(bin), do: {:ok, byte_size(bin)}
  defp apply_pure_bif(:length, [list]) when is_list(list), do: {:ok, length(list)}
  defp apply_pure_bif(:hd, [[h | _]]), do: {:ok, h}
  defp apply_pure_bif(:tl, [[_ | t]]), do: {:ok, t}

  defp apply_pure_bif(:atom_to_binary, [atom]) when is_atom(atom) and not is_nil(atom) do
    {:ok, Atom.to_string(atom)}
  end

  defp apply_pure_bif(:++, [a, b]) when is_list(a) and is_list(b), do: {:ok, a ++ b}

  defp apply_pure_bif(_op, _args), do: :dynamic

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

  Function parameters and pattern-matched-destructure-of-call-result are
  represented via separate helpers (`arg_position/3` and the
  `{:call_field, mfa, idx}` shape returned for `get_tuple_element` of a
  call result) to keep this function's value contract free of markers.
  """
  @spec resolve_register([term()], non_neg_integer(), register()) :: {:ok, term()} | :dynamic
  def resolve_register(instrs, call_idx, register) do
    preceding = instrs |> Enum.take(call_idx) |> Enum.reverse()
    do_resolve(preceding, normalize_reg(register))
  end

  @doc """
  Find the MFA of the most recent remote call (`call_ext` /
  `call_ext_only` / `call_ext_last`) that wrote to `register` within
  the current execution path. Returns `{:ok, {mod, func, arity}}` or
  `:no`.

  Walks back from `call_idx` honoring the same control-flow barriers
  as `resolve_register/3`. Useful for recognizing patterns like
  `Process.send_after(self(), :tick, _)` where the target register was
  populated by `:erlang.self/0` immediately before the call site.
  """
  @spec last_call_writer([term()], non_neg_integer(), register()) ::
          {:ok, {module(), atom(), arity()}} | :no
  def last_call_writer(instrs, call_idx, register) do
    preceding = instrs |> Enum.take(call_idx) |> Enum.reverse()
    do_last_call_writer(preceding, normalize_reg(register))
  end

  @doc """
  Determine whether `register` is a function parameter at instruction
  index `call_idx`. Returns `{:ok, n}` if it's the n-th parameter (so
  `{:x, n}` for `n < arity`), or `:no` otherwise.

  A register is "still a parameter" at index `call_idx` if walking back
  through the preceding instructions hits the function-entry `func_info`
  without crossing a write to that register or a control-flow barrier.

  This lets extractors distinguish "I don't know" from "this is
  parameter N", which matters for client-API functions like
  `def get(pid), do: GenServer.call(pid, :get)`.
  """
  @spec arg_position([term()], non_neg_integer(), register()) ::
          {:ok, non_neg_integer()} | :no
  def arg_position(instrs, call_idx, register) do
    preceding = instrs |> Enum.take(call_idx) |> Enum.reverse()
    do_arg_position(preceding, normalize_reg(register))
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

  # Walk back looking for the function entry. If we hit it without finding
  # a write or a barrier, the register is still in its function-arg state.
  defp do_arg_position([], _reg), do: :no

  defp do_arg_position([{:func_info, _, _, arity} | _], {:x, n}) when n < arity,
    do: {:ok, n}

  defp do_arg_position([{:func_info, _, _, _} | _], _reg), do: :no

  defp do_arg_position([instr | rest], reg) do
    cond do
      barrier?(instr) -> :no
      writes_to?(instr, reg) -> :no
      true -> do_arg_position(rest, reg)
    end
  end

  defp do_last_call_writer([], _reg), do: :no

  defp do_last_call_writer([instr | rest], reg) do
    cond do
      barrier?(instr) ->
        :no

      writes_to?(instr, reg) ->
        case instr do
          {:call_ext, _, {:extfunc, m, f, a}} ->
            {:ok, {m, f, a}}

          {:call_ext_only, _, {:extfunc, m, f, a}} ->
            {:ok, {m, f, a}}

          {:call_ext_last, _, {:extfunc, m, f, a}, _} ->
            {:ok, {m, f, a}}

          # BIFs are implicit :erlang functions; the arity is the length
          # of the args list. This catches `self()`, `node()`, and other
          # Erlang built-ins that resolve_register doesn't reach.
          {:bif, name, _, args, _dst} ->
            {:ok, {:erlang, name, length(args)}}

          {:gc_bif, name, _, _live, args, _dst} ->
            {:ok, {:erlang, name, length(args)}}

          _ ->
            :no
        end

      true ->
        do_last_call_writer(rest, reg)
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

  # Pure BIF whitelist: when both args resolve to literals we can compute
  # the result statically. The whitelist only includes BIFs whose result
  # is fully determined by their arguments — no clock, no process state,
  # no atom-table mutation.
  defp interpret({:bif, :element, _, [idx_op, tuple_op], _dst}, rest, _reg) do
    apply_pure_bif(:element, [resolve_element(rest, idx_op), resolve_element(rest, tuple_op)])
  end

  defp interpret({:bif, :tuple_size, _, [tuple_op], _dst}, rest, _reg) do
    apply_pure_bif(:tuple_size, [resolve_element(rest, tuple_op)])
  end

  defp interpret({:bif, :map_size, _, [map_op], _dst}, rest, _reg) do
    apply_pure_bif(:map_size, [resolve_element(rest, map_op)])
  end

  defp interpret({:bif, :byte_size, _, [bin_op], _dst}, rest, _reg) do
    apply_pure_bif(:byte_size, [resolve_element(rest, bin_op)])
  end

  defp interpret({:bif, :hd, _, [list_op], _dst}, rest, _reg) do
    apply_pure_bif(:hd, [resolve_element(rest, list_op)])
  end

  defp interpret({:bif, :tl, _, [list_op], _dst}, rest, _reg) do
    apply_pure_bif(:tl, [resolve_element(rest, list_op)])
  end

  defp interpret({:bif, :atom_to_binary, _, [atom_op], _dst}, rest, _reg) do
    apply_pure_bif(:atom_to_binary, [resolve_element(rest, atom_op)])
  end

  defp interpret({:bif, _, _, _, _dst}, _rest, _reg), do: :dynamic

  # gc_bif has the same shape as bif plus a `live` count between fail and args.
  defp interpret({:gc_bif, :length, _, _live, [list_op], _dst}, rest, _reg) do
    apply_pure_bif(:length, [resolve_element(rest, list_op)])
  end

  defp interpret({:gc_bif, :++, _, _live, [a_op, b_op], _dst}, rest, _reg) do
    apply_pure_bif(:++, [resolve_element(rest, a_op), resolve_element(rest, b_op)])
  end

  defp interpret({:gc_bif, _, _, _, _, _dst}, _rest, _reg), do: :dynamic

  defp interpret({:get_tuple_element, src, idx, _dst}, rest, _reg) do
    case resolve_source(rest, src) do
      {:ok, tuple} when is_tuple(tuple) and idx < tuple_size(tuple) ->
        {:ok, elem(tuple, idx)}

      _ ->
        # Source isn't a known literal tuple. If a remote call wrote it
        # most recently, surface that as `{:call_field, mfa, idx}` so
        # callers can recognize "this register is field N of <call>'s
        # return". This is the resolution shape that lets pattern-matched
        # destructuring (`{:ok, val} = call()`) be traceable through the
        # backward dataflow.
        find_call_writer(rest, normalize_reg(src), idx)
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
