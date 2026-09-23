defmodule Scry.ScannerTest do
  use ExUnit.Case, async: true

  alias Roux.Input
  alias Scry.Scanner

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

      scan = Scanner.discover([Path.join(dir, "app/ebin"), Path.join(dir, "dep/ebin")], [])

      assert scan.modules == %{Shared => own, OnlyDep => only}
      assert scan.duplicates == [%{module: Shared, used: own, shadowed: [dep]}]

      # The order the caller gives decides, never the directory listing.
      reversed = Scanner.discover([Path.join(dir, "dep/ebin"), Path.join(dir, "app/ebin")], [])
      assert reversed.modules[Shared] == dep
    end

    test "ignored modules are neither analyzed nor reported", %{tmp_dir: dir} do
      beam!(Path.join(dir, "a"), Elixir.Gen.Thing)
      beam!(Path.join(dir, "b"), Elixir.Gen.Thing)

      scan = Scanner.discover([Path.join(dir, "a"), Path.join(dir, "b")], [~r/^Gen\./])
      assert scan == %{modules: %{}, duplicates: []}
    end
  end

  describe "sync/3" do
    setup do
      db = Roux.Database.new()
      :ok = Roux.Lang.register_module(db, Scry.Frontend)
      :ok = Roux.Lang.register_module(db, Scry.Analysis)
      %{db: db}
    end

    test "a beam that vanished after discovery is skipped, not a crash", %{db: db, tmp_dir: dir} do
      kept = beam!(dir, Elixir.Kept)
      gone = Path.join(dir, "Elixir.Gone.beam")

      result = Scanner.sync(db, %{Kept => kept, Gone => gone}, %{})

      assert Map.keys(result.sources) == [kept]
      assert result.changed == [Kept]
      assert Input.get(db, :module_set, :all) == [Kept]
    end

    test "a vanished beam that was there before is removed", %{db: db, tmp_dir: dir} do
      kept = beam!(dir, Elixir.Kept)
      later = beam!(dir, Elixir.Later)
      Scanner.sync(db, %{Kept => kept, Later => later}, %{})

      File.rm!(later)
      result = Scanner.sync(db, %{Kept => kept, Later => later}, %{})

      assert result.removed == [Later]
      assert Input.get(db, :module_set, :all) == [Kept]
    end
  end
end
