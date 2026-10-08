defmodule Argus.Analysis.SetsTest do
  use ExUnit.Case, async: true

  alias Argus.Analysis.Catalog
  alias Argus.Analysis.Sets

  doctest Argus.Analysis.Sets

  test "a set resolves to its analyses' modules, in the set's order" do
    {:ok, names} = Sets.set(:default)
    assert {:ok, mods} = Sets.resolve(:default)
    assert Enum.map(mods, & &1.name()) == names
  end

  test "every concern but coverage is in :all, and every analysis is a concern" do
    {:ok, all} = Sets.set(:all)
    assert Enum.sort(all ++ [:coverage]) == Enum.sort(Sets.concerns())
    assert Enum.sort(Catalog.names()) == Enum.sort(Sets.concerns())
  end

  test "the races concern is in the default set" do
    assert {:ok, default} = Sets.set(:default)
    assert :races in default
  end

  test "a name asked for twice is resolved once, where it was first asked" do
    assert {:ok, mods} = Sets.resolve([:unsafe_input, :exposure, :unsafe_input])
    assert Enum.map(mods, & &1.name()) == [:unsafe_input, :exposure]
  end

  test "a selection that is neither a set nor a list is invalid" do
    assert {:error, {:invalid_analyses, "startup"}} = Sets.resolve("startup")
    assert {:error, {:unknown_analysis, :nope}} = Sets.resolve([:startup, :nope])
  end
end
