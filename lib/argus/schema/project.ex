defmodule Argus.Schema.Project do
  @moduledoc """
  Layer-4 project facts, set by the frontend from what the build tool says about \
  the modules (`Argus.Project`) and exposed through `Argus.Schema`. No beam says \
  whose code it is: a module's facts are a function of its bytecode alone, shared \
  by every project that builds it. Without a project (`Argus.analyze/3` with no \
  `dependencies:`) every relation here is empty: every module is the program's own.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :dependency_module,
        layer: 4,
        fields: [{:mod, :symbol, "the module"}],
        doc: """
        A module of a dependency the build fetched, analyzed with the program \
        (`include_deps`). An application of the project's own is never one, though \
        its build analyzes it apart: an umbrella's other children are the program's \
        code, dependencies of the child analyzed only by the build's reckoning.
        """
      }
    ])
  end
end
