defmodule Argus.Autoresearch.ConfigTest do
  use ExUnit.Case, async: true

  alias Argus.Autoresearch.Config

  @moduletag :tmp_dir

  defp write_config(path, content) do
    File.write!(path, content)
  end

  defp mkproject(path) do
    File.mkdir_p!(path)
    File.write!(Path.join(path, "mix.exs"), "defmodule Project.MixProject do end")
  end

  describe "from_map/1" do
    test "parses a valid config map" do
      raw = %{
        corpus_root: "/tmp/fake_corpus",
        tiers: %{"fast" => ["a", "b"]},
        default_tier: "fast",
        canary_project: "a",
        checks_barrier: [["mix", ["test"]]],
        measure_concurrency: 2,
        measure_timeout_s: 60
      }

      assert {:ok, config} = Config.from_map(raw)
      assert config.corpus_root == Path.expand("/tmp/fake_corpus")
      assert config.tiers == %{"fast" => ["a", "b"]}
      assert config.default_tier == "fast"
      assert config.canary_project == "a"
      assert config.measure_concurrency == 2
    end

    test "accepts :all as a tier value" do
      raw = %{
        corpus_root: "/tmp/c",
        tiers: %{"full" => :all, "fast" => ["x"]},
        default_tier: "fast"
      }

      assert {:ok, config} = Config.from_map(raw)
      assert config.tiers["full"] == :all
    end

    test "uses defaults for concurrency and timeout when absent" do
      raw = %{
        corpus_root: "/tmp/c",
        tiers: %{"fast" => []},
        default_tier: "fast"
      }

      assert {:ok, config} = Config.from_map(raw)
      assert config.measure_concurrency == 4
      assert config.measure_timeout_s == 300
    end

    test "rejects missing corpus_root" do
      raw = %{tiers: %{"fast" => []}, default_tier: "fast"}
      assert {:error, {:invalid, _}} = Config.from_map(raw)
    end

    test "rejects missing tiers" do
      raw = %{corpus_root: "/tmp/c", default_tier: "fast"}
      assert {:error, {:invalid, _}} = Config.from_map(raw)
    end

    test "rejects default_tier not in tiers" do
      raw = %{
        corpus_root: "/tmp/c",
        tiers: %{"fast" => []},
        default_tier: "medium"
      }

      assert {:error, {:invalid, reason}} = Config.from_map(raw)
      assert reason =~ "default_tier"
    end

    test "rejects tier values that aren't lists of strings or :all" do
      raw = %{
        corpus_root: "/tmp/c",
        tiers: %{"fast" => [:atom_not_string]},
        default_tier: "fast"
      }

      assert {:error, {:invalid, _}} = Config.from_map(raw)
    end

    test "rejects malformed checks_barrier entries" do
      raw = %{
        corpus_root: "/tmp/c",
        tiers: %{"fast" => []},
        default_tier: "fast",
        checks_barrier: ["not_a_list"]
      }

      assert {:error, {:invalid, _}} = Config.from_map(raw)
    end

    test "rejects non-map input" do
      assert {:error, {:invalid, :not_a_map}} = Config.from_map([])
    end
  end

  describe "load/1" do
    test "loads a valid config file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config.exs")

      write_config(path, """
      %{
        corpus_root: "/tmp/fake",
        tiers: %{"fast" => ~w(a b)},
        default_tier: "fast"
      }
      """)

      assert {:ok, config} = Config.load(path)
      assert config.tiers == %{"fast" => ["a", "b"]}
    end

    test "returns enoent for missing file" do
      assert {:error, :enoent} = Config.load("/nonexistent/config.exs")
    end

    test "returns an error on Elixir eval failure", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config.exs")
      write_config(path, "this is not valid elixir {")

      assert {:error, {:eval_failed, _}} = Config.load(path)
    end
  end

  describe "resolve_tier/2" do
    test "resolves explicit project names against corpus_root", %{tmp_dir: tmp_dir} do
      mkproject(Path.join(tmp_dir, "a"))
      mkproject(Path.join(tmp_dir, "b"))

      config = %Config{
        corpus_root: tmp_dir,
        tiers: %{"fast" => ["a", "b"]},
        default_tier: "fast"
      }

      assert {:ok, resolved} = Config.resolve_tier(config, "fast")
      assert [{"a", _}, {"b", _}] = resolved

      for {_name, path} <- resolved do
        assert File.dir?(path)
      end
    end

    test "returns nil paths for missing projects without failing", %{tmp_dir: tmp_dir} do
      mkproject(Path.join(tmp_dir, "a"))
      # "b" does not exist

      config = %Config{
        corpus_root: tmp_dir,
        tiers: %{"fast" => ["a", "b"]},
        default_tier: "fast"
      }

      assert {:ok, [{"a", path_a}, {"b", nil}]} = Config.resolve_tier(config, "fast")
      assert File.dir?(path_a)
    end

    test "resolves :all to every project dir under corpus_root", %{tmp_dir: tmp_dir} do
      mkproject(Path.join(tmp_dir, "alpha"))
      mkproject(Path.join(tmp_dir, "beta"))
      # A non-project dir should be excluded.
      File.mkdir_p!(Path.join(tmp_dir, "not_a_project"))

      config = %Config{
        corpus_root: tmp_dir,
        tiers: %{"full" => :all},
        default_tier: "full"
      }

      assert {:ok, resolved} = Config.resolve_tier(config, "full")
      names = Enum.map(resolved, fn {name, _} -> name end)
      assert "alpha" in names
      assert "beta" in names
      refute "not_a_project" in names
    end

    test "errors on unknown tier", %{tmp_dir: tmp_dir} do
      config = %Config{corpus_root: tmp_dir, tiers: %{"fast" => []}, default_tier: "fast"}
      assert {:error, {:unknown_tier, "medium"}} = Config.resolve_tier(config, "medium")
    end

    test "errors when corpus_root does not exist" do
      config = %Config{
        corpus_root: "/definitely/does/not/exist",
        tiers: %{"fast" => ["a"]},
        default_tier: "fast"
      }

      assert {:error, {:corpus_root_missing, _}} = Config.resolve_tier(config, "fast")
    end
  end
end
