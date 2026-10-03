defmodule Argus.Analyses.UnsafeInput.HtmlInjection do
  @moduledoc "Findings for caller-supplied values emitted as unescaped HTML."

  alias Argus.Findings

  @spec output_relations() :: [Argus.Analysis.output_relation()]
  def output_relations do
    [
      %{
        name: :unescaped_html_from_input,
        fields: [
          {:id, :symbol, "raw HTML output instruction ID"},
          {:func, :symbol, "function containing the output"},
          {:api, :symbol, "raw HTML output API"}
        ],
        key: [:id],
        doc: "Caller-derived text reaches raw HTML without an escaping proof for those bytes."
      }
    ]
  end

  @spec finding(atom(), [String.t()]) :: Findings.attrs()
  def finding(:unescaped_html_from_input, [id, func, api]) do
    Findings.new(
      :warning,
      "Unescaped data rendered as HTML",
      "#{func} passes content derived from an exported API's input to #{api} " <>
        "without a matching HTML-text escaping step. Render assigns can contain " <>
        "stored user-authored labels as well as request data; if the value contains " <>
        "untrusted markup, the browser may execute it. This flow does not establish " <>
        "that every caller supplies attacker-controlled content.",
      at: Findings.at_instr(id),
      at_label: "input emitted as raw HTML",
      help: [
        "HTML-escape the same text before marking it raw or adding static highlighting",
        "use encoding appropriate to the output context; regex escaping does not escape HTML"
      ]
    )
  end
end
