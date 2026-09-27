defmodule Argus.RunTest do
  use ExUnit.Case, async: true

  doctest Argus.Run

  test "an unknown backend is an argument error naming it" do
    assert_raise ArgumentError, ~r/:nope/, fn -> Argus.Run.backend(backend: :nope) end
  end

  test "an option only the batch backend reads picks it, unless a backend is named" do
    for option <- [:facts_dir, :cache, :solve_cache, :extractors, :relations] do
      assert {:batch, _} = Argus.Run.backend([{option, :x}])
      assert {:graph, [{^option, :x}]} = Argus.Run.backend([{option, :x}, backend: :graph])
    end
  end
end
