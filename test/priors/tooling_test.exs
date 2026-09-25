defmodule Argus.Priors.Questions.ToolingTest do
  use ExUnit.Case, async: true

  alias Argus.Priors.Questions.Tooling
  alias Argus.Test.Fixtures.DerivedInspect.OneField
  alias Argus.Test.Fixtures.Tooling.{DevSetup, Product}

  @mods [
    Mix.ArgusFixtures.Seed,
    Product,
    DevSetup,
    OneField,
    Inspect.Argus.Test.Fixtures.DerivedInspect.OneField
  ]

  defp facts(mods) do
    {:ok, facts} =
      Argus.Pipeline.extract(mods,
        format: :typed,
        extractors: [Argus.Extractors.OTP, Argus.Extractors.Tooling]
      )

    facts
  end

  defp subjects, do: @mods |> facts() |> Tooling.subjects()

  test "every module the structure leaves undecided is asked, one per request" do
    ids = Enum.map(subjects(), & &1.id)

    assert inspect(Product) in ids
    assert inspect(DevSetup) in ids
    # The structure named it: not asked.
    refute "Mix.ArgusFixtures.Seed" in ids
    # A protocol's implementation is the struct's.
    refute inspect(Inspect.Argus.Test.Fixtures.DerivedInspect.OneField) in ids

    for s <- subjects(), do: assert(s.batch_key == s.id)
  end

  test "a module with no exported function of its own is left as the product" do
    [{mod, beam}] =
      Code.compile_string("defmodule Argus.ToolingQTest.Bare do\n defstruct [:a]\nend")

    ids = [beam] |> facts() |> Tooling.subjects() |> Enum.map(& &1.id)
    refute inspect(mod) in ids
  end

  test "the state is names: the module, its functions, what it calls and who calls it" do
    s = Enum.find(subjects(), &(&1.id == inspect(DevSetup)))

    assert s.state.module == inspect(DevSetup)
    assert s.state.functions == ["run/1"]
    assert "String" not in s.state.calls
    assert ":os" in s.state.calls
    assert s.state.called_by == []
    assert Tooling.state([s]) == %{modules: [s.state]}

    for s <- subjects(), {_k, v} <- s.state, x <- List.wrap(v), is_binary(x) do
      refute x =~ ~r/#\d+$/, "an instruction id leaked into the state: #{x}"
    end
  end

  test "who calls a module is read from the other modules' calls" do
    [{_, caller}] =
      Code.compile_string(
        "defmodule Argus.ToolingQTest.Caller do\n def go, do: #{inspect(DevSetup)}.run(\"ls\")\nend"
      )

    s =
      [DevSetup, caller]
      |> facts()
      |> Tooling.subjects()
      |> Enum.find(&(&1.id == inspect(DevSetup)))

    assert s.state.called_by == ["Argus.ToolingQTest.Caller"]
  end

  test "one choice per module: product, a developer's tool or test support" do
    [s | _] = subjects()
    q = Tooling.questions([s])
    assert Map.keys(q) == ["kind__0"]
    assert q["kind__0"].instructions =~ "What is the module `#{s.id}`"
    assert Map.keys(q["kind__0"].criteria) |> Enum.sort() == ~w(development product test)a
  end

  test "rows carry the likeliest kind and the mass of development and test" do
    [s | _] = subjects()

    answer = %{
      "choice" => "development",
      "probabilities" => %{"development" => 0.6, "test" => 0.3, "product" => 0.1}
    }

    assert [[mod, "development", "600", "900"]] = Tooling.rows([s], %{"kind__0" => answer})
    assert mod == s.id

    assert Tooling.rows([s], %{"kind__0" => %{"choice" => "x", "probabilities" => %{}}}) == []
    assert Tooling.rows([s], %{}) == []
  end
end
