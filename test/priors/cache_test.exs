defmodule Argus.Priors.CacheTest do
  use ExUnit.Case, async: true

  alias Argus.Priors.Cache

  @moduletag :tmp_dir

  @generation %{
    model: "jev-1.13.0",
    question: "Elixir.Argus.Priors.Questions.Sensitivity",
    prompt_version: 1
  }
  @request %{
    model: "jev-1.13.0",
    state: %{schema_module: "M", fields: ["a", "b"]},
    questions: %{"kind__0" => %{type: "choice"}}
  }
  @response %{
    "answers" => %{"kind__0" => %{"choice" => "none", "probabilities" => %{"none" => 1.0}}},
    "usage" => %{"input_tokens" => 12}
  }

  test "the key ignores map ordering and atom-vs-string keys" do
    a = Cache.key(@generation, @request)

    b =
      Cache.key(@generation, %{
        "questions" => %{"kind__0" => %{"type" => "choice"}},
        "state" => %{"fields" => ["a", "b"], "schema_module" => "M"},
        "model" => "jev-1.13.0"
      })

    assert a == b
    assert String.length(a) == 64
  end

  test "the key changes with the generation and with the request" do
    base = Cache.key(@generation, @request)
    assert base != Cache.key(%{@generation | prompt_version: 2}, @request)
    assert base != Cache.key(%{@generation | model: "jev-2.0.0"}, @request)
    assert base != Cache.key(@generation, put_in(@request, [:state, :fields], ["a", "c"]))
  end

  test "put then get round-trips through JSON", %{tmp_dir: dir} do
    key = Cache.key(@generation, @request)
    assert Cache.get(dir, @generation, key) == :miss
    assert :ok = Cache.put(dir, @generation, key, @request, @response)
    assert {:ok, entry} = Cache.get(dir, @generation, key)
    assert entry.key == key
    assert entry.generation == @generation
    assert entry.response == @response
    assert entry.request["state"]["schema_module"] == "M"
  end

  test "entries are grouped by generation directory", %{tmp_dir: dir} do
    :ok = Cache.put(dir, @generation, "k1", @request, @response)
    :ok = Cache.put(dir, %{@generation | prompt_version: 2}, "k2", @request, @response)

    assert %{"jev-1.13.0--Sensitivity--v1" => [_], "jev-1.13.0--Sensitivity--v2" => [_]} =
             Cache.entries(dir)
  end

  test "clear removes one generation or all", %{tmp_dir: dir} do
    :ok = Cache.put(dir, @generation, "k1", @request, @response)
    :ok = Cache.put(dir, %{@generation | prompt_version: 2}, "k2", @request, @response)

    assert {:ok, 1} = Cache.clear(dir, generation: "jev-1.13.0--Sensitivity--v1")
    assert Cache.get(dir, @generation, "k1") == :miss
    assert {:ok, 1} = Cache.clear(dir)
    assert Cache.entries(dir) == %{}
  end

  test "export writes a cassette that import reads back", %{tmp_dir: dir} do
    :ok = Cache.put(dir, @generation, "k1", @request, @response)
    :ok = Cache.put(dir, @generation, "k2", @request, @response)
    cassette = Path.join(dir, "out/priors.jsonl")

    assert {:ok, 1} = Cache.export(dir, cassette, keys: ["k2"])
    assert cassette |> File.read!() |> String.split("\n", trim: true) |> length() == 1

    other = Path.join(dir, "other")
    assert {:ok, 1} = Cache.import(other, cassette)
    assert {:ok, entry} = Cache.get(other, @generation, "k2")
    assert entry.response == @response
    assert Cache.get(other, @generation, "k1") == :miss
  end
end
