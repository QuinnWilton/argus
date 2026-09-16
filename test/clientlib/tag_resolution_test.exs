defmodule Argus.Clientlib.TagResolutionTest do
  use ExUnit.Case

  alias Argus.{Analysis, Pipeline, Souffle}

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp priv_dl, do: Path.join(:code.priv_dir(:panoptes), "dl")

  defp solve(tmp_dir, modules, outputs) do
    facts_dir = Path.join(tmp_dir, "facts")

    {:ok, _} =
      Pipeline.run(modules, facts_dir,
        extractors: [
          Argus.Extractors.OTP,
          Argus.Extractors.ApiCalls,
          Argus.Extractors.CallbackTag
        ]
      )

    :ok = Analysis.derive_stage0(facts_dir)

    rules =
      """
      .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"
      .include "#{Path.join(priv_dl(), "clientlib/otp.dl")}"
      #{Enum.map_join(outputs, "\n", &".output #{&1}")}
      """

    rules_path = Path.join(tmp_dir, "tags.dl")
    File.write!(rules_path, rules)
    {:ok, results} = Souffle.run(facts_dir, rules_path)
    results
  end

  test "a dynamic-target call is attributed to the one module handling its tag",
       %{tmp_dir: tmp_dir} do
    skip_without_souffle()

    results =
      solve(tmp_dir, [Argus.Test.Fixtures.TagServerA, Argus.Test.Fixtures.TagServerB], [
        "tag_resolved_call",
        "sync_dep"
      ])

    a = "Argus.Test.Fixtures.TagServerA"
    b = "Argus.Test.Fixtures.TagServerB"

    assert [a <> ":handle_call/3", "call", b] in results["tag_resolved_call"]
    assert [b <> ":handle_call/3", "call", a] in results["tag_resolved_call"]
    assert [a <> ":handle_call/3", b] in results["sync_dep"]
    assert [b <> ":handle_call/3", a] in results["sync_dep"]
  end

  test "a tag handled by more than one module attributes nothing", %{tmp_dir: tmp_dir} do
    skip_without_souffle()

    results =
      solve(
        tmp_dir,
        [
          Argus.Test.Fixtures.TagServerA,
          Argus.Test.Fixtures.TagServerB,
          Argus.Test.Fixtures.TagProxy
        ],
        ["tag_handler_count", "tag_resolved_call"]
      )

    assert ["call", ":shared_status", "2"] in results["tag_handler_count"]

    refute Enum.any?(results["tag_resolved_call"], fn [func, _kind, _mod] ->
             func == "Argus.Test.Fixtures.TagProxy:status/1"
           end)
  end
end
