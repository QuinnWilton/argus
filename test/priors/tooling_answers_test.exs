defmodule Argus.Priors.Questions.ToolingAnswersTest do
  @moduledoc """
  Jev's recorded answers to version 2 for twelve modules of the
  evaluation programs: what every analysis steps down at 0.9 and what it
  leaves. blockster's development setup, hexpm's fake-data generator,
  nerves_hub's debugging helpers, logflare's development-only dashboard,
  Phoenix's code reloader and OTP's `erts_debug` clear it; Livebook's
  doctest runner (it runs its users' doctests), sequin's test messages
  (a feature of its function editor), logflare's system metrics, Ecto's
  migrator and ejabberd's admin commands do not. rabbit's
  `code_version`, which patches modules in the running release, is the
  calibration's one mistake, pinned here as the limit it is.

  The requests are rebuilt from the recorded rows, so a change to what
  the question shows the model misses the cassette and fails here: a
  change in wording is a new prompt version and a new recording.
  """

  use ExUnit.Case, async: true

  alias Argus.Priors.{Cache, Driver}
  alias Argus.Priors.Questions.Tooling

  @moduletag :tmp_dir

  @fixtures Path.expand("../fixtures/priors", __DIR__)

  setup %{tmp_dir: dir} do
    {:ok, 17} = Cache.import(dir, Path.join(@fixtures, "tooling_v2.jsonl"))
    {raw, _} = Code.eval_file(Path.join(@fixtures, "tooling_modules.exs"))

    {:ok, rows, stats} =
      Driver.derive(Tooling, Argus.Facts.decode(raw), mode: :cached_only, cache_dir: dir)

    assert %{requests: 17, cached: 17, failed: 0} = stats

    %{rows: Map.new(rows, fn [mod, kind, _kp, p] -> {mod, {kind, String.to_integer(p)}} end)}
  end

  defp retiered?(rows, mod) do
    {_kind, p} = Map.fetch!(rows, mod)
    p >= 900
  end

  test "a development setup, fake data, debugging helpers, a dev page and a reloader clear 0.9",
       %{rows: rows} do
    for mod <- [
          "BlocksterV2.BotSystem.DevSetup",
          "Hexpm.Fake",
          "NervesHub.Debug",
          "LogflareWeb.Live.Dev.DashboardLive",
          "Phoenix.CodeReloader.Server",
          ":erts_debug"
        ] do
      assert retiered?(rows, mod), "#{mod}: #{inspect(rows[mod])}"
    end

    assert {"test", _} = rows["Hexpm.Fake"]
    assert {"development", _} = rows["BlocksterV2.BotSystem.DevSetup"]
  end

  test "product that reads like tooling stays the product", %{rows: rows} do
    for mod <- [
          "Livebook.Runtime.Evaluator.Doctests",
          "Sequin.Functions.TestMessages",
          "Logflare.SystemMetrics.Wobserver.Processes",
          "Ecto.Migrator",
          ":ejabberd_admin"
        ] do
      refute retiered?(rows, mod), "#{mod}: #{inspect(rows[mod])}"
    end
  end

  test "the calibration's one mistake: a module that patches the running release's code",
       %{rows: rows} do
    assert retiered?(rows, ":code_version")
  end
end
