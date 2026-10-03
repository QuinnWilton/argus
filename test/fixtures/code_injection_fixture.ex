defmodule Argus.Test.Fixtures.CodeInjection do
  @moduledoc false

  def callback_template(fun, input), do: EEx.eval_string(fun.(input), [])
  def callback_bindings(fun, input), do: EEx.eval_string("<%= value %>", value: fun.(input))
  def literal_template(input), do: EEx.eval_string("<%= value %>", value: input)
  def dynamic_template(input), do: EEx.eval_string(input, [])
  def compiled_template(input), do: EEx.compile_string(input)
  def constant_callback(input), do: EEx.eval_string((fn _ -> "literal" end).(input), [])
  def opaque_external(input), do: EEx.eval_string(unknown_external(input), [])
  defp unknown_external(input), do: :persistent_term.get(input)

  def unsafe_helper(fun, input), do: normalize(fun.(input), input, true)
  def safe_helper(fun, input), do: normalize(fun.(input), input, false)

  def guarded_false(fun, input, flag) when flag == false,
    do: normalize(fun.(input), input, flag)

  def wrong_value_gate(fun, input, flag) when flag == false,
    do: normalize(fun.(input), input, true)

  def mixed_helper(fun, input, enabled), do: normalize(fun.(input), input, enabled)
  def wrong_flag(fun, input, false), do: normalize(fun.(input), input, true)
  def wrong_flag(fun, input, true), do: normalize(fun.(input), input, false)

  defp normalize(content, input, evaluate?) do
    evaluate(content, input, evaluate?)
  end

  defp evaluate(content, _input, false), do: content
  defp evaluate(content, input, true), do: EEx.eval_string(content, value: input)

  def partially_checked(fun, input, safe?) do
    value = fun.(input)
    if safe?, do: normalize(value, input, false), else: normalize(value, input, true)
  end

  def discarded_callback(fun, input) do
    fun.(input)
    EEx.eval_string("literal", [])
  end

  def tuple_content(fun, input) do
    {system, _user} = fun.(input)
    EEx.eval_string(system, value: input)
  end

  def callback_return(fun, input), do: EEx.eval_string(callback_result(fun, input), [])
  defp callback_result(fun, input), do: fun.(input)

  def returned_via_mapping(fun, input) do
    content = fun.(input)
    Enum.map([content], fn value -> value end) |> Enum.join() |> EEx.eval_string([])
  end
end
