defmodule Argus.Project.ScanTest do
  use ExUnit.Case, async: true

  alias Argus.Project.Scan

  @moduletag :tmp_dir

  defp beam!(dir, module, content \\ "beam") do
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{module}.beam")
    File.write!(path, content)
    path
  end

  describe "discover/2" do
    test "a module in two ebins is taken from the first, and reported", %{tmp_dir: dir} do
      own = beam!(Path.join(dir, "app/ebin"), Elixir.Shared)
      dep = beam!(Path.join(dir, "dep/ebin"), Elixir.Shared)
      only = beam!(Path.join(dir, "dep/ebin"), Elixir.OnlyDep)

      scan = Scan.discover([Path.join(dir, "app/ebin"), Path.join(dir, "dep/ebin")], [])

      assert scan.modules == %{Shared => own, OnlyDep => only}
      assert scan.duplicates == [%{module: Shared, used: own, shadowed: [dep]}]

      # The order the caller gives decides, never the directory listing.
      reversed = Scan.discover([Path.join(dir, "dep/ebin"), Path.join(dir, "app/ebin")], [])
      assert reversed.modules[Shared] == dep
    end

    test "ignored modules are neither analyzed nor reported, only watched", %{tmp_dir: dir} do
      first = beam!(Path.join(dir, "a"), Elixir.Gen.Thing)
      beam!(Path.join(dir, "b"), Elixir.Gen.Thing)

      scan = Scan.discover([Path.join(dir, "a"), Path.join(dir, "b")], [~r/^Gen\./])
      assert scan == %{modules: %{}, ignored: %{Gen.Thing => first}, duplicates: []}
    end
  end
end
