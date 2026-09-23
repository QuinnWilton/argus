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

    test "ignored modules are neither analyzed nor reported, only watched", %{tmp_dir: dir} do
      first = beam!(Path.join(dir, "a"), Elixir.Gen.Thing)
      beam!(Path.join(dir, "b"), Elixir.Gen.Thing)

      scan = Scanner.discover([Path.join(dir, "a"), Path.join(dir, "b")], [~r/^Gen\./])
      assert scan == %{modules: %{}, ignored: %{Gen.Thing => first}, duplicates: []}
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

    test "an ignored module is watched in its own input, never analyzed", %{db: db, tmp_dir: dir} do
      kept = beam!(dir, Elixir.Kept)
      gen = beam!(dir, Elixir.Gen, "v1")

      result = Scanner.sync(db, %{Kept => kept}, %{}, %{Gen => gen})

      assert result.changed == [Kept]
      assert result.ignored_moved?
      assert Input.get(db, :module_set, :all) == [Kept]
      assert %{path: ^gen} = Input.get(db, :ignored_beam, Gen)
      refute Input.exists?(db, :beam_meta, Gen)
      assert Map.has_key?(result.sources, gen)

      File.write!(gen, "v2")
      result = Scanner.sync(db, %{Kept => kept}, result.sources, %{Gen => gen})
      assert result.changed == []
      assert result.ignored_moved?

      result = Scanner.sync(db, %{Kept => kept}, result.sources, %{})
      assert result.ignored_moved?
      refute Input.exists?(db, :ignored_beam, Gen)
    end

    test "a module moving onto or off the ignore list is read under its new input",
         %{db: db, tmp_dir: dir} do
      path = beam!(dir, Elixir.Moving)
      # Old enough for the mtime+size prefilter to trust the metadata.
      File.touch!(path, System.os_time(:second) - 60)

      analyzed = Scanner.sync(db, %{Moving => path}, %{})
      assert Input.exists?(db, :beam_meta, Moving)

      ignored = Scanner.sync(db, %{}, analyzed.sources, %{Moving => path})
      assert ignored.removed == [Moving]
      assert %{path: ^path} = Input.get(db, :ignored_beam, Moving)

      back = Scanner.sync(db, %{Moving => path}, ignored.sources, %{})
      assert back.changed == [Moving]
      assert %{path: ^path} = Input.get(db, :beam_meta, Moving)
      refute Input.exists?(db, :ignored_beam, Moving)
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
