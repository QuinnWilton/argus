defmodule Argus.Extractors.OTP do
  @moduledoc """
  OTP pattern extractor.

  Detects OTP behaviour implementations, process links, and the
  init/handle_continue handshake from module attributes and bytecode.
  The call facts (`sync_call`, `async_cast`, `sup_call`) come from
  `Argus.Extractors.ApiCalls`.

  ## Emitted facts

  - `implements_behaviour(mod, behaviour)` — module implements a behaviour
  - `started_as(mod, behaviour)` — a start or an `enter_loop` in the
    module's code names `mod` the callback module of `behaviour`
    (`Argus.Extractor.GenStarts`), declared or not
  - `process_link(from_mod, to_mod)` — Process.link / :erlang.link call
  - `init_continues_to(mod, tag)` — module's init/1 returns `{:continue, tag}`
  - `handle_continue_clause(mod, tag, func_id)` — handle_continue/2 clause matching `tag`
  - `continue_return(id, func, clause, tag)` — the return at `id` hands the
    process to handle_continue/2 with a term tagged `tag`, from the clause
    of `func` for its first argument's tag `clause`
  - `timeout_return(id, func, clause)` — the return at `id` arms the loop's
    idle timeout, whose `:timeout` message comes if nothing else does
  - `start_acked(id, func)` — the call or receive at `id` runs only after
    `func` has acknowledged its start: every path from the function's
    entry to it passes a `:proc_lib.init_ack/1,2`
  - `last_send(id, func)` — the send at `id` is `func`'s last act: every
    path on from it returns, with no call, send or receive between

  ## After the start is acknowledged

  A process started with `:proc_lib.start_link/3` holds its starter until
  it calls `:proc_lib.init_ack/1`; an init/1 that enters its own loop
  (`:gen_server.enter_loop/3`, OTP's logger_olp) acks first and waits
  afterwards, and what it waits for then is its loop's business, not the
  start's. Read on the function's graph: the instructions reached from
  the entry along paths that have not yet passed an init_ack are the
  start's; every other call and receive is `start_acked`. An ack made
  in a helper the function calls is not seen.
  """

  @behaviour Argus.Extractor

  alias Argus.Cfg.Walk
  alias Argus.Extractor.Dispatch
  alias Argus.Extractor.GenStarts
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId

  import Argus.Extractor.Helpers, only: [cfg: 3, each_remote_call: 3, get_behaviours: 1]
  import Argus.Extractor.Facts, only: [add_fact: 3, track_dynamic: 5]
  import Argus.Extractor.Resolve, only: [arg_position: 3, resolve_callee: 1]
  import Argus.Extractor.Shapes, only: [return_shapes: 1]

  @impl true
  def relations,
    do: [
      :continue_return,
      :handle_continue_clause,
      :implements_behaviour,
      :init_continues_to,
      :process_link,
      :last_send,
      :start_acked,
      :started_as,
      :timeout_return
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = module_data.module
    mod_str = inspect(mod)
    functions = module_data.functions

    %{}
    |> extract_behaviours(mod_str, module_data.attributes)
    |> extract_started_as(module_data)
    |> extract_link_calls(mod_str, module_data)
    |> extract_continue_facts(mod, mod_str, functions)
    |> extract_loop_asks(mod, functions)
    |> extract_start_acked(module_data)
    |> extract_last_sends(module_data)
  end

  # ── What a callback's return asks of its loop ───────────────────────
  #
  # Two things a return can ask the loop for next, each a message the
  # process makes itself (clientlib/runs.dl reads them as such):
  #
  # - `continue_return`: `{:ok, state, {:continue, t}}`, `{:noreply,
  #   state, {:continue, t}}` or `{:reply, reply, state, {:continue, t}}`
  #   hands the process to handle_continue/2 with `t`. Its tag is `t`'s
  #   atom, or its tuple's first element, `*` when the return does not
  #   spell it.
  # - `timeout_return`: `{:ok, state, ms}`, `{:noreply, state, ms}` or
  #   `{:reply, reply, state, ms}` arms the loop's idle timeout, whose
  #   `:timeout` message comes when nothing else does first. A value the
  #   return does not spell is taken as a timeout: only `:infinity`,
  #   `:hibernate` and a continue are known not to be one.
  #
  # Read in init/1, in a handler, and in a helper whose result a callback
  # returns (its callers are the rules' to follow), per return and clause:
  # the clause is the tag the function's first argument was established
  # to be on the paths to the return (Dispatch.argument_tags/2, as
  # returned_update reads one), `*` where none was.
  defp extract_loop_asks(facts, mod, functions) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      returns =
        for {:return, idx} <- Enum.with_index(instrs),
            ask <- loop_asks(instrs, idx),
            do: {idx, ask}

      emit_loop_asks(acc, InstrId.func_id(mod, name, arity), instrs, returns)
    end)
  end

  defp emit_loop_asks(facts, _func_id, _instrs, []), do: facts

  defp emit_loop_asks(facts, func_id, instrs, returns) do
    tags = Dispatch.argument_tags(instrs, {:x, 0})

    returns
    |> Enum.flat_map(fn {idx, ask} ->
      for clause <- return_clauses(Map.get(tags, idx)), do: {idx, clause, ask}
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(facts, fn
      {idx, clause, {:continue, tag}}, acc ->
        add_fact(acc, :continue_return, [InstrId.mint(func_id, idx), func_id, clause, tag])

      {idx, clause, :timeout}, acc ->
        add_fact(acc, :timeout_return, [InstrId.mint(func_id, idx), func_id, clause])
    end)
  end

  defp return_clauses(nil), do: ["*"]

  defp return_clauses(set) do
    if MapSet.member?(set, :any), do: ["*"], else: Enum.sort(set)
  end

  # What the tuple the return at idx hands back asks for: `{:continue,
  # tag}` or `:timeout`, from its last element when the tuple is a
  # callback's `{:ok, state, x}`, `{:noreply, state, x}` or `{:reply,
  # reply, state, x}`.
  defp loop_asks(instrs, idx) do
    instrs
    |> Resolve.writers(idx, {:x, 0})
    |> Enum.flat_map(fn
      {:param, _k} ->
        []

      at ->
        case Reaching.at(instrs, at) do
          {:put_tuple2, _dst, {:list, [{:atom, head} | rest]}} ->
            if asking?(head, length(rest)), do: slot_asks(instrs, at, List.last(rest)), else: []

          {:move, {:literal, tuple}, _dst} when is_tuple(tuple) and tuple_size(tuple) > 0 ->
            [head | rest] = Tuple.to_list(tuple)
            if asking?(head, length(rest)), do: literal_asks(List.last(rest)), else: []

          _ ->
            []
        end
    end)
    |> Enum.uniq()
  end

  defp asking?(head, n) when head in [:ok, :noreply], do: n == 2
  defp asking?(:reply, n), do: n == 3
  defp asking?(_head, _n), do: false

  defp slot_asks(_instrs, _at, {:literal, term}), do: literal_asks(term)
  defp slot_asks(_instrs, _at, {:integer, _ms}), do: [:timeout]
  defp slot_asks(_instrs, _at, {:atom, atom}), do: literal_asks(atom)

  defp slot_asks(instrs, at, element) do
    case Instr.register(element) do
      {kind, _} = reg when kind in [:x, :y] ->
        instrs
        |> Resolve.writers(at, reg)
        |> Enum.flat_map(fn
          {:param, _k} ->
            [:timeout]

          w ->
            case Reaching.at(instrs, w) do
              {:put_tuple2, _dst, {:list, [{:atom, :continue}, term]}} ->
                [{:continue, continue_term_tag(instrs, w, term)}]

              {:move, {:literal, term}, _dst} ->
                literal_asks(term)

              {:move, {:integer, _ms}, _dst} ->
                [:timeout]

              {:move, {:atom, atom}, _dst} ->
                literal_asks(atom)

              _ ->
                [:timeout]
            end
        end)

      _ ->
        []
    end
  end

  defp literal_asks({:continue, term}), do: [{:continue, literal_tag(term)}]
  defp literal_asks(ms) when is_integer(ms), do: [:timeout]
  defp literal_asks(atom) when atom in [:infinity, :hibernate], do: []
  defp literal_asks(_term), do: []

  defp continue_term_tag(_instrs, _at, {:atom, atom}), do: inspect(atom)
  defp continue_term_tag(_instrs, _at, {:literal, term}), do: literal_tag(term)

  defp continue_term_tag(instrs, at, element) do
    with {kind, _} = reg when kind in [:x, :y] <- Instr.register(element),
         [w] <- Resolve.writers(instrs, at, reg),
         true <- is_integer(w),
         {:put_tuple2, _dst, {:list, [{:atom, head} | _]}} <- Reaching.at(instrs, w) do
      inspect(head)
    else
      _ -> "*"
    end
  end

  defp literal_tag(atom) when is_atom(atom), do: inspect(atom)

  defp literal_tag(tuple)
       when is_tuple(tuple) and tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)),
       do: inspect(elem(tuple, 0))

  defp literal_tag(_term), do: "*"

  # ── After the start is acknowledged ─────────────────────────────────

  defp extract_start_acked(facts, %{module: mod, functions: functions} = module_data) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      acks = for {instr, idx} <- Enum.with_index(instrs), init_ack?(instr), do: idx

      case acks do
        [] ->
          acc

        _ ->
          emit_acked(
            acc,
            InstrId.func_id(mod, name, arity),
            instrs,
            cfg(module_data, name, arity)
          )
      end
    end)
  end

  # No graph, no rows: a wait the fact cannot place after the ack stays
  # the start's.
  defp emit_acked(facts, _func_id, _instrs, nil), do: facts

  defp emit_acked(facts, func_id, instrs, fun) do
    {:done, before} =
      Walk.explore(fun, instrs, [Dispatch.entry_index(instrs)],
        on_instr: fn instr, _idx -> if init_ack?(instr), do: :prune, else: :continue end
      )

    for {instr, idx} <- Enum.with_index(instrs),
        waits?(instr),
        not MapSet.member?(before, idx),
        reduce: facts do
      acc -> add_fact(acc, :start_acked, [InstrId.mint(func_id, idx), func_id])
    end
  end

  defp init_ack?(instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, :proc_lib, :init_ack, arity} -> arity in [1, 2]
      _ -> false
    end
  end

  defp waits?({:loop_rec, _fail, _dst}), do: true
  defp waits?(instr), do: Instr.call?(instr) or Instr.tail_call?(instr)

  # ── A send that ends the function ───────────────────────────────────
  #
  # A process whose last act is to send its starter a message has done
  # everything else it does before the message is sent: a loader that
  # reports it is done (clientlib/handoff.dl). The send is the last act
  # when it is a tail call, or when every path on from it returns without
  # a call, a send or a receive. A function with a `try` or a `catch` is
  # not read: an exception after the send goes on in its handler.

  defp extract_last_sends(facts, %{module: mod, functions: functions} = module_data) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      sends = for {instr, idx} <- Enum.with_index(instrs), send?(instr), do: idx

      if sends == [] or Enum.any?(instrs, &handles?/1) do
        acc
      else
        emit_last_sends(
          acc,
          InstrId.func_id(mod, name, arity),
          instrs,
          sends,
          cfg(module_data, name, arity)
        )
      end
    end)
  end

  defp emit_last_sends(facts, _func_id, _instrs, _sends, nil), do: facts

  defp emit_last_sends(facts, func_id, instrs, sends, fun) do
    for idx <- sends, last_act?(fun, instrs, idx), reduce: facts do
      acc -> add_fact(acc, :last_send, [InstrId.mint(func_id, idx), func_id])
    end
  end

  defp last_act?(fun, instrs, idx) do
    if Instr.tail_call?(Enum.at(instrs, idx)) do
      true
    else
      verdict =
        Walk.explore(fun, instrs, [idx + 1],
          on_instr: fn instr, _at -> if acts?(instr), do: {:halt, :acts}, else: :continue end
        )

      match?({:done, _}, verdict)
    end
  end

  # `!`, and the calls that send: erlang:send/2,3 and Process.send/3.
  defp send?(:send), do: true

  defp send?(instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, :erlang, :send, arity} -> arity in [2, 3]
      {:ok, Process, :send, 3} -> true
      _ -> false
    end
  end

  defp acts?(:send), do: true
  defp acts?({op, _fail, _dst}) when op in [:loop_rec], do: true
  defp acts?({op, _label}) when op in [:wait], do: true
  defp acts?({:wait_timeout, _label, _time}), do: true
  defp acts?(instr), do: Instr.call?(instr) or Instr.tail_call?(instr)

  defp handles?({op, _reg, _label}) when op in [:try, :catch], do: true
  defp handles?(_instr), do: false

  # Two facts:
  #   - init_continues_to(mod, tag) when init/1 returns {:ok, _, {:continue, tag}}
  #   - handle_continue_clause(mod, tag, func_id) for each handle_continue/2 clause
  defp extract_continue_facts(facts, mod, mod_str, functions) do
    facts
    |> extract_init_continues(mod, mod_str, functions)
    |> extract_handle_continue_clauses(mod, mod_str, functions)
  end

  defp extract_init_continues(facts, _mod, mod_str, functions) do
    case Helpers.find_function(functions, :init, 1) do
      nil ->
        facts

      instrs ->
        # Two shapes are common in real BEAM bytecode:
        #   1. The whole return is a literal: `move {literal, {:ok, _, {:continue, tag}}}, x0`.
        #      The compiler folds the entire term when the state is also a literal.
        #   2. The return is built at runtime via `put_tuple2`. The third element
        #      is either a literal `{:continue, tag}` or another `put_tuple2`.
        instrs
        |> return_shapes()
        |> Enum.flat_map(fn {_idx, elements} -> List.wrap(continue_tag(elements)) end)
        |> Enum.uniq()
        |> Enum.reduce(facts, fn tag, acc ->
          add_fact(acc, :init_continues_to, [mod_str, tag])
        end)
    end
  end

  # Look for {:ok, _state, {:continue, tag}} or {:noreply, _state, {:continue, tag}}
  # shapes in a put_tuple2 element list.
  defp continue_tag([{:atom, :ok}, _state, third]), do: extract_continue_from_element(third)

  defp continue_tag([{:atom, :noreply}, _state, third]),
    do: extract_continue_from_element(third)

  defp continue_tag(_), do: nil

  defp extract_continue_from_element({:literal, {:continue, tag}}) when is_atom(tag),
    do: inspect(tag)

  defp extract_continue_from_element(_), do: nil

  # For handle_continue clauses, identify them by name + arity.
  defp extract_handle_continue_clauses(facts, _mod, mod_str, functions) do
    Enum.reduce(functions, facts, fn
      {:function, :handle_continue, 2, _entry, instrs}, acc ->
        func_id = "#{mod_str}:handle_continue/2"

        # The clause head dispatches on the first argument (the tag). We
        # can't easily separate clauses without more analysis, but we can
        # detect tag literals from the test instructions at the top.
        tags = clause_tags(instrs)

        if tags == [] do
          add_fact(acc, :handle_continue_clause, [mod_str, "dynamic", func_id])
        else
          Enum.reduce(tags, acc, fn tag, inner ->
            add_fact(inner, :handle_continue_clause, [mod_str, tag, func_id])
          end)
        end

      _, acc ->
        acc
    end)
  end

  # The tag literals handle_continue/2 dispatches on: the atoms an
  # `is_eq_exact` or `select_val` compares its first argument against.
  #
  # The tag arrives in {x,0}, but {x,0} is also the BEAM's first scratch
  # register, so once a clause body starts it holds whatever that body is
  # working on. Collecting every comparison on {x,0} recorded every atom
  # any clause happened to compare against — `:ok`, `nil` and `false` were
  # recorded as handle_continue tags across the corpus, roughly half the
  # rows in the relation. A comparison counts only where the writes that
  # reach {x,0} are the parameter itself (`Resolve.arg_position/3`), which
  # also finds the tag of a clause whose test follows another clause's
  # body.
  defp clause_tags(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn {instr, idx} ->
      case dispatch_tags(instr) do
        [] -> []
        tags -> if arg_position(instrs, idx, {:x, 0}) == {:ok, 0}, do: tags, else: []
      end
    end)
    |> Enum.uniq()
  end

  defp dispatch_tags({:test, :is_eq_exact, _, [reg, {:atom, tag}]}) when is_atom(tag),
    do: if(Instr.register(reg) == {:x, 0}, do: [inspect(tag)], else: [])

  defp dispatch_tags({:select_val, reg, _fail, {:list, pairs}}) do
    if Instr.register(reg) == {:x, 0} do
      pairs
      |> Enum.chunk_every(2)
      |> Enum.flat_map(fn
        [{:atom, tag}, _label] when is_atom(tag) -> [inspect(tag)]
        _ -> []
      end)
    else
      []
    end
  end

  defp dispatch_tags(_instr), do: []

  defp extract_behaviours(facts, mod_str, attrs) do
    attrs
    |> get_behaviours()
    |> Enum.reduce(facts, fn behaviour, acc ->
      add_fact(acc, :implements_behaviour, [mod_str, inspect(behaviour)])
    end)
  end

  defp extract_started_as(facts, module_data) do
    module_data
    |> GenStarts.callback_modules()
    |> Enum.reduce(facts, fn {mod, behaviour}, acc ->
      add_fact(acc, :started_as, [inspect(mod), inspect(behaviour)])
    end)
  end

  defp extract_link_calls(facts, mod_str, module_data) do
    each_remote_call(module_data, facts, fn acc, ctx, mfa ->
      handle_link(acc, mod_str, ctx, mfa)
    end)
  end

  defp handle_link(facts, mod_str, ctx, {Process, :link, 1}) do
    callee = resolve_callee(ctx)

    facts
    |> track_dynamic(callee, ctx, :process_link_target, :process_link)
    |> add_fact(:process_link, [mod_str, callee])
  end

  defp handle_link(facts, mod_str, ctx, {:erlang, :link, 1}) do
    callee = resolve_callee(ctx)

    facts
    |> track_dynamic(callee, ctx, :process_link_target, :process_link)
    |> add_fact(:process_link, [mod_str, callee])
  end

  defp handle_link(facts, _mod_str, _ctx, _mfa), do: facts

  # Resolve a timeout argument to its string representation for facts.
  # Positive integer → milliseconds, :infinity → "-1", anything else → "0" (dynamic).
end
