defmodule Argus.Priors.Questions.ValueSourceAnswersTest do
  @moduledoc """
  Jev's recorded answers to version 2 for eight real modules whose
  sinks no request reaches: what `unsafe_input`'s 0.9 re-tiers and what
  it leaves. A pool's, a cache's and a supervisor's names from start
  options, an Ecto type's stored term and a generator's argument clear
  0.9; tesla's Mint adapter making an atom of a URL's scheme (the shape
  of GHSA-h74c-q9j7-mpcm) and the boot server decoding a UDP request do
  not.

  The requests are rebuilt from the recorded rows, so a change to what
  the question shows the model misses the cassette and fails here: a
  change in wording is a new prompt version and a new recording.
  """

  use ExUnit.Case, async: true

  alias Argus.Priors.{Cache, Driver}
  alias Argus.Priors.Questions.ValueSource

  @moduletag :tmp_dir

  @fixtures Path.expand("../fixtures/priors", __DIR__)

  setup %{tmp_dir: dir} do
    {:ok, 8} = Cache.import(dir, Path.join(@fixtures, "value_source_v2.jsonl"))
    {raw, _} = Code.eval_file(Path.join(@fixtures, "value_source_modules.exs"))

    {:ok, rows, stats} =
      Driver.derive(ValueSource, Argus.Facts.decode(raw), mode: :cached_only, cache_dir: dir)

    assert %{requests: 8, cached: 8, failed: 0} = stats

    %{
      rows:
        Map.new(rows, fn [func, sink, source, _sp, p] ->
          {{func, sink}, {source, String.to_integer(p)}}
        end)
    }
  end

  defp retiered?(rows, key) do
    {_source, p} = Map.fetch!(rows, key)
    p >= 900
  end

  test "names from start options, a stored term and a generator's argument clear 0.9", %{
    rows: rows
  } do
    for key <- [
          {"Finch:pool_supervisor_name/1", "atom"},
          {"Finch:manager_name/1", "atom"},
          {"Cachex.Services.Janitor:start_link/1", "atom"},
          {"Ecto.Term:load/1", "deserialization"},
          {"Mix.Tasks.Phx.Gen.Context:put_context_app/2", "atom"}
        ] do
      assert retiered?(rows, key), "#{inspect(key)}: #{inspect(rows[key])}"
    end

    assert {"operator", _} = rows[{"Mix.Tasks.Phx.Gen.Context:put_context_app/2", "atom"}]
    assert {"stored", _} = rows[{"Ecto.Term:load/1", "deserialization"}]
  end

  test "a URL's scheme and a boot request are left as they are", %{rows: rows} do
    refute retiered?(rows, {"Tesla.Adapter.Mint:open_conn/2", "atom"})
    refute retiered?(rows, {":erl_boot_server:handle_command/3", "deserialization"})
    assert {"outside", _} = rows[{":erl_boot_server:handle_command/3", "deserialization"}]
  end
end
