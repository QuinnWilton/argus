defmodule Argus.Souffle do
  @moduledoc """
  Behaviour for executing Souffle Datalog programs.

  Implementations receive a facts directory, a rules file path, and options,
  then return the derived relations as a map of relation name to rows.
  """

  @type result :: %{String.t() => [[String.t()]]}

  @callback run(facts_dir :: Path.t(), rules_path :: Path.t(), opts :: keyword()) ::
              {:ok, result()} | {:error, term()}
end
