defmodule Argus.Test.PriorOracle do
  @moduledoc """
  An `Argus.Priors.Oracle` for tests: every choice is its first
  criterion at 0.5, every noul is `:noul` (default 0.1), and each request
  appends a line to `:log`, so a test can see whether the cache or the
  oracle answered.

  `choose: criterion` answers every choice offering that criterion with
  it, at probability `:choose_p` (default 0.95) — a confident answer, the
  kind a consumer re-tiers a finding on.
  """

  @behaviour Argus.Priors.Oracle

  @impl true
  def ask(request, opts) do
    if log = Keyword.get(opts, :log) do
      File.write!(log, [inspect(map_size(request.questions)), "\n"], [:append])
    end

    answers =
      for {id, q} <- request.questions, into: %{} do
        case q.type do
          "noul" ->
            {id, %{"type" => "noul", "noul" => Keyword.get(opts, :noul, 0.1)}}

          "choice" ->
            {id, choice(q, opts)}

          "score" ->
            {id,
             %{
               "type" => "score",
               "score" => 1.0,
               "confidence" => 0.5,
               "probabilities" => %{"1" => 1.0}
             }}
        end
      end

    {:ok,
     %{answers: answers, usage: %{"input_tokens" => 10}, model: request.model, request_id: nil}}
  end

  defp choice(q, opts) do
    criteria = q.criteria |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    chosen = opts |> Keyword.get(:choose) |> then(&(&1 && to_string(&1)))

    if chosen in criteria do
      p = Keyword.get(opts, :choose_p, 0.95)
      rest = (1 - p) / max(length(criteria) - 1, 1)

      %{
        "type" => "choice",
        "choice" => chosen,
        "confidence" => p,
        "probabilities" => Map.new(criteria, &{&1, if(&1 == chosen, do: p, else: rest)})
      }
    else
      first = List.first(criteria)

      %{
        "type" => "choice",
        "choice" => first,
        "confidence" => 0.5,
        "probabilities" => %{first => 0.5}
      }
    end
  end
end
