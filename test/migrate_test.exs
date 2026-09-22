defmodule Argus.MigrateTest do
  use ExUnit.Case, async: true

  alias Argus.Migrate

  @moduletag :tmp_dir

  describe "migrate_counts/1" do
    test "a retired name that maps to one concern moves, adding to what is there" do
      assert {%{"coupling" => 3}, []} =
               Migrate.migrate_counts(%{"one_for_one_coupling" => 1, "coupling" => 2})
    end

    test "a retired name spanning several concerns is dropped and reported" do
      assert {%{"structure" => 0}, [{:ambiguous, "supervision", 4, targets}]} =
               Migrate.migrate_counts(%{"supervision" => 4, "structure" => 0})

      assert Enum.sort(targets) == [:coupling, :shutdown, :startup, :structure]
    end

    test "a zero under a name spanning several concerns is a zero under each" do
      assert {counts, []} =
               Migrate.migrate_counts(%{
                 "supervision" => 0,
                 "one_for_one_coupling" => 2,
                 "shutdown" => 1
               })

      assert counts == %{"coupling" => 2, "shutdown" => 1, "startup" => 0, "structure" => 0}
    end

    test "current and unknown names pass through" do
      assert {%{"mailbox" => 1, "obelos_thing" => 2}, []} =
               Migrate.migrate_counts(%{"mailbox" => 1, "obelos_thing" => 2})
    end

    test "two retired names landing in one concern sum" do
      assert {%{"blocking" => 3}, []} =
               Migrate.migrate_counts(%{"call_cycle" => 1, "timeout_chain" => 2})
    end
  end

  describe "migrate_manifest/1" do
    @manifest """
    %{
      name: "x",
      # kept — with a multi-byte dash before the block
      expectations: %{
        argus: %{
          "one_for_one_coupling" => 1,
          "supervision" => 0,
          "unsafe_task" => 2
        },
        obelos: %{"suggestions" => 3},
        # scry pins the default set
        scry: %{"unlinked_spawn" => 0},
        gloss: %{}
      },
      edits: []
    }
    """

    test "rewrites the retired analyzers' maps and keeps the rest of the file", %{tmp_dir: dir} do
      path = Path.join(dir, "manifest.exs")
      File.write!(path, @manifest)

      assert {:ok, notes} = Migrate.migrate_manifest(path)
      assert [argus: [{:ambiguous, "unsafe_task", 2, _}]] = notes

      {manifest, _} = Code.eval_file(path)
      assert manifest.name == "x"
      assert manifest.edits == []

      assert manifest.expectations == %{
               argus: %{"coupling" => 1, "shutdown" => 0, "startup" => 0, "structure" => 0},
               obelos: %{"suggestions" => 3},
               scry: %{"failure" => 0},
               gloss: %{}
             }

      rewritten = File.read!(path)
      assert rewritten =~ "# kept — with a multi-byte dash before the block"
      assert rewritten =~ "# scry pins the default set"
      assert rewritten =~ ~s(obelos: %{"suggestions" => 3})
    end

    test "the analyzers option narrows the rewrite", %{tmp_dir: dir} do
      path = Path.join(dir, "manifest.exs")
      File.write!(path, @manifest)

      assert {:ok, _} = Migrate.migrate_manifest(path, analyzers: [:argus])

      {manifest, _} = Code.eval_file(path)
      assert manifest.expectations.scry == %{"unlinked_spawn" => 0}
      assert manifest.expectations.argus["coupling"] == 1
    end

    test "an analyzer the manifest does not pin is an error", %{tmp_dir: dir} do
      path = Path.join(dir, "manifest.exs")
      File.write!(path, @manifest)

      assert {:error, {:unknown_analyzer, :planchette}} =
               Migrate.migrate_manifest(path, analyzers: [:planchette])

      assert File.read!(path) == @manifest
    end
  end
end
