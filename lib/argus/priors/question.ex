defmodule Argus.Priors.Question do
  @moduledoc """
  One question family: which subjects to ask about, what to show the
  model, what to ask, and how an answer becomes rows of one prior
  relation.

  A question is asked about the residue — the subjects the structural
  facts cannot decide — and about nothing else; `subjects/1` is where
  that judgement lives. The state handed to the model is names: modules,
  functions, fields, literals, behaviours. Never instruction ids, labels,
  hashes or line numbers, which the model reads as noise, and never more
  than the question is about: unrelated state measurably lowers accuracy.

  Subjects sharing a `batch_key` ride in one request with a shared state
  and one set of questions each, suffixed by their index; the model
  charges state once per request, and a schema seen whole is better
  context for each of its fields than a field seen alone.

  `prompt_version/0` is part of every cache key: a change in wording or
  criteria is a new generation, and old answers stop being hits.
  """

  @type subject :: %{
          required(:id) => term(),
          required(:batch_key) => term(),
          required(:state) => map()
        }

  @doc "The prior relation the rows fill; a `layer: 3` relation in `Argus.Schema`."
  @callback relation() :: atom()

  @doc "Bumped whenever `state/1` or `questions/1` change what the model sees."
  @callback prompt_version() :: pos_integer()

  @doc "The fact relations `subjects/1` reads."
  @callback relations_read() :: [atom()]

  @doc "The residue: the subjects worth a question, with their per-subject state."
  @callback subjects(facts :: Argus.Facts.t()) :: [subject()]

  @doc "The shared state for subjects with one `batch_key`."
  @callback state([subject()]) :: map()

  @doc "The questions for those subjects, ids suffixed `__i` by position."
  @callback questions([subject()]) :: %{String.t() => map()}

  @doc "Rows of `relation/0` from the answers; a subject the answers omit yields none."
  @callback rows([subject()], answers :: %{String.t() => map()}) :: [[String.t()]]
end
