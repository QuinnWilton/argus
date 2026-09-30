defmodule Argus.CfgWalkTest do
  use ExUnit.Case, async: true

  alias Argus.Cfg
  alias Argus.Cfg.Walk

  defp returned?(body, stop? \\ fn _ -> false end) do
    instrs = [
      {:label, 1},
      {:func_info, {:atom, __MODULE__}, {:atom, :sample}, 1},
      {:label, 2} | body
    ]

    data = %{module: __MODULE__, functions: [{:function, :sample, 1, 2, instrs}]}
    fun = Cfg.build_for(data, :sample, 1)
    Walk.carries_to_return?(fun, instrs, 3, {:x, 0}, stop?)
  end

  test "a saved copy survives a call, while the original x register does not" do
    call = {:call_ext, 0, {:extfunc, System, :monotonic_time, 0}}
    assert returned?([{:move, {:x, 0}, {:y, 0}}, call, {:move, {:y, 0}, {:x, 0}}, :return])
    refute returned?([call, :return])
  end

  test "an unblocked branch returning something else cannot vouch for the value" do
    body = [
      {:move, {:x, 0}, {:y, 0}},
      {:test, :is_atom, {:f, 3}, [{:x, 2}]},
      {:move, {:x, 1}, {:x, 0}},
      {:move, {:y, 0}, {:x, 0}},
      {:jump, {:f, 4}},
      {:label, 3},
      {:move, {:atom, :other}, {:x, 0}},
      {:label, 4},
      :return
    ]

    stop? = &match?({:move, {:x, 1}, _}, &1)
    assert returned?(body)
    refute returned?(body, stop?)
    assert returned?(List.replace_at(body, 6, {:move, {:y, 0}, {:x, 0}}), stop?)
  end

  test "loops terminate and preserve distinct copies" do
    assert returned?([
             {:move, {:x, 0}, {:y, 0}},
             {:label, 3},
             {:test, :is_atom, {:f, 4}, [{:x, 2}]},
             {:swap, {:x, 0}, {:y, 0}},
             {:jump, {:f, 3}},
             {:label, 4},
             {:move, {:y, 0}, {:x, 0}},
             :return
           ])

    refute returned?([{:label, 3}, {:jump, {:f, 3}}])
  end
end
