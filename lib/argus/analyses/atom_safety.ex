defmodule Argus.Analyses.AtomSafety do
  @moduledoc """
  Atom safety analysis.

  Detects unsafe atom creation reachable from exported functions, atom creation
  in loops, unsafe deserialization, and dynamic code execution. The BEAM atom
  table is fixed-size and never garbage collected, making any path converting
  untrusted input to atoms a denial-of-service vector.

  ## Output relations

  All three relations are anchored at the offending call SITE — `id` is
  the instruction, `func` the function containing it.

  - `atom_exhaustion_risk(id, func, api)` — unsafe atom creation reachable from an exported function.
  - `unsafe_deserialization_finding(id, func, api)` — `binary_to_term` without `:safe` option.
  - `code_injection_risk(id, func, api)` — `Code.eval_string` / `:os.cmd` reachable from exports.

  ## Finding severities

  - `atom_exhaustion_risk` — `:warning`. Whether the input is attacker
    influenced can't be decided statically; when it is, this is a
    node-killing DoS.
  - `unsafe_deserialization_finding` — `:error`. `binary_to_term` without
    `:safe` on untrusted bytes interns unbounded atoms and materializes
    funs/ports/refs — a known remote DoS vector.
  - `code_injection_risk` — `:error`. Dynamic evaluation reachable from
    the module's public surface is arbitrary code execution if any
    caller-controlled data flows in.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

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
        fields: [
          {:id, :symbol, "instruction ID of the unsafe call"},
          {:func, :symbol, "function containing the unsafe atom creation"},
          {:api, :symbol, "API"}
        ],
        doc: "Unsafe atom creation reachable from an exported function."
      },
      %{
        name: :unsafe_deserialization_finding,
        fields: [
          {:id, :symbol, "instruction ID of the call"},
          {:func, :symbol, "function"},
          {:api, :symbol, "API"}
        ],
        doc: "binary_to_term without :safe option."
      },
      %{
        name: :code_injection_risk,
        fields: [
          {:id, :symbol, "instruction ID of the call"},
          {:func, :symbol, "function"},
          {:api, :symbol, "API"}
        ],
        doc: "Dynamic code execution reachable from exports."
      }
    ]
  end

  @impl true
  def finding(:atom_exhaustion_risk, [id, func, api]) do
    Findings.new(
      :warning,
      "Dynamic atom creation reachable from an exported function",
      "#{func} calls #{api}, and the module's public surface reaches it. The " <>
        "BEAM atom table is never garbage collected (default cap 1,048,576 " <>
        "entries); if caller-influenced input reaches this call, every new " <>
        "value permanently consumes a slot until the node dies. Prefer " <>
        "String.to_existing_atom or an explicit whitelist.",
      at: Findings.at_instr(id)
    )
  end

  def finding(:unsafe_deserialization_finding, [id, func, api]) do
    Findings.new(
      :error,
      "binary_to_term without :safe",
      "#{func} deserializes with #{api} and no :safe option. Untrusted bytes " <>
        "can intern unbounded atoms and materialize funs, ports, and " <>
        "references — a well-known denial-of-service vector. Pass [:safe] and " <>
        "validate the decoded shape.",
      at: Findings.at_instr(id)
    )
  end

  def finding(:code_injection_risk, [id, func, api]) do
    Findings.new(
      :error,
      "Dynamic code execution reachable from exports",
      "#{func} calls #{api}, reachable from an exported function. If any " <>
        "caller-controlled data flows into that call, it is arbitrary code " <>
        "execution inside the node.",
      at: Findings.at_instr(id)
    )
  end
end
