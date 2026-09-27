defmodule Argus.Specs.SourceTest do
  @moduledoc """
  A project's calls read the specs of the project's own dependencies
  (and the installed OTP's), never the code path: the rebar3 fixture's
  telemetry is a stand-in at a version argus carries another of, with a
  function only it has.
  """

  use ExUnit.Case, async: true

  alias Argus.Specs.Source
  alias Argus.Test.Projects

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Projects.synthesize!(:rebar3_app, Path.join(dir, "app"))
    {:ok, project} = Argus.Project.load(:rebar3, root)
    %{root: root, project: project, source: Source.new(project)}
  end

  test "a module is found in the project, then OTP, then the runtime; else nowhere", %{
    root: root,
    source: source
  } do
    assert Source.which(source, :telemetry) ==
             {:ok, Path.join(root, "_build/default/checkouts/telemetry/ebin/telemetry.beam")}

    assert Source.which(source, :shop_sup) ==
             {:ok, Path.join(root, "_build/default/lib/shop/ebin/shop_sup.beam")}

    assert {:ok, lists} = Source.which(source, :lists)
    assert String.starts_with?(lists, List.to_string(:code.root_dir()))

    assert Source.which(source, Enum) == {:ok, :runtime}
    assert Source.which(source, :argus_no_such_module) == :error

    # argus's own dependencies are not the project's.
    assert Source.which(source, Roux.Database) == :error
  end

  test "installed specs are the project's telemetry's, not argus's", %{source: source} do
    memo = :ets.new(:specs_source_test, [:set, :public])
    :ets.insert(memo, {:specs_source, source})

    assert %{{:fixture_version, 0} => shapes} = Argus.Specs.installed(:telemetry, memo)
    assert :total in shapes

    # The code path's telemetry is argus's, which has no such function.
    refute Map.has_key?(Argus.Specs.installed(:telemetry), {:fixture_version, 0})
    :ets.delete(memo)
  end

  test "extraction with the source reads the callee's specs from the project", %{
    root: root,
    source: source
  } do
    beam = Path.join(root, "_build/default/lib/ledger/ebin/ledger.beam")

    rows = fn opts ->
      opts = [format: :typed, extractors: [Argus.Extractors.Specs]] ++ opts
      {:ok, facts} = Argus.Pipeline.extract([beam], opts)
      for %{func: ":telemetry:" <> _ = func, origin: "installed"} <- facts.spec_return, do: func
    end

    assert ":telemetry:fixture_version/0" in rows.(specs_source: source)
    refute ":telemetry:fixture_version/0" in rows.([])
  end
end
