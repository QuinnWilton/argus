defmodule Argus.Integrations.Rebar3Test do
  @moduledoc """
  The rebar3 fixture built by rebar3 itself, and the rebar3 plugin
  (`integrations/rebar3_argus`) run by rebar3 against the escript built
  from this checkout: the ebins rebar3 names, the report relayed, a
  finding over `fail_above` a rebar3 error, and the plugin as a
  post-compile hook.

  Tagged `:rebar3` (and `:escript`): CI's escript job runs them, and
  `mix test --include rebar3 --include escript` does locally.
  """

  use ExUnit.Case, async: false
  @moduletag :rebar3
  @moduletag :flowlog
  @moduletag timeout: 600_000

  alias Argus.Test.Projects

  @plugin Path.expand("../../integrations/rebar3_argus", __DIR__)

  setup_all do
    rebar3 = System.find_executable("rebar3") || raise "rebar3 is not on PATH"
    dir = Path.join(System.tmp_dir!(), "argus_rebar3_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{rebar3_bin: rebar3, dir: dir}
  end

  defp rebar3(context, root, args, env \\ []) do
    System.cmd(context.rebar3_bin, args,
      cd: root,
      stderr_to_stdout: true,
      env: [{"ARGUS_CACHE_DIR", Path.join(context.dir, "store")}, {"TERM", "dumb"} | env]
    )
  end

  test "the adapter finds what rebar3 built, and the driver what it builds", context do
    root = Projects.copy!(:rebar3_app, Path.join(context.dir, "built"))
    {output, 0} = rebar3(context, root, ["compile"])
    assert output =~ "Compiling shop"

    {:ok, project} = Argus.Project.load(:rebar3, root)
    assert Keyword.keys(project.apps) == [:ledger, :shop]
    assert Keyword.keys(project.deps) == [:telemetry]
    assert Argus.Project.stale(project) == []

    config = Argus.Config.load(analyses: [:coupling, :failure])
    result = Argus.Driver.run(config, project: project)
    entries = Argus.Report.build(result.located, config, root)

    assert entries |> Enum.map(& &1.title) |> Enum.sort() ==
             ["Coupled children under one_for_one", "Unlinked process spawned"]
  end

  describe "the plugin" do
    @describetag :escript

    setup context do
      root = Projects.copy!(:rebar3_app, Path.join(context.dir, "plugin"))
      File.mkdir_p!(Path.join(root, "_checkouts"))
      File.cp_r!(@plugin, Path.join(root, "_checkouts/rebar3_argus"))
      File.rm_rf!(Path.join(root, "_checkouts/rebar3_argus/_build"))
      File.write!(Path.join(root, "rebar.config"), "\n{plugins, [rebar3_argus]}.\n", [:append])
      %{root: root, env: [{"ARGUS_ESCRIPT", Argus.Test.Escript.build!()}]}
    end

    test "rebar3 argus relays the report on rebar3's exact ebins", context do
      {output, 0} = rebar3(context, context.root, ["argus"], context.env)

      # rebar.config's {argus, [{analyses, [coupling, mailbox, blocking, startup]}]}.
      assert output =~ "warning[argus.coupling]: Coupled children under one_for_one"
      assert output =~ "├─[apps/shop/src/shop_sonar.erl:18:5]"
      assert output =~ "1 finding (1 warning)"
      refute output =~ "\e["
    end

    test "findings over fail_above are a rebar3 error", context do
      {output, 1} = rebar3(context, context.root, ["argus", "--fail-above", "0"], context.env)
      assert output =~ "argus found more than 0 findings (fail_above)"

      {_output, 0} = rebar3(context, context.root, ["argus", "--fail-above", "1"], context.env)
    end

    test "--format json is the escript's JSON", context do
      {output, 0} = rebar3(context, context.root, ["argus", "-f", "json"], context.env)
      [json | _] = output |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "[{"))

      assert [%{"analysis" => "coupling", "file" => "apps/shop/src/shop_sup.erl"}] =
               JSON.decode!(json)
    end

    test "as a post-compile hook", context do
      File.write!(
        Path.join(context.root, "rebar.config"),
        "{provider_hooks, [{post, [{compile, argus}]}]}.\n",
        [:append]
      )

      {output, 0} = rebar3(context, context.root, ["compile"], context.env)
      assert output =~ "Compiling shop"
      assert output =~ "1 finding (1 warning)"
    end

    test "no escript to be found is a rebar3 error that says where it looks", context do
      {output, 1} =
        rebar3(context, context.root, ["argus"], [
          {"ARGUS_ESCRIPT", Path.join(context.dir, "nowhere/argus")}
        ])

      assert output =~
               "the argus escript #{Path.join(context.dir, "nowhere/argus")} is not a file"
    end
  end
end
