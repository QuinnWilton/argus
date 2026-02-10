defmodule Argus.Analyses.CallgraphCtx do
  @moduledoc """
  Context-sensitive call graph with 1-call-site sensitivity.

  Extends the basic call graph with call site information, enabling analyses
  to distinguish different call sites within the same function. Also provides
  call site fan-out (for detecting dynamic dispatch) and context-sensitive
  reachability.

  ## Output relations

  - `call_edge_ctx(caller, callee, site)` — call edge with call site ID.
  - `call_edge(caller, callee)` — context-insensitive projection.
  - `call_site_fan_out(site, fan_out)` — number of callees per call site.
  - `function_call_site_count(func, n)` — call sites per function.
  - `call_reachable_ctx(from, to, origin_site)` — transitive reachability
    tracking the originating call site.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :callgraph_ctx

  @impl true
  def description, do: "context-sensitive call graph (1-call-site sensitivity)"

  @impl true
  def rules_file, do: "analyses/callgraph_ctx.dl"

  @impl true
  def extractors, do: []

  @impl true
  def output_relations do
    [
      %{
        name: :call_edge_ctx,
        fields: [
          {:caller, :symbol, "calling function ID"},
          {:callee, :symbol, "called function or MFA string"},
          {:site, :symbol, "call site instruction ID"}
        ],
        doc: "Call graph edge with call site context."
      },
      %{
        name: :call_edge,
        fields: [
          {:caller, :symbol, "calling function ID"},
          {:callee, :symbol, "called function or MFA string"}
        ],
        doc: "Context-insensitive call graph edge (projection)."
      },
      %{
        name: :call_site_fan_out,
        fields: [
          {:site, :symbol, "call site instruction ID"},
          {:fan_out, :number, "number of distinct callees"}
        ],
        doc: "Number of distinct callees at a call site."
      },
      %{
        name: :function_call_site_count,
        fields: [
          {:func, :symbol, "function ID"},
          {:n, :number, "number of call sites"}
        ],
        doc: "Number of distinct call sites in a function."
      },
      %{
        name: :call_reachable_ctx,
        fields: [
          {:from, :symbol, "source function ID"},
          {:to, :symbol, "reachable function or MFA string"},
          {:origin_site, :symbol, "originating call site instruction ID"}
        ],
        doc: "Transitive call reachability tracking the initial call site."
      }
    ]
  end
end
