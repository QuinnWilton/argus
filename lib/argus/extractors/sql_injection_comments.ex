defmodule Argus.Extractors.SqlInjection.Comments do
  @moduledoc false

  alias Argus.Cfg.Function, as: CfgFunction
  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Extractors.SecurityValues
  alias Argus.Instr
  alias Argus.Instr.Reaching

  @doc "Body-derived parameter summaries for SQL comment validators."
  @spec validators(Argus.Extractor.module_data()) :: [{mfa(), non_neg_integer()}]
  def validators(data) do
    for {:function, name, arity, _, instrs} <- data.functions,
        candidates = candidates(instrs),
        candidates != [],
        cfg = Helpers.cfg(data, name, arity),
        cfg != nil,
        cfg = SecurityValues.proof_cfg(cfg, instrs),
        param <- candidates,
        validates?(cfg, instrs, param),
        do: {{data.module, name, arity}, param}
  end

  defp candidates(instrs) do
    for {instr, at} <- Enum.with_index(instrs),
        Helpers.match_remote_call(instr) in [{:ok, Keyword, :get, 2}, {:ok, Keyword, :get, 3}],
        Resolve.resolve_register(instrs, at, {:x, 1}) == {:ok, :comment},
        {:param, param} <- [identity(instrs, at, {:x, 0})],
        uniq: true,
        do: param
  end

  @doc "The options are checked on all paths before this exact persistence site."
  @spec safe_options?(
          Argus.Extractor.module_data(),
          mfa(),
          non_neg_integer(),
          term(),
          [{mfa(), non_neg_integer()}]
        ) :: boolean()
  def safe_options?(data, {_, name, arity}, use, operand, validators) do
    {:function, _, _, _, instrs} =
      Enum.find(data.functions, fn {:function, n, a, _, _} -> n == name and a == arity end)

    options = identity(instrs, use, operand)
    cfg = Helpers.cfg(data, name, arity)

    options != nil and cfg != nil and
      Enum.any?(CallSites.for_module(data), fn site ->
        same_function? = site.instrs == instrs

        same_function? and
          Enum.any?(validators, fn {mfa, pos} ->
            site.mfa == mfa and identity(instrs, site.idx, {:x, pos}) == options and
              dominates_use?(cfg, site.idx, use)
          end)
      end)
  end

  defp dominates_use?(cfg, at, use) do
    case {CfgFunction.block_at(cfg, at), CfgFunction.block_at(cfg, use)} do
      {%{id: same}, %{id: same}} -> at < use
      {%{id: before}, %{id: after_use}} -> CfgFunction.dominates?(cfg, before, after_use)
      _ -> false
    end
  end

  # Copies and supported keyword updates preserve the identity of the comment
  # option. Updating :comment itself breaks it, even if the same list was checked.
  defp identity(instrs, at, operand) do
    Resolve.trace(instrs, at, operand, nil, fn
      {:param, pos}, _ ->
        {:param, pos}

      {idx, instr}, follow ->
        case Helpers.match_remote_call(instr) do
          {:ok, Keyword, fun, arity} when fun in [:put, :put_new] and arity == 3 ->
            case Resolve.resolve_register(instrs, idx, {:x, 1}) do
              {:ok, key} when key != :comment -> follow.(idx, {:x, 0})
              _ -> nil
            end

          {:ok, Keyword, :get, arity} when arity in [2, 3] ->
            if Resolve.resolve_register(instrs, idx, {:x, 1}) == {:ok, :comment} do
              case follow.(idx, {:x, 0}) do
                nil -> nil
                parent -> {:comment, parent}
              end
            end

          _ ->
            nil
        end
    end)
  end

  defp validates?(cfg, instrs, param) do
    subject = {:comment, {:param, param}}
    walk(cfg, instrs, [{cfg.entry, false}], subject, %{}, false)
  end

  # Carry the proof through the CFG. Every reachable normal completion must
  # either have selected nil or rejected both forbidden sequences on that value.
  @spec walk(
          CfgFunction.t(),
          [term()],
          [{non_neg_integer(), boolean()}],
          term(),
          %{term() => true},
          boolean()
        ) ::
          boolean()
  defp walk(_cfg, _instrs, [], _subject, _seen, completed), do: completed

  defp walk(cfg, instrs, [{id, safe?} = state | rest], subject, seen, completed) do
    if Map.has_key?(seen, state) do
      walk(cfg, instrs, rest, subject, seen, completed)
    else
      block = Map.fetch!(cfg.blocks, id)
      {_, last} = block.range
      instr = Reaching.at(instrs, last)
      completes? = block.terminator == :return or (Instr.tail_call?(instr) and not raises?(instr))

      if completes? and not safe? do
        false
      else
        next =
          for {target, edge} <- block.succs do
            proven? = safe? or safe_edge?(instrs, last, instr, edge, subject)
            {target, proven?}
          end

        walk(
          cfg,
          instrs,
          next ++ rest,
          subject,
          Map.put(seen, state, true),
          completed or completes?
        )
      end
    end
  end

  defp raises?(instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, :erlang, fun, _} when fun in [:error, :exit, :throw] -> true
      _ -> false
    end
  end

  defp safe_edge?(instrs, at, {:test, op, _, [left, right]}, edge, subject)
       when op in [:is_eq_exact, :is_ne_exact] do
    {value, expected} =
      case literal(left) do
        {:ok, constant} -> {right, constant}
        :error -> {left, elem_or_nil(literal(right))}
      end

    equals? = {op, edge} in [{:is_eq_exact, :branch_pass}, {:is_ne_exact, :branch_fail}]
    excludes? = {op, edge} in [{:is_eq_exact, :branch_fail}, {:is_ne_exact, :branch_pass}]

    cond do
      expected == nil and equals? -> identity(instrs, at, value) == subject
      expected == false and equals? -> excludes_controls?(instrs, at, value, subject)
      expected == true and excludes? -> excludes_controls?(instrs, at, value, subject)
      true -> false
    end
  end

  defp safe_edge?(instrs, at, {:select_val, value, _, _}, {:select_arm, result}, subject)
       when result in ["false", ":false", "nil", ":nil"] do
    excludes_controls?(instrs, at, value, subject)
  end

  defp safe_edge?(_instrs, _at, _instr, _edge, _subject), do: false

  defp excludes_controls?(instrs, at, value, subject) do
    with {:ok, {String, :contains?, 2}, call} <- Resolve.call_result_origin(instrs, at, value),
         true <- identity(instrs, call, {:x, 0}) == subject,
         {:ok, patterns} <- Resolve.resolve_register(instrs, call, {:x, 1}) do
      patterns = List.wrap(patterns)
      <<0>> in patterns and "*/" in patterns
    else
      _ -> false
    end
  end

  defp literal({:atom, value}), do: {:ok, value}
  defp literal({:literal, value}), do: {:ok, value}
  defp literal(_), do: :error
  defp elem_or_nil({:ok, value}), do: value
  defp elem_or_nil(:error), do: :unknown
end
