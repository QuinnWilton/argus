defmodule Argus.Analyses.ToolingTest do
  @moduledoc """
  A finding in code only developers' tools or tests run steps down a
  level, and nothing else moves (clientlib/tooling.dl,
  `Argus.Findings.Tooling`): three modules make the same call, and only
  the one the structure or the prior names as tooling reports it lower.
  """

  use ExUnit.Case, async: true

  alias Argus.Findings
  alias Argus.Test.Fixtures.Tooling.{DevSetup, Product}
  alias Argus.Test.Memo

  @moduletag :tmp_dir
  @moduletag :capture_log

  @mods [Mix.ArgusFixtures.Seed, Product, DevSetup]

  # Calls DevSetup a development tool at `:p` (0.95 by default) and every
  # other module the product; answers nothing else.
  defmodule Oracle do
    @behaviour Argus.Priors.Oracle

    @impl true
    def ask(request, opts) do
      answers =
        for {id, %{type: "choice", instructions: text}} <- request.questions,
            text =~ "What is the module",
            into: %{} do
          {kind, p} =
            if text =~ "`#{inspect(DevSetup)}`",
              do: {"development", Keyword.get(opts, :p, 0.95)},
              else: {"product", 0.99}

          {id,
           %{
             "type" => "choice",
             "choice" => kind,
             "confidence" => p,
             "probabilities" => %{kind => p, "product" => 1 - p}
           }}
        end

      {:ok,
       %{answers: answers, usage: %{"input_tokens" => 50}, model: request.model, request_id: nil}}
    end
  end

  defp skip_without_souffle do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")
  end

  # Code execution each module's export reaches, by module.
  defp findings(opts) do
    opts = Keyword.put(opts, :analyses, [:unsafe_input])

    assert {:ok, %Findings{degraded: []} = r} = Findings.run(@mods, opts)

    r.findings
    |> Enum.filter(&(&1.title =~ "Dynamic code execution"))
    |> Map.new(&{&1.module, &1})
  end

  defp priors(dir, extra \\ []),
    do: [
      priors: :live,
      priors_opts:
        Keyword.merge(
          [
            oracle: Oracle,
            cache_dir: dir,
            model: "jev-test",
            questions: [Argus.Priors.Questions.Tooling]
          ],
          extra
        )
    ]

  test "a module under Mix. steps down, structurally; the product and the undecided do not" do
    skip_without_souffle()
    by_module = findings([])

    assert %{severity: :warning, provenance: :structural, confidence: nil} =
             seed =
             by_module[Mix.ArgusFixtures.Seed]

    assert List.last(seed.help) =~ "tooling: a Mix task"

    # The positive twins: the same call, at its structural severity.
    for mod <- [Product, DevSetup] do
      assert %{severity: :error, provenance: :structural} = by_module[mod]
      refute Enum.any?(by_module[mod].help, &(&1 =~ "tooling"))
    end
  end

  test "the tooling prior at 0.9 or more steps its module down, heuristic", %{tmp_dir: dir} do
    skip_without_souffle()
    by_module = findings(priors(dir))

    assert %{severity: :warning, provenance: :heuristic, confidence: 950} =
             dev =
             by_module[DevSetup]

    assert List.last(dev.help) =~ "developer's tool or test support"
    assert List.last(dev.help) =~ "p=0.95"

    # The product the model calls the product, and the Mix module the
    # structure already named, are as they were without priors.
    assert %{severity: :error, provenance: :structural} = by_module[Product]
    assert %{severity: :warning, provenance: :structural} = by_module[Mix.ArgusFixtures.Seed]
  end

  test "below 0.9 the prior moves nothing", %{tmp_dir: dir} do
    skip_without_souffle()
    by_module = findings(priors(dir, oracle_opts: [p: 0.85]))
    assert %{severity: :error, provenance: :structural} = by_module[DevSetup]
  end

  test "priors re-tier and never remove: the same findings, by title and anchor", %{
    tmp_dir: dir
  } do
    skip_without_souffle()
    key = fn m -> m |> Map.values() |> Enum.map(&{&1.title, &1.mfa, &1.instr}) |> Enum.sort() end
    assert key.(findings([])) == key.(findings(priors(dir)))
  end

  describe "the tooling rows" do
    defp tooling_rows(facts) do
      assert {:ok, results} = Memo.run_rules(facts, :structure)
      Enum.sort(results["tooling"] || [])
    end

    @base %{
      function_def: [
        ["Mix.Tasks.Seed:run/1", "Mix.Tasks.Seed", "run", "1", "1"],
        ["App.DevSetup:run/0", "App.DevSetup", "run", "0", "1"],
        ["App.Worker:run/0", "App.Worker", "run", "0", "1"]
      ],
      tooling_module: [["Mix.Tasks.Seed", "mix"]]
    }

    test "a structural row is the structure's at 1000; without a prior nothing else" do
      skip_without_souffle()
      assert tooling_rows(@base) == [["Mix.Tasks.Seed", "mix", "1000"]]
    end

    test "the prior names a module at 0.9 or more, never one the structure named" do
      skip_without_souffle()

      facts =
        Map.put(@base, :prior_tooling, [
          ["App.DevSetup", "development", "930", "940"],
          ["App.Worker", "test", "600", "850"],
          ["Mix.Tasks.Seed", "development", "990", "990"]
        ])

      assert tooling_rows(facts) == [
               ["App.DevSetup", "prior", "940"],
               ["Mix.Tasks.Seed", "mix", "1000"]
             ]
    end
  end
end
