defmodule Argus.Extractor.ShapesTest do
  use ExUnit.Case, async: true

  alias Argus.Extractor.Shapes

  @elements [{:atom, :reply}, {:x, 0}, {:atom, :state}]

  test "a tuple overwritten before the return is not a return shape" do
    assert Shapes.return_shapes([
             {:put_tuple2, {:x, 1}, {:list, @elements}},
             {:move, {:x, 1}, {:x, 0}},
             {:move, {:atom, :ok}, {:x, 0}},
             :return
           ]) == []
  end

  test "an overwritten tuple register does not carry the tuple to the return" do
    assert Shapes.return_shapes([
             {:put_tuple2, {:x, 1}, {:list, @elements}},
             {:move, {:atom, :ok}, {:x, 1}},
             {:move, {:x, 1}, {:x, 0}},
             :return
           ]) == []
  end

  test "a tuple passed to a raising call is not returned" do
    assert Shapes.return_shapes([
             {:put_tuple2, {:x, 1}, {:list, @elements}},
             {:move, {:x, 1}, {:x, 0}},
             {:call_ext_only, 1, {:extfunc, :erlang, :error, 1}}
           ]) == []
  end

  test "copies and jumps can carry a tuple to the return" do
    instrs = [
      {:put_tuple2, {:x, 1}, {:list, @elements}},
      {:move, {:x, 1}, {:y, 0}},
      {:jump, {:f, 2}},
      {:label, 1},
      {:move, {:atom, :unreachable}, {:y, 0}},
      {:label, 2},
      {:move, {:y, 0}, {:x, 0}},
      :return
    ]

    assert Shapes.return_shapes(instrs) == [{0, @elements}]
  end

  test "a join retains the tuples returned by both branches" do
    instrs = [
      {:test, :is_atom, {:f, 2}, [{:x, 0}]},
      {:put_tuple2, {:x, 0}, {:list, @elements}},
      {:jump, {:f, 3}},
      {:label, 2},
      {:move, {:literal, {:noreply, :state}}, {:x, 0}},
      {:label, 3},
      :return
    ]

    assert Shapes.return_shapes(instrs) == [
             {1, @elements},
             {4, [{:atom, :noreply}, {:atom, :state}]}
           ]
  end

  test "legacy put_tuple/put instructions retain their immediate return shape" do
    assert Shapes.return_shapes([
             {:put_tuple, 2, {:x, 0}},
             {:put, {:atom, :ok}},
             {:put, {:x, 1}},
             {:deallocate, 1},
             :return
           ]) == [{0, [{:atom, :ok}, {:x, 1}]}]
  end
end
