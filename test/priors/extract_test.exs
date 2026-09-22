defmodule Argus.Priors.ExtractTest do
  @moduledoc """
  `Argus.Analysis.extract_facts/3` derives the priors into the facts
  directory it stages, after stage 0, or leaves the relation empty.
  """

  use ExUnit.Case

  alias Argus.{Analysis, Souffle}
  alias Argus.Test.Fixtures.Secret, as: S

  @moduletag :tmp_dir

  defmodule Oracle do
    @behaviour Argus.Priors.Oracle

    @impl true
    def ask(request, _opts) do
      answers =
        for {id, %{type: "choice"}} <- request.questions, into: %{} do
          {id,
           %{
             "type" => "choice",
             "choice" => "credential",
             "confidence" => 0.9,
             "probabilities" => %{"credential" => 0.91}
           }}
        end

      {:ok,
       %{answers: answers, usage: %{"input_tokens" => 10}, model: request.model, request_id: nil}}
    end
  end

  defmodule Broken do
    @behaviour Argus.Priors.Oracle
    @impl true
    def ask(_request, _opts), do: {:error, :down}
  end

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp rows(dir) do
    dir
    |> Path.join("prior_sensitive.facts")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, "\t"))
  end

  test "priors off: the relation's file exists and is empty" do
    skip_without_souffle()
    {:ok, dir} = Analysis.extract_facts([S.Heuristic], [:exposure])
    assert rows(dir) == []
  end

  test "priors on: the relation holds the question's rows", %{tmp_dir: cache} do
    skip_without_souffle()

    {:ok, dir} =
      Analysis.extract_facts([S.Heuristic], [:exposure],
        priors: :live,
        priors_opts: [oracle: Oracle, cache_dir: cache, model: "jev-test"]
      )

    assert rows(dir) == [
             ["schema_field", inspect(S.Heuristic), ":id", "secret", "credential", "910"],
             ["schema_field", inspect(S.Heuristic), ":label", "secret", "credential", "910"],
             ["schema_field", inspect(S.Heuristic), ":totp_seed", "secret", "credential", "910"]
           ]
  end

  test "an oracle that fails leaves the relation empty and extraction succeeds", %{tmp_dir: cache} do
    skip_without_souffle()

    {:ok, dir} =
      Analysis.extract_facts([S.Heuristic], [:exposure],
        priors: :live,
        priors_opts: [oracle: Broken, cache_dir: cache, model: "jev-test"]
      )

    assert rows(dir) == []
    assert File.exists?(Path.join(dir, "call_edge.facts"))
  end
end
