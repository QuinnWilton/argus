defmodule Argus.Extractor.DispatchTest do
  @moduledoc """
  Where a function's `func_info` label is, however `beam_disasm` lays
  the function's start out: OTP 29's as the compiler does (`label, line,
  func_info`), OTP 28's so for a module's first function only and `line,
  label, func_info` for every other. Read as the instruction just before
  `func_info`, every function on OTP 29, and a module's first on OTP 28,
  had no clause-failure label: none was total, and none could fail a
  clause head.
  """

  use ExUnit.Case, async: true

  alias Argus.Extractor.Dispatch
  alias Argus.Pipeline.Disassemble

  @body [{:label, 2}, {:test, :is_pid, {:f, 1}, [x: 0]}, :return]
  @func_info {:func_info, {:atom, :m}, {:atom, :f}, 1}

  test "the label is found past the line marker, in every layout" do
    for prefix <- [
          [{:label, 1}, {:line, [{:location, ~c"m.erl", 3}]}],
          [{:label, 1}, {:line, []}],
          [{:label, 1}, {:line, 1}],
          [{:line, 1}, {:label, 1}],
          [{:label, 1}]
        ] do
      assert Dispatch.func_info_label(prefix ++ [@func_info | @body]) == 1, inspect(prefix)
    end

    assert Dispatch.func_info_label([{:line, 1}, @func_info | @body]) == nil
    assert Dispatch.func_info_label(@body) == nil
  end

  test "a module's first function reads as its others do" do
    source = ~c"""
    -module(dispatch_first_probe).
    -export([first/1, second/1, guarded/1]).
    first(_) -> ok.
    second(_) -> ok.
    guarded(X) when is_pid(X) -> ok.
    """

    {:ok, tokens, _} = :erl_scan.string(source)

    forms =
      tokens
      |> Enum.chunk_while([], &chunk_form/2, &{:cont, Enum.reverse(&1), []})
      |> Enum.reject(&(&1 == []))
      |> Enum.map(fn form_tokens ->
        {:ok, form} = :erl_parse.parse_form(form_tokens)
        form
      end)

    {:ok, _, bin} = :compile.forms(forms, [:binary])
    {:ok, %{functions: functions}} = Disassemble.disassemble_path(bin)
    code = Map.new(functions, fn {:function, name, _, _, code} -> {name, code} end)

    assert Dispatch.total?(code.first)
    assert Dispatch.total?(code.second)
    refute Dispatch.total?(code.guarded)
  end

  defp chunk_form({:dot, _} = dot, acc), do: {:cont, Enum.reverse([dot | acc]), []}
  defp chunk_form(token, acc), do: {:cont, [token | acc]}
end
