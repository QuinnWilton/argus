defmodule Argus.PriorsTest do
  @moduledoc """
  Priors end to end: the pipeline writes the relation, the rule reads it,
  and a run without priors is the run it always was.
  """

  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Fixtures.Secret, as: S

  @moduletag :tmp_dir

  @mods [S.Exposed, S.PartlyRedacted, S.Redacted, S.Ordinary, S.Heuristic]

  # Names `totp_seed` a credential at 0.95 and everything else `none`.
  defmodule Oracle do
    @behaviour Argus.Priors.Oracle

    @impl true
    def ask(request, opts) do
      answers =
        for {id, %{type: "choice", instructions: text}} <- request.questions, into: %{} do
          {detail, p} =
            if text =~ "`totp_seed`",
              do: {"credential", Keyword.get(opts, :p, 0.95)},
              else: {"none", 0.98}

          {id,
           %{
             "type" => "choice",
             "choice" => detail,
             "confidence" => p,
             "probabilities" => %{detail => p}
           }}
        end

      {:ok,
       %{answers: answers, usage: %{"input_tokens" => 50}, model: request.model, request_id: nil}}
    end
  end

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp run(opts) do
    assert {:ok, %Argus.Findings{degraded: []} = r} =
             Argus.Findings.run(@mods, Keyword.put(opts, :analyses, [:exposure]))

    Enum.filter(r.findings, &(&1.title =~ "printed by inspect"))
  end

  defp priors(dir, extra \\ []),
    do: [
      priors: :live,
      priors_opts: Keyword.merge([oracle: Oracle, cache_dir: dir, model: "jev-test"], extra)
    ]

  test "off by default: the heuristic relation stays empty and the findings are the structural ones" do
    skip_without_souffle()
    findings = run([])

    assert findings |> Enum.map(& &1.module) |> Enum.sort() ==
             Enum.sort([S.Exposed, S.Exposed, S.PartlyRedacted])

    assert Enum.all?(findings, &(&1.provenance == :structural and is_nil(&1.confidence)))
  end

  test "with priors, the model's secret is a heuristic finding a step down in severity", %{
    tmp_dir: dir
  } do
    skip_without_souffle()
    findings = run(priors(dir))

    assert [heuristic] = Enum.filter(findings, &(&1.provenance == :heuristic))
    assert heuristic.title == "#{inspect(S.Heuristic)}.:totp_seed is printed by inspect/1"
    assert heuristic.severity == :warning
    assert heuristic.confidence == 950
    assert heuristic.at_label =~ "heuristic"
    assert heuristic.at_label =~ "p=0.95"
    assert heuristic.analysis == :exposure
  end

  test "priors add and never remove: findings with priors are a superset", %{tmp_dir: dir} do
    skip_without_souffle()
    without = run([]) |> Enum.map(&{&1.title, &1.mfa}) |> MapSet.new()
    with_priors = run(priors(dir)) |> Enum.map(&{&1.title, &1.mfa}) |> MapSet.new()
    assert MapSet.subset?(without, with_priors)
  end

  test "below the threshold the model's answer changes nothing", %{tmp_dir: dir} do
    skip_without_souffle()
    findings = run(priors(dir, oracle_opts: [p: 0.85]))
    refute Enum.any?(findings, &(&1.provenance == :heuristic))
  end

  test "a field the table names is the table's, whatever the model says", %{tmp_dir: dir} do
    skip_without_souffle()
    findings = run(priors(dir))
    structural = Enum.filter(findings, &(&1.provenance == :structural))
    assert length(structural) == 3
  end

  test "cached_only reads the cache the live run filled and needs no oracle", %{tmp_dir: dir} do
    skip_without_souffle()
    live = run(priors(dir))

    cached =
      run(
        priors: :cached_only,
        priors_opts: [cache_dir: dir, model: "jev-test", oracle: Argus.PriorsTest.NoOracle]
      )

    assert Enum.sort(live) == Enum.sort(cached)
  end

  test "cached_only with an empty cache is the run without priors", %{tmp_dir: dir} do
    skip_without_souffle()

    assert run(
             priors: :cached_only,
             priors_opts: [cache_dir: Path.join(dir, "empty"), model: "jev-test"]
           ) == run([])
  end

  test "live without a key fails before extracting" do
    key = System.get_env("TYPESAFE_API_KEY")
    System.delete_env("TYPESAFE_API_KEY")

    try do
      assert_raise ArgumentError, ~r/TYPESAFE_API_KEY/, fn ->
        Argus.Findings.run(@mods, analyses: [:exposure], priors: :live)
      end
    after
      if key, do: System.put_env("TYPESAFE_API_KEY", key)
    end
  end

  test "an unknown mode is refused" do
    assert_raise ArgumentError, ~r/:cached_only or :live/, fn ->
      Argus.Findings.run(@mods, analyses: [:exposure], priors: :sometimes)
    end
  end

  defmodule NoOracle do
    @behaviour Argus.Priors.Oracle
    @impl true
    def ask(_request, _opts), do: raise("the oracle was asked in cached_only mode")
  end
end
