defmodule Scry.ConfigTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Scry.Config

  test "the default analyses are argus's default set" do
    assert Config.load([]).analyses == Scry.Analysis.default_analyses()
    assert {:ok, Config.load([]).analyses} == Argus.Analysis.set(:default)
  end

  test "a named set expands to its members, once" do
    {:ok, security} = Argus.Analysis.set(:security)
    assert Config.load(analyses: [:security, :exposure]).analyses == security
  end

  test "a retired name expands to its concerns with a notice" do
    output =
      capture_io(fn ->
        send(self(), {:analyses, Config.load(analyses: [:unsafe_task, :coupling]).analyses})
      end)

    assert_received {:analyses, [:failure, :mailbox, :coupling]}
    assert output =~ ":unsafe_task is retired in argus 0.17"
    assert output =~ ":failure, :mailbox"
  end

  test "a severity override keyed by a retired name follows its findings" do
    assert Config.load(severity: [gen_statem: :error, ets: :info]).severity ==
             %{mailbox: :error, state_machine: :error, ets: :info}
  end

  test "an unknown analysis fails with the concerns and the sets" do
    assert_raise Mix.Error, ~r/unknown analyses \[:nonsense\].*or a set: \[:all, :default/s, fn ->
      Config.load(analyses: [:coupling, :nonsense])
    end
  end

  describe "priors" do
    test "off by default, a bare mode or a keyword with mode: and Argus.Priors options" do
      assert Config.load([]).priors == %{mode: :off, opts: []}
      assert Config.load(priors: :cached_only).priors == %{mode: :cached_only, opts: []}

      assert Config.load(
               priors: [mode: :cached_only, cassette: "priors.jsonl", model: "jev-1.13.0"]
             ).priors ==
               %{mode: :cached_only, opts: [cassette: "priors.jsonl", model: "jev-1.13.0"]}
    end

    test "an unknown mode or option fails naming the valid ones" do
      assert_raise Mix.Error, ~r/priors must be :off, :cached_only, :live/, fn ->
        Config.load(priors: :sometimes)
      end

      assert_raise Mix.Error, ~r/unknown priors options \[:threshold\]/, fn ->
        Config.load(priors: [mode: :cached_only, threshold: 900])
      end
    end

    test "live without a key fails at configuration" do
      key = System.get_env("TYPESAFE_API_KEY")
      System.delete_env("TYPESAFE_API_KEY")

      try do
        assert_raise ArgumentError, ~r/TYPESAFE_API_KEY/, fn -> Config.load(priors: :live) end
      after
        if key, do: System.put_env("TYPESAFE_API_KEY", key)
      end
    end

    test "live with an oracle of one's own needs no key" do
      assert %{mode: :live, opts: [oracle: Scry.Test.PriorOracle]} =
               Config.load(priors: [mode: :live, oracle: Scry.Test.PriorOracle]).priors
    end
  end
end
