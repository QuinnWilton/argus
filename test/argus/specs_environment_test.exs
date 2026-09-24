defmodule Argus.SpecsEnvironmentTest do
  # Sync: these tests put directories on the VM's code path, which every
  # other test (and the corpus's memoized engine digest) reads.
  use ExUnit.Case, async: false

  alias Argus.Specs

  @moduletag :tmp_dir

  # An application directory the way a path dependency's build leaves it:
  # an ebin holding the `.app` file and one beam returning `returns`,
  # compiled from `root/deps/<name>/lib`. Its spec says the same, and it
  # keeps its debug info (`mix test` compiles without), which is where
  # specs are read from and where the source path lands.
  defp app_dir(root, name, returns, ebin \\ nil) do
    ebin = ebin || Path.join([root, name, "ebin"])
    File.mkdir_p!(ebin)

    File.write!(
      Path.join(ebin, "argus_env_probe.app"),
      ~s|{application, argus_env_probe, [{vsn, "0.1.0"}, {modules, ['Elixir.ArgusEnvProbe']}]}.\n|
    )

    [{ArgusEnvProbe, beam}] =
      Code.compile_string(
        """
        defmodule ArgusEnvProbe do
          @compile :debug_info
          @spec run() :: #{returns}
          def run, do: #{returns}
        end
        """,
        Path.join([root, "deps", name, "lib", "probe.ex"])
      )

    :code.purge(ArgusEnvProbe)
    :code.delete(ArgusEnvProbe)
    File.write!(Path.join(ebin, "Elixir.ArgusEnvProbe.beam"), beam)
    ebin
  end

  defp with_path(ebin, fun) do
    true = :code.add_patha(String.to_charlist(ebin))

    try do
      fun.()
    after
      :code.del_path(String.to_charlist(ebin))
    end
  end

  test "an application's beams move the digest when its version does not", %{tmp_dir: tmp} do
    before = app_dir(Path.join(tmp, "before"), "argus_env_probe", ":ok")
    later = app_dir(Path.join(tmp, "later"), "argus_env_probe", "{:error, :later}")

    a = with_path(before, &Specs.environment_digest/0)
    b = with_path(later, &Specs.environment_digest/0)

    assert a != b
    assert with_path(before, &Specs.environment_digest/0) == a
  end

  test "an excluded application is named by its version alone", %{tmp_dir: tmp} do
    before = app_dir(Path.join(tmp, "before"), "argus_env_probe", ":ok")
    later = app_dir(Path.join(tmp, "later"), "argus_env_probe", "{:error, :later}")

    a = with_path(before, fn -> Specs.environment_digest(exclude: [:argus_env_probe]) end)
    b = with_path(later, fn -> Specs.environment_digest(exclude: [:argus_env_probe]) end)

    assert a == b
    assert a != with_path(before, &Specs.environment_digest/0)
  end

  test "a dependency built in two checkouts of one project digests the same" do
    # Outside the working directory, as in `Argus.BeamDigestTest`.
    tmp = Path.join(System.tmp_dir!(), "argus-specs-env-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp) end)

    # Where Mix puts a dependency's build: `<project>/_build/<env>/lib`.
    in_project = fn project ->
      root = Path.join(tmp, project)
      ebin = Path.join([root, "_build", "test", "lib", "argus_env_probe", "ebin"])
      app_dir(root, "argus_env_probe", ":ok", ebin)
    end

    here = in_project.("argus")
    there = in_project.("wt/argus-other")

    assert File.read!(Path.join(here, "Elixir.ArgusEnvProbe.beam")) !=
             File.read!(Path.join(there, "Elixir.ArgusEnvProbe.beam"))

    assert with_path(here, &Specs.environment_digest/0) ==
             with_path(there, &Specs.environment_digest/0)
  end
end
