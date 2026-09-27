defmodule Argus.ProjectTest do
  @moduledoc """
  Each adapter finds a built project's program, dependencies and state
  directory, over the fixture projects built without their tools
  (`Argus.Test.Projects`), and says what to run when there is nothing
  built, or when a source is newer than its beam.
  """

  use ExUnit.Case, async: true

  alias Argus.Project
  alias Argus.Test.Projects

  @moduletag :tmp_dir

  describe "detect/1" do
    test "each build tool by the files it keeps", %{tmp_dir: dir} do
      for {name, kind} <- [rebar3_app: :rebar3, gleam_app: :gleam, erlang_mk_app: :erlang_mk] do
        assert Project.detect(Projects.source(name)) == {:ok, kind}
      end

      assert Project.detect(Path.expand("projects/depot", Path.dirname(__DIR__))) == :error
      File.write!(Path.join(dir, "mix.exs"), "")
      assert Project.detect(dir) == {:ok, :mix}
    end

    test "a directory of bare beams is never detected", %{tmp_dir: dir} do
      assert Project.detect(dir) == :error
    end
  end

  describe "rebar3" do
    test "an umbrella's apps are one program; the rest of the profile are dependencies", %{
      tmp_dir: dir
    } do
      root = Projects.synthesize!(:rebar3_app, Path.join(dir, "app"))
      assert {:ok, project} = Project.load(:rebar3, root)

      lib = Path.join(root, "_build/default/lib")

      assert project.apps == [
               {:ledger, Path.join(lib, "ledger/ebin")},
               {:shop, Path.join(lib, "shop/ebin")}
             ]

      assert project.deps == [
               {:telemetry, Path.join(root, "_build/default/checkouts/telemetry/ebin")}
             ]

      assert project.state_dir == Path.join(root, "_build/default/argus")
      assert project.build == "rebar3 compile"
      assert Project.stale(project) == []
    end

    test "a source newer than its beam, or without one, is stale", %{tmp_dir: dir} do
      root = Projects.synthesize!(:rebar3_app, Path.join(dir, "app"))
      File.touch!(Path.join(root, "apps/shop/src/shop_sonar.erl"), System.os_time(:second) + 60)
      File.write!(Path.join(root, "apps/ledger/src/ledger_new.erl"), "-module(ledger_new).\n")

      {:ok, project} = Project.load(:rebar3, root)

      assert Project.stale(project) ==
               ["apps/ledger/src/ledger_new.erl", "apps/shop/src/shop_sonar.erl"]
    end

    test "nothing built names the build command", %{tmp_dir: dir} do
      root = Projects.copy!(:rebar3_app, Path.join(dir, "app"))
      assert {:error, message} = Project.load(:rebar3, root)
      assert message =~ "no beams for ledger (_build/default/lib/ledger/ebin)"
      assert message =~ "build it first (`rebar3 compile`)"

      assert {:error, message} = Project.load(:rebar3, root, profile: "test")
      assert message =~ "`rebar3 as test compile`"
    end

    test "explicit ebins and state take the place of what would be found", %{tmp_dir: dir} do
      root = Projects.synthesize!(:rebar3_app, Path.join(dir, "app"))
      shop = Path.join(root, "_build/default/lib/shop/ebin")

      {:ok, project} =
        Project.load(:rebar3, root,
          apps: [shop: shop],
          deps: [ledger: "_build/default/lib/ledger/ebin"],
          state_dir: Path.join(dir, "state")
        )

      assert project.apps == [shop: shop]
      assert project.deps == [ledger: Path.join(root, "_build/default/lib/ledger/ebin")]
      assert project.state_dir == Path.join(dir, "state")
    end

    test "a single-app project is its root app", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "src"))
      File.write!(Path.join(dir, "rebar.config"), "{erl_opts, [debug_info]}.\n")
      File.write!(Path.join(dir, "src/solo.app.src"), "{application, solo, []}.\n")
      File.mkdir_p!(Path.join(dir, "_build/default/lib/solo/ebin"))
      File.write!(Path.join(dir, "_build/default/lib/solo/ebin/solo.beam"), "")

      assert {:ok, %{apps: [solo: _], deps: []}} = Project.load(:rebar3, dir)
    end
  end

  describe "gleam" do
    test "the package gleam.toml names, the other packages as dependencies", %{tmp_dir: dir} do
      root = Projects.synthesize!(:gleam_app, Path.join(dir, "app"))
      assert {:ok, project} = Project.load(:gleam, root)

      erlang = Path.join(root, "build/dev/erlang")
      assert project.apps == [gleam_app: Path.join(erlang, "gleam_app/ebin")]
      assert project.deps == [gleam_stdlib: Path.join(erlang, "gleam_stdlib/ebin")]
      assert project.state_dir == Path.join(root, "build/argus")
      assert project.build == "gleam build"
    end

    test "a Gleam module is stale by its path's module name", %{tmp_dir: dir} do
      root = Projects.synthesize!(:gleam_app, Path.join(dir, "app"))
      later = System.os_time(:second) + 60
      File.touch!(Path.join(root, "src/gleam_app/worker.gleam"), later)

      {:ok, project} = Project.load(:gleam, root)
      assert Project.stale(project) == ["src/gleam_app/worker.gleam"]

      File.touch!(Path.join(root, "build/dev/erlang/gleam_app/ebin/gleam_app@worker.beam"), later)
      assert Project.stale(project) == []
    end

    test "nothing built names gleam build", %{tmp_dir: dir} do
      root = Projects.copy!(:gleam_app, Path.join(dir, "app"))
      assert {:error, message} = Project.load(:gleam, root)
      assert message =~ "(`gleam build`)"
    end
  end

  describe "erlang.mk" do
    test "ebin/ named by PROJECT, deps/*/ebin as dependencies", %{tmp_dir: dir} do
      root = Projects.synthesize!(:erlang_mk_app, Path.join(dir, "app"))
      assert {:ok, project} = Project.load(:erlang_mk, root)

      assert project.apps == [mk_app: Path.join(root, "ebin")]
      assert project.deps == [mk_dep: Path.join(root, "deps/mk_dep/ebin")]
      assert project.state_dir == Path.join(root, ".erlang.mk/argus")
      assert project.build == "make"
      assert Project.stale(project) == []
    end
  end

  describe "beams" do
    test "named directories, by their .app or the directory above", %{tmp_dir: dir} do
      root = Projects.synthesize!(:erlang_mk_app, Path.join(dir, "app"))

      {:ok, project} =
        Project.load(:beams, root,
          ebins: ["ebin"],
          dep_ebins: [Path.join(root, "deps/mk_dep/ebin")]
        )

      assert project.apps == [mk_app: Path.join(root, "ebin")]
      assert project.deps == [mk_dep: Path.join(root, "deps/mk_dep/ebin")]
      assert project.state_dir == Path.join(root, ".argus")
      assert project.build == nil
    end

    test "no ebin named is an error", %{tmp_dir: dir} do
      assert {:error, message} = Project.load(:beams, dir)
      assert message =~ "no application to analyze"
    end
  end
end
