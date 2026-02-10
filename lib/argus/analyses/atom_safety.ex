defmodule Argus.Analyses.AtomSafety do
  @moduledoc """
  Atom safety analysis.

  Detects unsafe atom creation reachable from exported functions, atom creation
  in loops, unsafe deserialization, and dynamic code execution. The BEAM atom
  table is fixed-size and never garbage collected, making any path converting
  untrusted input to atoms a denial-of-service vector.

  ## Output relations

  - `atom_exhaustion_risk(func, api)` — unsafe atom creation reachable from exported function.
  - `unsafe_deserialization_finding(func, api)` — `binary_to_term` without `:safe` option.
  - `code_injection_risk(func, api)` — `Code.eval_string` / `:os.cmd` reachable from exports.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :atom_safety

  @impl true
  def description,
    do: "Atom table exhaustion, unsafe deserialization, and code injection detection"

  @impl true
  def rules_file, do: "analyses/atom_safety.dl"

  @impl true
  def extractors, do: [Argus.Extractors.AtomSafety]

  @impl true
  def output_relations do
    [
      %{
        name: :atom_exhaustion_risk,
        fields: [{:func, :symbol, "function with unsafe atom creation"}, {:api, :symbol, "API"}],
        doc: "Unsafe atom creation reachable from an exported function."
      },
      %{
        name: :unsafe_deserialization_finding,
        fields: [{:func, :symbol, "function"}, {:api, :symbol, "API"}],
        doc: "binary_to_term without :safe option."
      },
      %{
        name: :code_injection_risk,
        fields: [{:func, :symbol, "function"}, {:api, :symbol, "API"}],
        doc: "Dynamic code execution reachable from exports."
      }
    ]
  end
end
