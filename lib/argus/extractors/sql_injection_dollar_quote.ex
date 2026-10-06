defmodule Argus.Extractors.SqlInjection.DollarQuote do
  @moduledoc false

  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Instr

  @doc "The body parameter enclosed in a proven fresh, syntactically valid dollar delimiter."
  @spec parameter(mfa(), %{mfa() => [Instr.instr()]}) :: non_neg_integer() | nil
  def parameter(mfa, functions) do
    instrs = Map.fetch!(functions, mfa)
    returns = for {instr, at} <- Enum.with_index(instrs), instr == :return, do: at

    if returns != [] and not Enum.any?(instrs, &Instr.tail_call?/1) do
      agree(returns, &wrapper(instrs, &1, functions))
    end
  end

  defp wrapper(instrs, at, functions) do
    Resolve.trace(instrs, at, {:x, 0}, nil, fn
      {built, {:bs_create_bin, _, _, _, _, _, {:list, segments}}}, _ ->
        case operands(segments) do
          [left, body, right] -> selected_wrapper(instrs, built, left, body, right, functions)
          _ -> nil
        end

      _, _ ->
        nil
    end)
  end

  defp selected_wrapper(instrs, at, left, body, right, functions) do
    with {:ok, {Enum, :find, 2}, find} <- Resolve.call_result_origin(instrs, at, left),
         {:ok, {Enum, :find, 2}, ^find} <- Resolve.call_result_origin(instrs, at, right),
         {:ok, param} <- Resolve.arg_position(instrs, at, body),
         true <- excludes_body?(instrs, find, param, functions),
         true <- delimiter_stream?(instrs, find, functions) do
      param
    else
      _ -> nil
    end
  end

  defp excludes_body?(instrs, at, param, functions) do
    Resolve.trace(instrs, at, {:x, 1}, false, fn
      {made, {:make_fun3, {_, _, 2} = target, _, _, _, {:list, [capture]}}}, _ ->
        Resolve.arg_position(instrs, made, capture) == {:ok, param} and
          predicate?(Map.get(functions, target, []))

      _, _ ->
        false
    end)
  end

  defp predicate?(instrs) do
    every_return?(instrs, fn at ->
      Resolve.trace(instrs, at, {:x, 0}, false, fn
        {negation, {:bif, :not, _, [result], _}}, _ ->
          with {:ok, {String, :contains?, 2}, call} <-
                 Resolve.call_result_origin(instrs, negation, result) do
            Resolve.arg_position(instrs, call, {:x, 0}) == {:ok, 1} and
              Resolve.arg_position(instrs, call, {:x, 1}) == {:ok, 0}
          else
            _ -> false
          end

        _, _ ->
          false
      end)
    end)
  end

  defp delimiter_stream?(instrs, find, functions) do
    with {:ok, {Stream, :map, 2}, map} <- Resolve.call_result_origin(instrs, find, {:x, 0}),
         mapper when mapper != nil <- Resolve.fun_target(instrs, map, {:x, 1}),
         true <- tag_template?(Map.get(functions, mapper, [])),
         {:ok, {Stream, :iterate, 2}, iterate} <-
           Resolve.call_result_origin(instrs, map, {:x, 0}),
         {:ok, initial} when is_integer(initial) and initial >= 0 <-
           Resolve.resolve_register(instrs, iterate, {:x, 0}),
         successor when successor != nil <- Resolve.fun_target(instrs, iterate, {:x, 1}) do
      increment?(Map.get(functions, successor, []))
    else
      _ -> false
    end
  end

  defp increment?(instrs) do
    every_return?(instrs, fn at ->
      Resolve.trace(instrs, at, {:x, 0}, false, fn
        {sum, {:gc_bif, :+, _, _, [value, {:integer, step}], _}}, _ when step > 0 ->
          Resolve.arg_position(instrs, sum, value) == {:ok, 0}

        {sum, {:bif, :+, _, [value, {:integer, step}], _}}, _ when step > 0 ->
          Resolve.arg_position(instrs, sum, value) == {:ok, 0}

        _, _ ->
          false
      end)
    end)
  end

  defp tag_template?(instrs) do
    every_return?(instrs, fn at ->
      Resolve.trace(instrs, at, {:x, 0}, false, fn
        {built, {:bs_create_bin, _, _, _, _, _, {:list, segments}}}, _ ->
          case operands(segments) do
            [{:string, prefix}, number, {:string, "$"}] ->
              is_binary(prefix) and Regex.match?(~r/^\$[A-Za-z_][A-Za-z_0-9]*$/, prefix) and
                decimal_counter?(instrs, built, number)

            _ ->
              false
          end

        _, _ ->
          false
      end)
    end)
  end

  defp decimal_counter?(instrs, at, value) do
    Resolve.trace(instrs, at, value, false, fn
      {:param, 0}, _ ->
        true

      {converted, instr}, _ ->
        Helpers.match_remote_call(instr) in [
          {:ok, String.Chars, :to_string, 1},
          {:ok, :erlang, :integer_to_binary, 1}
        ] and Resolve.arg_position(instrs, converted, {:x, 0}) == {:ok, 0}

      _, _ ->
        false
    end)
  end

  defp every_return?(instrs, prove) do
    returns = for {instr, at} <- Enum.with_index(instrs), instr == :return, do: at
    returns != [] and not Enum.any?(instrs, &Instr.tail_call?/1) and Enum.all?(returns, prove)
  end

  defp operands(segments) do
    operands = segments |> Enum.chunk_every(6) |> Enum.map(&full_operand/1)
    if Enum.any?(operands, &is_nil/1), do: [], else: operands
  end

  # The exclusion predicate tests the complete delimiter and body. Truncation,
  # non-byte units, or encoding an integer as raw bits changes those bytes and
  # cannot inherit that proof.
  defp full_operand([{:atom, kind}, _, 8, _, value, {:atom, :all}])
       when kind in [:binary, :append, :private_append],
       do: Instr.register(value)

  defp full_operand([{:atom, :string}, _, 8, _, {:string, bytes}, {:integer, size}])
       when is_binary(bytes) and byte_size(bytes) == size,
       do: {:string, bytes}

  defp full_operand(_segment), do: nil

  defp agree([first | rest], fun) do
    value = fun.(first)
    if value != nil and Enum.all?(rest, &(fun.(&1) == value)), do: value
  end
end
