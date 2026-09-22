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

  test "a generic tag names no server even with one handler", %{tmp_dir: tmp_dir} do
    skip_without_souffle()

    results =
      solve(tmp_dir, [Argus.Test.Fixtures.TagGetServer, Argus.Test.Fixtures.TagGenericClient], [
        "tag_handler_count",
        "tag_resolved_call"
      ])

    assert ["call", ":get", "1"] in results["tag_handler_count"]
    assert results["tag_resolved_call"] == []
  end

  test "a tag a handle_info also matches is not evidence", %{tmp_dir: tmp_dir} do
    skip_without_souffle()

    results =
      solve(
        tmp_dir,
        [
          Argus.Test.Fixtures.TagBumpServer,
          Argus.Test.Fixtures.TagBumpListener,
          Argus.Test.Fixtures.TagBumpClient
        ],
        ["tag_resolved_call"]
      )

    assert results["tag_resolved_call"] == []
  end

  test "among several handlers, the one the caller's module refers to wins",
       %{tmp_dir: tmp_dir} do
    skip_without_souffle()

    results =
      solve(
        tmp_dir,
        [
          Argus.Test.Fixtures.TagServerA,
          Argus.Test.Fixtures.TagServerB,
          Argus.Test.Fixtures.TagPool
        ],
        ["tag_resolved_call"]
      )

    pool = "Argus.Test.Fixtures.TagPool:handle_call/3"

    assert [pool, "call", "Argus.Test.Fixtures.TagServerA"] in results["tag_resolved_call"]
    refute [pool, "call", "Argus.Test.Fixtures.TagServerB"] in results["tag_resolved_call"]
  end

  test "a cycle edge that exists only by tag attribution says so" do
    skip_without_souffle()

    {:ok, results} =
      Argus.analyze([Argus.Test.Fixtures.TagServerA, Argus.Test.Fixtures.TagServerB], :blocking)

    assert [[_, _, _, _]] = results["call_cycle"]
    assert Enum.all?(results["call_cycle_path"], fn [_, _, _, how] -> how == "tag" end)
    assert results["call_cycle_path"] != []
  end
end
