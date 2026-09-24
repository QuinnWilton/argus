defmodule Mix.Tasks.Compile.ScryPriorsTest do
  @moduledoc """
  Priors through scry: the classifier's rows as an input, off by default,
  asked once and then served from the cache and the manifest. In this
  module's peer (`Scry.Test.Peer`): the Mix project stack and the
  working directory are VM-wide.
  """

  use ExUnit.Case, async: true
  use Scry.Test.Peer

  alias Scry.Test.{Fixture, Peer}

  @moduletag timeout: 300_000
  @moduletag :souffle

  # Coupling reads the priors (`prior_talks_to_process`); with mailbox,
  # every finding the fixture has. The questions are asked whatever the
  # analyses.
  @quick [analyses: [:coupling, :mailbox]]

  setup_all do
    %{peer: Peer.start!()}
  end

  defp checkout!(app) do
    copy = Fixture.checkout!(Path.join(System.tmp_dir!(), "scry_priors_#{app}"), @quick, app)
    {copy, app}
  end

  defp compile!, do: Fixture.compile!()

  # The runner directly, on the beams the compile left: what it returns
  # carries every entry field, which a diagnostic does not.
  defp run(scry_config, manifest) do
    Scry.Runner.run(Scry.Config.load(@quick ++ scry_config), manifest: manifest, force: false)
  end

  defp entries(result), do: result.findings_by_file |> Map.values() |> List.flatten()

  defp keys(result),
    do: result |> entries() |> Enum.map(&{&1.code, &1.title, &1.file, &1.line}) |> Enum.sort()

  test "off by default, then on: a superset served from the cache and the manifest on the warm run",
       %{peer: peer} do
    {copy, app} = checkout!(:depot_priors)

    scratch =
      Path.join(System.tmp_dir!(), "scry_priors_cache_#{System.unique_integer([:positive])}")

    File.rm_rf!(scratch)
    log = Path.join(scratch, "asked.log")
    File.mkdir_p!(scratch)

    on = [
      priors: [
        mode: :live,
        oracle: Scry.Test.PriorOracle,
        oracle_opts: [log: log, noul: 0.1],
        cache_dir: Path.join(scratch, "cache"),
        model: "jev-test"
      ]
    ]

    Fixture.in_peer(peer, copy, app, fn _log ->
      assert {_status, _} = compile!()
      manifest = Path.join(scratch, "manifest")

      # Off: every entry structural, nothing asked.
      off = run([], manifest)
      assert off.degraded == []
      assert entries(off) != []
      assert Enum.all?(entries(off), &(&1.provenance == :structural and is_nil(&1.confidence)))
      refute File.exists?(log)

      # On: the oracle is asked, and every structural finding is still there.
      live = run(on, Path.join(scratch, "manifest_on"))
      assert live.degraded == []
      asked = log |> File.read!() |> String.split("\n", trim: true)
      assert asked != []
      assert MapSet.subset?(MapSet.new(keys(off)), MapSet.new(keys(live)))
      assert Enum.all?(entries(live), &Map.has_key?(&1, :provenance))

      # Warm: same answers, nothing asked again — the rows came back with
      # the manifest and the cache answered any request the graph remade.
      warm = run(on, Path.join(scratch, "manifest_on"))
      assert keys(warm) == keys(live)
      assert File.read!(log) |> String.split("\n", trim: true) == asked

      # cached_only against the same cache: identical, and no oracle.
      cached =
        run(
          [
            priors: [
              mode: :cached_only,
              cache_dir: Path.join(scratch, "cache"),
              model: "jev-test"
            ]
          ],
          Path.join(scratch, "manifest_cached")
        )

      assert cached.degraded == []
      assert keys(cached) == keys(live)
      assert File.read!(log) |> String.split("\n", trim: true) == asked
    end)
  end

  test "cached_only with an empty cache is the run without priors", %{peer: peer} do
    {copy, app} = checkout!(:depot_priors_empty)

    scratch =
      Path.join(System.tmp_dir!(), "scry_priors_empty_#{System.unique_integer([:positive])}")

    File.rm_rf!(scratch)
    File.mkdir_p!(scratch)

    Fixture.in_peer(peer, copy, app, fn _log ->
      assert {_status, _} = compile!()
      off = run([], Path.join(scratch, "m1"))

      cached =
        run(
          [
            priors: [
              mode: :cached_only,
              cache_dir: Path.join(scratch, "nothing"),
              model: "jev-test"
            ]
          ],
          Path.join(scratch, "m2")
        )

      assert keys(cached) == keys(off)
      assert Enum.all?(entries(cached), &(&1.provenance == :structural))
    end)
  end
end
