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

  # The digest a fresh VM computes with `ebin` on its code path.
  defp in_peer(ebin, opts) do
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io})

    try do
      :ok = :peer.call(peer, :code, :add_pathsa, [:code.get_path()])
      true = :peer.call(peer, :code, :add_patha, [String.to_charlist(ebin)])
      :peer.call(peer, Argus.Specs, :environment_digest, [opts], 60_000)
    after
      :peer.stop(peer)
    end
  end

  test "a fresh VM reads an ebin's hashes kept under its stamp, and hashes it again once it moves",
       %{tmp_dir: tmp} do
    ebin = app_dir(Path.join(tmp, "app"), "argus_env_probe", ":ok")
    beam = Path.join(ebin, "Elixir.ArgusEnvProbe.beam")
    # Written long enough ago that a stamp tells a later write apart.
    File.touch!(beam, System.os_time(:second) - 60)
    cache = Path.join(tmp, "ebins")
    opts = [cache: cache]

    first = in_peer(ebin, opts)

    assert [kept] =
             cache |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "argus_env_probe-"))

    # A fresh VM takes the kept hashes as they are: planted ones show.
    File.write!(Path.join(cache, kept), :erlang.term_to_binary([{"planted", "hash"}]))
    assert in_peer(ebin, opts) != first

    # Once the beams move, the planted entry is another stamp's.
    File.touch!(beam, System.os_time(:second) - 30)
    assert in_peer(ebin, opts) == first
  end

  test "an ebin's digests are each beam's, kept under the stamp the environment reads",
       %{tmp_dir: tmp} do
    ebin = app_dir(Path.join(tmp, "app"), "argus_env_probe", ":ok")
    beam = Path.join(ebin, "Elixir.ArgusEnvProbe.beam")
    File.touch!(beam, System.os_time(:second) - 60)
    cache = Path.join(tmp, "ebins")
    {:ok, hash} = Argus.BeamDigest.digest(beam, debug_info: true)

    assert Specs.ebin_digests([ebin], cache: cache) ==
             %{ebin => [{"Elixir.ArgusEnvProbe.beam", hash}]}

    # The entry the environment digest reads: a fresh VM's digest with
    # it planted shows the plant, as one keyed by `environment_digest/1`
    # itself does.
    first = in_peer(ebin, cache: cache)

    assert [kept] =
             cache |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "argus_env_probe-"))

    File.write!(Path.join(cache, kept), :erlang.term_to_binary([{"planted", "hash"}]))
    assert in_peer(ebin, cache: cache) != first
  end

  test "an ebin written a moment ago is hashed every time and kept nowhere", %{tmp_dir: tmp} do
    ebin = app_dir(Path.join(tmp, "app"), "argus_env_probe", ":ok")
    cache = Path.join(tmp, "ebins")
    with_path(ebin, fn -> Specs.environment_digest(cache: cache) end)

    kept =
      case File.ls(cache) do
        {:ok, names} -> names
        {:error, :enoent} -> []
      end

    refute Enum.any?(kept, &String.starts_with?(&1, "argus_env_probe-"))
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
