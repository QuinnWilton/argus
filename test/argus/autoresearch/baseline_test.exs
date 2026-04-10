defmodule Argus.Autoresearch.BaselineTest do
  use ExUnit.Case, async: true

  alias Argus.Autoresearch.{Baseline, Snapshot}

  @moduletag :tmp_dir

  defp make_snapshot do
    # Build a minimal snapshot using the public constructor.
    Snapshot.from_reports(
      [{"fake", %{"analyses" => %{"coverage" => %{"findings" => %{}}}}}],
      tier: "fast",
      argus_git_sha: "abcdef1"
    )
  end

  describe "exists?/1" do
    test "returns false when baseline directory is empty", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "baseline")
      refute Baseline.exists?(dir)
    end

    test "returns true after a successful promote", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "baseline")
      assert :ok = Baseline.promote(make_snapshot(), dir: dir)
      assert Baseline.exists?(dir)
    end
  end

  describe "promote/2 and read/1" do
    test "writes snapshot.json and metadata.json atomically", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "baseline")
      snap = make_snapshot()

      assert :ok = Baseline.promote(snap, dir: dir, note: "initial")
      assert File.exists?(Baseline.snapshot_path(dir))
      assert File.exists?(Baseline.metadata_path(dir))

      assert {:ok, restored} = Baseline.read(dir)
      assert restored == snap
    end

    test "metadata includes sha, tier, created_at, and note", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "baseline")
      assert :ok = Baseline.promote(make_snapshot(), dir: dir, note: "first run")

      assert {:ok, meta} = Baseline.metadata(dir)
      assert meta.argus_git_sha == "abcdef1"
      assert meta.tier == "fast"
      assert meta.note == "first run"
      assert is_binary(meta.created_at)
    end

    test "promote overwrites an existing baseline", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "baseline")

      first =
        Snapshot.from_reports([{"a", %{"analyses" => %{}}}],
          tier: "fast",
          argus_git_sha: "sha1"
        )

      second =
        Snapshot.from_reports([{"b", %{"analyses" => %{}}}],
          tier: "fast",
          argus_git_sha: "sha2"
        )

      assert :ok = Baseline.promote(first, dir: dir)
      assert :ok = Baseline.promote(second, dir: dir)

      assert {:ok, restored} = Baseline.read(dir)
      assert restored.argus_git_sha == "sha2"
      assert restored.projects == ["b"]
    end

    test "read returns :no_baseline when snapshot file is missing", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "baseline")
      File.mkdir_p!(dir)

      assert {:error, :no_baseline} = Baseline.read(dir)
    end

    test "metadata returns :no_baseline when file is missing", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "baseline")
      assert {:error, :no_baseline} = Baseline.metadata(dir)
    end
  end

  describe "canary fixture" do
    test "write_canary/2 and read_canary/1 round-trip", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "baseline")

      fixture = %{
        "supervision" => 3,
        "one_for_one_coupling" => 0,
        "atom_safety" => 1
      }

      assert :ok = Baseline.write_canary(fixture, dir)
      assert File.exists?(Baseline.canary_path(dir))

      assert {:ok, restored} = Baseline.read_canary(dir)
      assert restored == fixture
    end

    test "read_canary returns :no_canary when file is missing", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "baseline")
      assert {:error, :no_canary} = Baseline.read_canary(dir)
    end
  end
end
