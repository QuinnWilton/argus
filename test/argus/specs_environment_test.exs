defmodule Argus.SpecsEnvironmentTest do
  # Sync: these tests put directories on the VM's code path, which every
  # other test (and the corpus's memoized engine digest) reads.
  use ExUnit.Case, async: false

  alias Argus.Specs

  @moduletag :tmp_dir

  # An application directory the way a path dependency's build leaves it:
  # an ebin holding the `.app` file and one beam returning `returns`.
  # The spec says the same: under `mix test` the compiler keeps no debug
  # info, so the body is what makes the two builds differ.
  defp app_dir(root, name, returns) do
    ebin = Path.join([root, name, "ebin"])
    File.mkdir_p!(ebin)

    File.write!(
      Path.join(ebin, "argus_env_probe.app"),
      ~s|{application, argus_env_probe, [{vsn, "0.1.0"}, {modules, ['Elixir.ArgusEnvProbe']}]}.\n|
    )

    [{ArgusEnvProbe, beam}] =
      Code.compile_string("""
      defmodule ArgusEnvProbe do
        @spec run() :: #{returns}
        def run, do: #{returns}
      end
      """)

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
end
