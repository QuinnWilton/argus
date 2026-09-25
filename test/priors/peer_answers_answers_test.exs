defmodule Argus.Priors.Questions.PeerAnswersAnswersTest do
  @moduledoc """
  Jev's recorded answers to version 2 for seven real modules: the servers
  and receives blocking and startup ask about. A hook registry, the dets
  and code servers, rabbit's GUID server and `code_server:call/1`
  answer from inside the node at 0.8 and above; `dist_ac` (another
  node's application controller), a DBConnection pool (a free
  connection) and rabbit's disk monitor reading `df` do not.

  The requests are rebuilt from the recorded rows, so a change to what
  the question shows the model misses the cassette and fails here: a
  change in wording is a new prompt version and a new recording.
  """

  use ExUnit.Case, async: true

  alias Argus.Priors.{Cache, Driver}
  alias Argus.Priors.Questions.PeerAnswers

  @moduletag :tmp_dir

  @fixtures Path.expand("../fixtures/priors", __DIR__)

  setup %{tmp_dir: dir} do
    {:ok, 10} = Cache.import(dir, Path.join(@fixtures, "peer_answers_v2.jsonl"))
    {raw, _} = Code.eval_file(Path.join(@fixtures, "peer_answers_modules.exs"))

    {:ok, rows, stats} =
      Driver.derive(PeerAnswers, Argus.Facts.decode(raw), mode: :cached_only, cache_dir: dir)

    assert %{requests: 10, cached: 10, failed: 0} = stats

    %{
      rows:
        Map.new(rows, fn [kind, subject, peer, _pp, p] ->
          {{kind, subject}, {peer, String.to_integer(p)}}
        end)
    }
  end

  defp answers?(rows, key), do: elem(Map.fetch!(rows, key), 1) >= 800

  test "local services answer", %{rows: rows} do
    for key <- [
          {"server", ":ejabberd_hooks"},
          {"server", ":dets_server"},
          {"server", ":code_server"},
          {"server", ":rabbit_guid"},
          {"wait", ":code_server:call/1"}
        ] do
      assert answers?(rows, key), "#{inspect(key)}: #{inspect(rows[key])}"
    end
  end

  test "another node, a pool and an external command may not", %{rows: rows} do
    for key <- [
          {"server", ":dist_ac"},
          {"server", "DBConnection.ConnectionPool"},
          {"wait", ":rabbit_disk_monitor:get_reply/2"},
          {"wait", ":dist_ac:wait_dacs/4"}
        ] do
      refute answers?(rows, key), "#{inspect(key)}: #{inspect(rows[key])}"
    end

    assert {"remote", _} = rows[{"server", ":dist_ac"}]
    assert {"event", _} = rows[{"server", "DBConnection.ConnectionPool"}]
  end
end
