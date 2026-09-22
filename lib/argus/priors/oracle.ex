defmodule Argus.Priors.Oracle do
  @moduledoc """
  What answers a prior's questions.

  A request is `%{model, state, questions}` in the shape of typesafe.ai's
  System-One API (`Argus.Priors.Jev` speaks it): `state` is text or JSON
  the questions are about, and each question is a `choice`, `score` or
  `noul` evaluated independently against that state. The answers come
  back under the question ids.

  The behaviour exists so that a test, or a run without network, can
  answer from a table: `Argus.Priors.Driver` asks whatever it is given.
  """

  @type request :: %{model: String.t(), state: map(), questions: map()}

  @type response :: %{
          answers: %{String.t() => map()},
          usage: %{String.t() => non_neg_integer()},
          model: String.t() | nil,
          request_id: String.t() | nil
        }

  @doc "Answers one request. `opts` are the oracle's own."
  @callback ask(request(), keyword()) :: {:ok, response()} | {:error, term()}
end
