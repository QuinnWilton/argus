defmodule Argus.Integrations.GleamTest do
  @moduledoc """
  The Gleam fixture built by gleam itself (it has no dependencies, so
  the build is offline): the adapter finds the package, and a finding
  lands in the Erlang the build generated, at the line the bytecode
  names. Tagged `:gleam`.
  """

  use ExUnit.Case, async: true
  @moduletag :gleam
  @moduletag :flowlog
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  alias Argus.Test.Projects

  test "a Gleam build's package, and a finding in its generated Erlang", %{tmp_dir: dir} do
    gleam = System.find_executable("gleam") || raise "gleam is not on PATH"
    root = Projects.copy!(:gleam_app, Path.join(dir, "app"))
    File.rm_rf!(Path.join(root, "erlang"))
    {output, 0} = System.cmd(gleam, ["build"], cd: root, stderr_to_stdout: true)
    assert output =~ "Compiled"

    {:ok, project} = Argus.Project.load(:gleam, root)
    assert Keyword.keys(project.apps) == [:gleam_app]
    assert Argus.Project.stale(project) == []

    config = Argus.Config.load(analyses: [:failure])
    result = Argus.Driver.run(config, project: project)
    entries = Argus.Report.build(result.located, config, root)

    artefacts = Path.join(root, "build/dev/erlang/gleam_app/_gleam_artefacts")
    assert [spawned] = Enum.filter(entries, &(&1.title == "Unlinked process spawned"))
    assert spawned.file == Path.join(artefacts, "gleam_app@worker.erl")

    assert spawned.file |> File.read!() |> String.split("\n") |> Enum.at(spawned.line - 1) =~
             "erlang:spawn("

    # The generated Erlang argus's fixture carries is what gleam wrote.
    for file <- ~w(gleam_app.erl gleam_app@worker.erl gleam_app@@main.erl) do
      assert File.read!(Path.join(artefacts, file)) ==
               File.read!(Path.join(Projects.source(:gleam_app), "erlang/gleam_app/#{file}"))
    end
  end
end
