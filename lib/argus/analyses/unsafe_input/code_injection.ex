defmodule Argus.Analyses.UnsafeInput.CodeInjection do
  @moduledoc "Findings for runtime callback content used as template source."
  alias Argus.Findings

  @spec output_relations() :: [Argus.Analysis.output_relation()]
  def output_relations do
    [
      %{
        name: :runtime_template_evaluation,
        fields: [
          {:source, :symbol, "runtime callback invocation"},
          {:source_func, :symbol, "function containing the callback invocation"},
          {:sink, :symbol, "template compiler instruction"},
          {:sink_func, :symbol, "function containing the template compiler"},
          {:api, :symbol, "template compiler API"}
        ],
        key: [:source, :sink],
        doc: "An unresolved callback's returned content reaches executable template source."
      }
    ]
  end

  @spec finding(atom(), [String.t()]) :: Findings.attrs()
  def finding(:runtime_template_evaluation, [source, source_func, sink, sink_func, api]) do
    Findings.new(
      :warning,
      "Runtime callback content evaluated as a template",
      "#{source_func} obtains content from a runtime callback and passes it to " <>
        "#{api} in #{sink_func} as template source. EEx compiles embedded Elixir " <>
        "expressions; if this content includes user input, it can execute that input. " <>
        "The callback's origin is known, but attacker control is not established.",
      at: Findings.at_instr(source),
      at_label: "runtime content produced here",
      related: [Findings.related("content compiled as template source", Findings.at_instr(sink))],
      help: [
        "use runtime callback content verbatim and evaluate only trusted templates",
        "pass untrusted values in bindings or assigns to a trusted literal template"
      ]
    )
  end
end
