defmodule Argus.Project.DriverTest do
  @moduledoc """
  The driver over each non-Mix fixture project (built without its tool,
  `Argus.Test.Projects`): its configuration from its own file, its
  findings placed in its own sources — a Gleam finding in the Erlang
  its build generated, at the line the bytecode names — and its state
  in its own directory. The project's beams are read, never loaded:
  its telemetry, which argus also carries, stays out of the VM.
  """

  use ExUnit.Case, async: true

  alias Argus.{Project, Report}
  alias Argus.Test.Projects

  @moduletag :tmp_dir
  @moduletag :flowlog
  @moduletag timeout: 300_000

  defp run(root, kind, config_overrides \\ []) do
    {:ok, project} = Project.load(kind, root)
    {raw, origin} = Argus.Config.Source.for_project(root, kind)
    config = struct(Argus.Config.load(raw, origin), config_overrides)
    result = Argus.Driver.run(config, project: project)
    {project, config, result, Report.build(result.located, config, root)}
  end

  defp at(entry, root), do: {Path.relative_to(entry.file, root), entry.line}

  test "rebar3: an umbrella's coupling across its apps, its dependency never loaded", %{
    tmp_dir: dir
  } do
    root = Projects.synthesize!(:rebar3_app, Path.join(dir, "app"))
    telemetry = :code.which(:telemetry)

    {project, config, result, entries} = run(root, :rebar3, analyses: [:coupling, :failure])

    assert config.analyses == [:coupling, :failure]
    assert result.notices == []

    assert [coupling] = Enum.filter(entries, &(&1.analysis == :coupling))
    assert at(coupling, root) == {"apps/shop/src/shop_sup.erl", 9}

    assert Enum.map(coupling.related, &at(&1, root)) == [
             {"apps/shop/src/shop_sonar.erl", 18},
             {"apps/shop/src/shop_notifier.erl", 20}
           ]

    assert [spawned] = Enum.filter(entries, &(&1.analysis == :failure))
    assert at(spawned, root) == {"apps/ledger/src/ledger.erl", 12}

    # Read, not loaded: the program's modules are not in the VM, and the
    # telemetry argus runs with is still its own.
    assert :code.is_loaded(:shop_sup) == false
    assert :code.which(:telemetry) == telemetry

    # The dependency, analyzed with include_deps, is the project's.
    scan = Argus.Project.Scan.scan(%{config | include_deps: true}, project)

    assert scan.modules[:telemetry] ==
             Path.join(root, "_build/default/checkouts/telemetry/ebin/telemetry.beam")

    # The state is the project's, and the next run is warm.
    assert File.regular?(Argus.Driver.manifest_file(project))
    {_, _, warm, warm_entries} = run(root, :rebar3, analyses: [:coupling, :failure])
    refute warm.changed?
    assert warm_entries == entries
  end

  test "gleam: a finding in the generated Erlang, at the line the bytecode names", %{
    tmp_dir: dir
  } do
    root = Projects.synthesize!(:gleam_app, Path.join(dir, "app"))

    {_project, _config, result, entries} =
      run(root, :gleam, analyses: [:failure], include_deps: true)

    # gleam@dynamic's nil/0 extracts (its ID once came out malformed).
    assert result.notices == []

    # gleam_app@@main (Gleam's own entry point, with a catch-all of its
    # own) is not the project's code.
    refute Enum.any?(entries, &String.contains?(&1.file, "@@main"))

    artefact = "build/dev/erlang/gleam_app/_gleam_artefacts/gleam_app@worker.erl"
    assert [spawned] = Enum.filter(entries, &(&1.title == "Unlinked process spawned"))
    assert at(spawned, root) == {artefact, 26}

    assert root |> Path.join(artefact) |> File.read!() |> String.split("\n") |> Enum.at(25) =~
             "erlang:spawn("
  end

  test "erlang.mk: argus.config's analyses and severities", %{tmp_dir: dir} do
    root = Projects.synthesize!(:erlang_mk_app, Path.join(dir, "app"))

    {project, config, _result, entries} = run(root, :erlang_mk)

    assert config.analyses == [:coupling, :mailbox, :failure, :blocking]
    assert [spawned] = Enum.filter(entries, &(&1.title == "Unlinked process spawned"))
    assert spawned.severity == :error
    assert at(spawned, root) == {"src/mk_pool.erl", 17}
    assert File.dir?(project.state_dir)
  end
end
