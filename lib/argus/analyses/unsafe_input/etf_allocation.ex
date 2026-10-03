defmodule Argus.Analyses.UnsafeInput.EtfAllocation do
  @moduledoc "Findings for compressed ETF allocation independent of executable-term safety."

  alias Argus.Findings

  @spec output_relations() :: [Argus.Analysis.output_relation()]
  def output_relations do
    [
      %{
        name: :compressed_etf_from_input,
        fields: [
          {:id, :symbol, "ETF decoder instruction ID"},
          {:func, :symbol, "function containing the decoder"},
          {:api, :symbol, "ETF decoder API"}
        ],
        key: [:id],
        doc: "Caller-derived ETF bytes reach a decoder without excluding compressed input."
      }
    ]
  end

  @spec finding(atom(), [String.t()]) :: Findings.attrs()
  def finding(:compressed_etf_from_input, [id, func, api]) do
    Findings.new(
      :warning,
      "Compressed ETF allocation from external input",
      "#{func} passes bytes derived from an exported API's input to #{api}. " <>
        "Compressed ETF can allocate its full expanded term before [:safe] or " <>
        "non-executable-term validation runs. Limiting the compressed bytes alone " <>
        "does not bound that allocation.",
      at: Findings.at_instr(id),
      at_label: "ETF decoded before compressed input is excluded",
      help: [
        "reject the ETF compressed prefix <<131, 80, _::binary>> before decoding the same bytes",
        "also cap uncompressed input size before decoding; checking the decoded term is too late"
      ]
    )
  end
end
