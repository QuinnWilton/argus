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
    assert_raise Scry.ConfigError,
                 ~r/unknown analyses \[:nonsense\].*or a set: \[:all, :default/s,
                 fn ->
                   Config.load(analyses: [:coupling, :nonsense])
                 end
  end

  describe "validation" do
    defp error(raw) do
      assert_raise Scry.ConfigError, fn -> Config.load(raw) end
    end

    test "a misspelled severity key fails and suggests the concern" do
      e = error(severity: [mailbx: :error])
      assert e.key == [:severity, :mailbx]
      assert e.message =~ "severity names unknown analysis :mailbx"
      assert e.message =~ "did you mean :mailbox?"
      assert e.message =~ ":scry → :severity → :mailbx"
    end

    test "a severity keyed by a set applies to every member; later entries win" do
      {:ok, default} = Argus.Analysis.set(:default)

      severity = Config.load(severity: [default: :error, mailbox: :info]).severity

      assert Map.keys(severity) |> Enum.sort() == Enum.sort(default)
      assert severity.mailbox == :info
      assert severity.coupling == :error
    end

    test "a severity level outside error/warning/info fails and suggests one" do
      e = error(severity: [mailbox: :warn])
      assert e.key == [:severity, :mailbox]
      assert e.message =~ "did you mean :warning?"
    end

    test "severity must be a keyword list" do
      assert error(severity: :error).key == [:severity]
      assert error(severity: [:mailbox]).key == [:severity]
    end

    test "ignore must be a keyword list with known keys" do
      e = error(ignore: :nope)
      assert e.key == [:ignore]
      assert e.message =~ "ignore must be a keyword list, got: :nope"

      e = error(ignore: [module: [~r/Gen/]])
      assert e.key == [:ignore, :module]
      assert e.message =~ "unknown ignore key :module"
      assert e.message =~ "did you mean :modules?"
    end

    test "an unknown top-level key suggests the known one" do
      e = error(analysis: [:mailbox])
      assert e.key == [:analysis]
      assert e.message =~ "did you mean :analyses?"
    end

    test "a config that is not a keyword list fails" do
      assert error(:all).key == []
      assert error([:mailbox]).key == []
    end

    test "a misspelled analysis suggests the concern" do
      e = error(analyses: [:coupling, :mailbx])
      assert e.message =~ "unknown analyses [:mailbx]"
      assert e.message =~ "did you mean :mailbox?"
    end

    test "an enum value suggests its closest member" do
      e = error(fail_on: :warnings)
      assert e.key == [:fail_on]
      assert e.message =~ "did you mean :warning?"
    end

    test "prints like Mix.Error, without a stacktrace" do
      assert %Scry.ConfigError{mix: true} = error(souffle: :maybe)
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
      assert_raise Scry.ConfigError, ~r/priors must be :off, :cached_only, :live/, fn ->
        Config.load(priors: :sometimes)
      end

      assert_raise Scry.ConfigError, ~r/unknown priors key :threshold/, fn ->
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
