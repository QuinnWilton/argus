defmodule Argus.Test.Fixtures.ParamFlow.Returns do
  @moduledoc false

  def local(params), do: params |> extract_name() |> String.to_atom()
  defp extract_name(params), do: trim_name(params["name"])
  defp trim_name(value), do: String.trim(value)

  def remote_self(value), do: value |> __MODULE__.trim_exported() |> String.to_atom()
  def trim_exported(value), do: String.trim(value)

  def ignored(value), do: value |> constant() |> String.to_atom()
  def constant(_value), do: "fixed"

  def selected(first, second), do: select(second, first) |> String.to_atom()
  def select(first, _second), do: first

  def sites(value) do
    a = select("fixed", value)
    b = select(value, "fixed")
    {String.to_atom(a), String.to_atom(b)}
  end

  def recursive(value, times), do: peel(value, times) |> String.to_atom()
  defp peel(value, 0), do: value
  defp peel(value, n), do: peel_again(String.trim(value), n - 1)
  defp peel_again(value, n), do: peel(value, n)

  def lookup(value), do: value |> stored() |> String.to_atom()
  defp stored(value), do: Process.get(value)

  def mapped(values), do: values |> Enum.map(&trim_name/1) |> Enum.join() |> String.to_atom()

  def external_map(values),
    do: values |> Enum.map(&String.trim/1) |> Enum.join() |> String.to_atom()

  def external_unknown(values),
    do: values |> Enum.map(&Process.get/1) |> Enum.join() |> String.to_atom()

  def constant_map(values),
    do: values |> Enum.map(fn _ -> "fixed" end) |> Enum.join() |> String.to_atom()

  def unknown_map(values, fun), do: values |> Enum.map(fun) |> Enum.join() |> String.to_atom()

  def captured_return(prefix, values),
    do: values |> Enum.map(fn _ -> prefix end) |> Enum.join() |> String.to_atom()

  def combined_return(prefix, values),
    do: values |> Enum.map(fn value -> prefix <> value end) |> Enum.join() |> String.to_atom()

  def selected_capture(first, second, values) do
    values
    |> Enum.map(fn _ -> select(second, first) end)
    |> Enum.join()
    |> String.to_atom()
  end

  def captured_sites(first, second, values) do
    one = Enum.map(values, fn _ -> first end)
    two = Enum.map(values, fn _ -> second end)
    {String.to_atom(Enum.join(one)), String.to_atom(Enum.join(two))}
  end

  def reduced(values, initial),
    do: values |> Enum.reduce(initial, fn value, acc -> acc <> value end) |> String.to_atom()

  def constant_reduce(values),
    do: values |> Enum.reduce("fixed", fn _value, _acc -> "fixed" end) |> String.to_atom()

  def map_join(values, separator),
    do: Enum.map_join(values, separator, fn _ -> "fixed" end) |> String.to_atom()

  def erlang_map(values),
    do: :lists.map(fn value -> trim_name(value) end, values) |> Enum.join() |> String.to_atom()

  def unknown_local_helper(value), do: value |> unknown_return() |> String.to_atom()
  defp unknown_return(value), do: Argus.Test.Fixtures.ParamFlow.Store.load(value)

  def chosen(value), do: value |> choose_existing() |> Atom.to_string() |> String.to_atom()
  defp choose_existing(value), do: String.to_existing_atom(value)
end
