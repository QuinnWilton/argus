defmodule Scry.Test.PriorOracle do
  @moduledoc """
  An `Argus.Priors.Oracle` for tests: every choice is its first
  criterion at 0.5, every noul is `:noul` (default 0.1), and each request
  appends a line to `:log`, so a test can see whether the cache or the
  oracle answered.
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
            first = q.criteria |> Map.keys() |> Enum.sort() |> List.first() |> to_string()

            {id,
             %{
               "type" => "choice",
               "choice" => first,
               "confidence" => 0.5,
               "probabilities" => %{first => 0.5}
             }}

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
end
