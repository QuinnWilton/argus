defmodule Argus.Schema.HtmlInjection do
  @moduledoc "Raw HTML output sites and context-specific escaping proofs."

  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :html_output_site,
        layer: 2,
        fields: [
          {:id, :symbol, "HTML output call instruction ID"},
          {:func, :symbol, "calling function ID"},
          {:api, :symbol, "raw HTML API"},
          {:pos, :number, "zero-based argument containing HTML"}
        ],
        doc: """
        Raw HTML marking or an HTML response body. A send_resp call qualifies only \
        when this connection is the returned value of a known HTML content-type \
        setter. This relation makes no assertion about attacker control.
        """
      },
      %{
        name: :html_input_escaped,
        layer: 2,
        fields: [
          {:id, :symbol, "HTML output call instruction ID"},
          {:func, :symbol, "calling function ID"},
          {:pos, :number, "zero-based HTML argument position"}
        ],
        doc: """
        Every reaching argument is safe in its modeled output context: HTML text \
        escaping with inert inline highlighting, a fully checked JavaScript string \
        inside a script. Named external renderers do not establish safety. \
        Proofs follow local returns and all known private callers. Regex escaping, \
        unchecked safe tuples, unknown callers, and context-inappropriate escaping \
        do not establish safety.
        """
      }
    ])
  end
end
