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

    test "current and unknown names pass through" do
      assert {%{"mailbox" => 1, "obelos_thing" => 2}, []} =
               Migrate.migrate_counts(%{"mailbox" => 1, "obelos_thing" => 2})
    end

    test "two retired names landing in one concern sum" do
      assert {%{"startup" => 3}, []} =
               Migrate.migrate_counts(%{
                 "sync_call_in_init" => 1,
                 "deferred_startup_deadlock" => 2
               })
    end
  end

  describe "migrate_manifest/1" do
    test "rewrites the expectations block and keeps the rest of the file", %{tmp_dir: dir} do
      path = Path.join(dir, "manifest.exs")

      File.write!(path, """
      %{
        name: "x",
        # kept
        expectations: %{
          argus: %{
            "one_for_one_coupling" => 1,
            "supervision" => 0,
            "unsafe_task" => 2
          },
          scry: %{"unlinked_spawn" => 0}
        },
        edits: []
      }
      """)

      assert {:ok, notes} = Migrate.migrate_manifest(path)

      assert [argus: [{:ambiguous, "supervision", 0, _}, {:ambiguous, "unsafe_task", 2, _}]] =
               notes

      {manifest, _} = Code.eval_file(path)
      assert manifest.name == "x"
      assert manifest.edits == []

      assert manifest.expectations == %{
               argus: %{"coupling" => 1},
               scry: %{"failure" => 0}
             }

      assert File.read!(path) =~ "# kept"
    end
  end
end
