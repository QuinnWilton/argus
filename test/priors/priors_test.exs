defmodule Argus.PriorsTest do
  @moduledoc """
  Priors end to end: the pipeline writes the relation, the rule reads it,
  and a run without priors is the run it always was.
  """

  use ExUnit.Case, async: true

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

  # The fixtures' facts and the solves come from the suite's store; the
  # priors are asked every run, which is what these tests test.
  defp through_store(opts, analyses),
    do: opts |> Keyword.put(:analyses, analyses) |> Keyword.put(:cache, Argus.Test.Memo.store())

  defp run(opts) do
    assert {:ok, %Argus.Findings{degraded: []} = r} =
             Argus.Findings.run(@mods, through_store(opts, [:exposure]))

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
    assert heuristic.title == "#{inspect(S.Heuristic)}.totp_seed is printed by inspect/1"
    assert heuristic.severity == :warning
    assert heuristic.confidence == 950
    assert List.last(heuristic.help) =~ "heuristic"
    assert List.last(heuristic.help) =~ "p=0.95"
    assert heuristic.at_label == "declared without redact: true"
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

  @tag :cache
  test "through a store, priors are asked every run and the findings are a fresh run's",
       %{tmp_dir: dir} do
    skip_without_souffle()
    store = Path.join(dir, "store")
    opts = [analyses: [:exposure]] ++ priors(Path.join(dir, "answers"))

    assert {:ok, afresh} = Argus.Findings.run(@mods, opts)
    assert {:ok, cold} = Argus.Findings.run(@mods, [cache: store] ++ opts)
    assert {:ok, warm} = Argus.Findings.run(@mods, [cache: store] ++ opts)

    for run <- [cold, warm], do: assert(run.findings == afresh.findings)
    assert Enum.any?(afresh.findings, &(&1.provenance == :heuristic))
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

  describe "unsafe_input re-tiers a path row by what the sink's function reads" do
    alias Argus.Test.Fixtures.Taint

    # Every asked function reads storage at 0.9; anything else `none`.
    defmodule StorageOracle do
      @behaviour Argus.Priors.Oracle

      @impl true
      def ask(request, opts) do
        source = Keyword.get(opts, :source, "storage")
        p = Keyword.get(opts, :p, 0.9)

        answers =
          for {id, q} <- request.questions, into: %{} do
            case q.type do
              "choice" when is_map_key(q.criteria, :storage) ->
                {id,
                 %{
                   "type" => "choice",
                   "choice" => source,
                   "confidence" => p,
                   "probabilities" => %{source => p}
                 }}

              "choice" ->
                {id,
                 %{
                   "type" => "choice",
                   "choice" => "none",
                   "confidence" => 0.99,
                   "probabilities" => %{"none" => 0.99}
                 }}

              "noul" ->
                {id, %{"type" => "noul", "noul" => 0.5}}
            end
          end

        {:ok,
         %{
           answers: answers,
           usage: %{"input_tokens" => 50},
           model: request.model,
           request_id: nil
         }}
      end
    end

    @taint [
      Taint.Store,
      Taint.StoreSourcedPlug,
      Taint.StoreSourcedAdjacent,
      Taint.StoreSourcedWorker
    ]

    defp sinks(opts) do
      assert {:ok, %Argus.Findings{degraded: []} = r} =
               Argus.Findings.run(@taint, through_store(opts, [:unsafe_input]))

      r.findings |> Enum.filter(&(&1.title =~ "atom creation")) |> Enum.sort_by(& &1.mfa)
    end

    defp storage(dir, extra \\ []),
      do: [
        priors: :live,
        priors_opts:
          Keyword.merge([oracle: StorageOracle, cache_dir: dir, model: "jev-test"], extra)
      ]

    test "off: direct is an error, adjacent a warning, transitive info, all structural" do
      skip_without_souffle()
      by_prox = sinks([]) |> Map.new(&{&1.at_label, &1.severity})
      assert map_size(by_prox) >= 1
      assert Enum.all?(sinks([]), &(&1.provenance == :structural))
      assert Enum.map(sinks([]), & &1.severity) |> Enum.sort() == [:error, :info, :warning]
    end

    test "on: the adjacent and transitive rows step down and say why; direct is untouched", %{
      tmp_dir: dir
    } do
      skip_without_souffle()
      findings = sinks(storage(dir))

      direct = Enum.find(findings, &(elem(&1.mfa, 1) == :call))
      adjacent = Enum.find(findings, &(elem(&1.mfa, 1) == :convert))
      transitive = Enum.find(findings, &(elem(&1.mfa, 1) == :level_two))

      assert direct.severity == :error and direct.provenance == :structural

      assert adjacent.severity == :info and adjacent.provenance == :heuristic and
               adjacent.confidence == 900

      assert List.last(adjacent.help) =~ "reads storage, not the request (p=0.90)"
      refute adjacent.at_label =~ "heuristic"
      assert transitive.severity == :info and transitive.provenance == :heuristic
      assert List.last(transitive.help) =~ "heuristic"
    end

    test "on: the same sites, the same titles — a re-tier never removes a row", %{tmp_dir: dir} do
      skip_without_souffle()
      key = &Enum.map(&1, fn f -> {f.title, f.mfa, f.instr} end)
      assert key.(sinks([])) == key.(sinks(storage(dir)))
    end

    test "passthrough leaves the row alone, and so does a probability under 0.7 (reads)", %{
      tmp_dir: dir
    } do
      skip_without_souffle()

      assert Enum.all?(
               sinks(storage(dir, oracle_opts: [source: "passthrough"])),
               &(&1.provenance == :structural)
             )

      assert Enum.all?(
               sinks(storage(dir, oracle_opts: [p: 0.65])),
               &(&1.provenance == :structural)
             )
    end
  end

  describe "coupling doubts a dependency inferred from reaching a sibling" do
    alias Argus.Test.Fixtures.{FacadeCaller, FacadeHelper, FacadeSupervisor}

    # Answers the noul with `p` for every module asked.
    defmodule NoulOracle do
      @behaviour Argus.Priors.Oracle

      @impl true
      def ask(request, opts) do
        p = Keyword.get(opts, :p, 0.1)

        answers =
          for {id, q} <- request.questions, into: %{} do
            case q.type do
              "noul" ->
                {id, %{"type" => "noul", "noul" => p}}

              "choice" ->
                first = q.criteria |> Map.keys() |> List.first() |> to_string()

                {id,
                 %{
                   "type" => "choice",
                   "choice" => first,
                   "confidence" => 0.5,
                   "probabilities" => %{first => 0.5}
                 }}
            end
          end

        {:ok,
         %{
           answers: answers,
           usage: %{"input_tokens" => 40},
           model: request.model,
           request_id: nil
         }}
      end
    end

    @facade [FacadeSupervisor, FacadeCaller, FacadeHelper]

    defp couplings(opts) do
      assert {:ok, %Argus.Findings{degraded: []} = r} =
               Argus.Findings.run(@facade, through_store(opts, [:coupling]))

      Enum.filter(r.findings, &(&1.title =~ "one_for_one"))
    end

    defp noul(dir, p),
      do: [
        priors: :live,
        priors_opts: [oracle: NoulOracle, oracle_opts: [p: p], cache_dir: dir, model: "jev-test"]
      ]

    # The caller reaches only a pure function of the helper, so no path
    # waits on a reply: the coupling is graded one-way, an info already.
    # The doubt then shows as provenance and label, not as a step down.
    test "off: the inferred coupling is a structural one-way finding" do
      skip_without_souffle()
      assert [finding] = couplings([])
      assert finding.severity == :info
      assert finding.provenance == :structural
      assert finding.title == "One-way coupling under one_for_one"
    end

    test "on, and the helper's API does not talk to a process: the same finding, marked heuristic",
         %{
           tmp_dir: dir
         } do
      skip_without_souffle()
      assert [finding] = couplings(noul(dir, 0.1))
      assert finding.severity == :info
      assert finding.provenance == :heuristic
      assert finding.confidence == 900

      assert finding.at_label == "supervision tree defined here"

      assert List.last(finding.help) =~
               "#{inspect(FacadeHelper)}'s API does not talk to a process"

      assert List.last(finding.help) =~ "(p=0.90)"

      assert finding.title == "One-way coupling under one_for_one"
    end

    test "on, and the model thinks it is a facade: nothing changes", %{tmp_dir: dir} do
      skip_without_souffle()
      assert [finding] = couplings(noul(dir, 0.85))
      assert finding.severity == :info and finding.provenance == :structural
    end
  end
end
