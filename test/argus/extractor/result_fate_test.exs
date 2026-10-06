defmodule Argus.Extractor.ResultFateTest do
  @moduledoc """
  `ResultFate.lost?/2`: whether a call's answer is read on no path, in its
  function or, handed back, in the callers the module shows.
  """
  use ExUnit.Case, async: true

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.ResultFate
  alias Argus.Pipeline.Disassemble

  setup_all do
    [{_mod, bin}] =
      Code.compile_string("""
      defmodule Argus.ResultFateTest.Calls do
        def dropped(x) do
          _ = make(x)
          :ok
        end

        def matched(x) do
          {:ok, y} = make(x)
          y
        end

        def returned(x), do: make(x)

        def in_each(xs), do: Enum.each(xs, fn x -> make(x) end)
        def in_any(xs), do: Enum.any?(xs, fn x -> make(x) end)
        def in_map_returned(xs), do: Enum.map(xs, fn x -> make(x) end)

        def in_map_dropped(xs) do
          _ = Enum.map(xs, fn x -> make(x) end)
          :ok
        end

        def in_map_then_each(groups),
          do: Enum.each(groups, fn xs -> Enum.map(xs, fn x -> make(x) end) end)

        def through_helper_dropped(x) do
          _ = helper(x)
          :ok
        end

        def through_helper_used(x), do: elem(helper(x), 1)

        defp helper(x), do: make(x)

        def consed_dropped(xs) do
          _ = Enum.reduce(xs, [], fn x, acc -> [make(x) | acc] end)
          :ok
        end

        def consed_reversed_dropped(xs) do
          _ = xs |> Enum.reduce([], fn x, acc -> [make(x) | acc] end) |> :lists.reverse()
          :ok
        end

        def consed_returned(xs), do: Enum.reduce(xs, [], fn x, acc -> [make(x) | acc] end)

        def wrapped_dropped(x) do
          _ = wrap(x)
          :ok
        end

        def wrapped_tested(x) do
          case make(x) do
            {:ok, y} -> y
            _ -> nil
          end
        end

        defp wrap(x), do: {:wrapped, make(x)}

        defp make(x), do: {:ok, x}
      end
      """)

    {:ok, data} = Disassemble.disassemble_path(bin)
    %{data: data}
  end

  # The fate of each call to make/1, by the function making it.
  defp fates(data) do
    for %{mfa: {_, :make, 1}} = site <- CallSites.for_module(data), into: %{} do
      name = site.func_id |> String.split(":", parts: 2) |> List.last()
      {name, ResultFate.lost?(data, site)}
    end
  end

  test "a call's answer read on no path is lost; one matched or handed out is not", %{data: data} do
    fates = fates(data)

    assert fates["dropped/1"]
    refute fates["matched/1"]
    # An exported function's callers are outside the module.
    refute fates["returned/1"]
  end

  test "a closure's answer is lost to a call dropping it, or keeping it in a list dropped",
       %{data: data} do
    fates = fates(data)

    assert fates["-in_each/1-fun-0-/1"]
    assert fates["-in_any/1-fun-0-/1"]
    assert fates["-in_map_dropped/1-fun-0-/1"]
    assert fates["-in_map_then_each/1-fun-0-/1"]
    refute fates["-in_map_returned/1-fun-0-/1"]
  end

  test "a helper's answer is lost when one of its callers drops it", %{data: data} do
    # helper/1's one caller that drops it is enough: a lost answer per call.
    assert fates(data)["helper/1"]
  end

  test "an answer built into a term is followed into what holds it", %{data: data} do
    fates = fates(data)

    # Consed onto a fold's accumulator: the fold keeps it, its caller
    # drops (or reverses, then drops) the list.
    assert fates["-consed_dropped/1-fun-0-/2"]
    assert fates["-consed_reversed_dropped/1-fun-0-/2"]
    refute fates["-consed_returned/1-fun-0-/2"]

    # Wrapped in a tuple a helper hands back, dropped by its caller.
    assert fates["wrap/1"]

    # A test reads it.
    refute fates["wrapped_tested/1"]
  end
end
