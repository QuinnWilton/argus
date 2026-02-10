defmodule Argus.Analyses.Loops do
  @moduledoc """
  Structured loop detection.

  Identifies loops via back-edges in the dominator tree and classifies them
  by BEAM-specific patterns: receive loops, recursive loops, and tail-recursive
  loops. Also computes loop membership, exits, nesting, and size.

  ## Output relations

  - `back_edge(source, target, func)` — CFG back-edge indicating a loop.
  - `loop_head(id, func)` — target of a back-edge (loop entry point).
  - `in_loop(id, head, func)` — instruction belongs to a loop body.
  - `loop_exit(from, to, head, func)` — edge leaving a loop.
  - `nested_loop(inner_head, outer_head, func)` — loop nesting.
  - `receive_loop(head, func)` — loop containing a receive.
  - `recursive_loop(head, func)` — loop containing a local call.
  - `tail_recursive_loop(head, func)` — loop containing a tail call.
  - `loop_size(head, func, count)` — number of instructions in a loop.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :loops

  @impl true
  def description, do: "structured loop detection and classification"

  @impl true
  def rules_file, do: "analyses/loops.dl"

  @impl true
  def extractors, do: []

  @impl true
  def output_relations do
    [
      %{
        name: :back_edge,
        fields: [
          {:source, :symbol, "back-edge source instruction ID"},
          {:target, :symbol, "back-edge target (loop head) instruction ID"},
          {:func, :symbol, "containing function ID"}
        ],
        doc: "CFG back-edge where target dominates source."
      },
      %{
        name: :loop_head,
        fields: [
          {:id, :symbol, "loop head instruction ID"},
          {:func, :symbol, "containing function ID"}
        ],
        doc: "Target of a back-edge (loop entry point)."
      },
      %{
        name: :in_loop,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:head, :symbol, "loop head instruction ID"},
          {:func, :symbol, "containing function ID"}
        ],
        doc: "Instruction belongs to a loop body."
      },
      %{
        name: :loop_exit,
        fields: [
          {:from, :symbol, "exit source instruction ID"},
          {:to, :symbol, "exit target instruction ID"},
          {:head, :symbol, "loop head instruction ID"},
          {:func, :symbol, "containing function ID"}
        ],
        doc: "CFG edge leaving a loop body."
      },
      %{
        name: :nested_loop,
        fields: [
          {:inner_head, :symbol, "inner loop head"},
          {:outer_head, :symbol, "outer loop head"},
          {:func, :symbol, "containing function ID"}
        ],
        doc: "Inner loop is nested within outer loop."
      },
      %{
        name: :receive_loop,
        fields: [
          {:head, :symbol, "loop head instruction ID"},
          {:func, :symbol, "containing function ID"}
        ],
        doc: "Loop containing a receive instruction."
      },
      %{
        name: :recursive_loop,
        fields: [
          {:head, :symbol, "loop head instruction ID"},
          {:func, :symbol, "containing function ID"}
        ],
        doc: "Loop containing a local call."
      },
      %{
        name: :tail_recursive_loop,
        fields: [
          {:head, :symbol, "loop head instruction ID"},
          {:func, :symbol, "containing function ID"}
        ],
        doc: "Loop containing a tail call."
      },
      %{
        name: :loop_size,
        fields: [
          {:head, :symbol, "loop head instruction ID"},
          {:func, :symbol, "containing function ID"},
          {:size, :number, "number of instructions in the loop"}
        ],
        doc: "Number of instructions in a loop body."
      }
    ]
  end
end
