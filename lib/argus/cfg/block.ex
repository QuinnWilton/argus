defmodule Argus.Cfg.Block do
  @moduledoc """
  One basic block: a maximal straight-line run of instructions with a single
  entry (the leader) and a single exit (the terminator).

  `range` is the inclusive instruction-index span within the function's raw
  beam_disasm stream (the same indexing as `Argus.InstrId.idx`, including
  `label`/`line` pseudo-instructions).
  """

  @enforce_keys [:id, :range]
  defstruct [:id, :range, :label, preds: [], succs: [], terminator: :fallthrough]

  @type id :: non_neg_integer()

  @typedoc """
  Why control leaves this block:

  - `:return` / `:tail_call` — leaves the function entirely.
  - `:raise` — raises (badmatch/case_end/if_end/try_case_end/raw_raise).
  - `:jump` — unconditional transfer (includes loop_rec_end/wait loop-backs).
  - `:branch` — two-way conditional (a test, a fail-labelled op, or
    receive-loop control).
  - `:select` — multi-way select_val/select_tuple_arity dispatch.
  - `:exception` — installs a handler (try/catch) and falls through.
  - `:fallthrough` — the block ends only because the next instruction is a
    leader (a jump target).
  """
  @type terminator ::
          :return | :tail_call | :raise | :jump | :branch | :select | :exception | :fallthrough

  @typedoc """
  The kind of a control-flow edge between blocks.

  `:branch_fail` is the branch's label edge (a test's fail edge);
  `:branch_pass` is its fallthrough. `{:select_arm, value}` carries the
  matched value as the emitter stringified it; `:select_fail` is the select's
  default. `:exception` is a try/catch handler edge.
  """
  @type edge_kind ::
          :fallthrough
          | :jump
          | :branch_pass
          | :branch_fail
          | {:select_arm, String.t()}
          | :select_fail
          | :exception

  @type t :: %__MODULE__{
          id: id(),
          range: {non_neg_integer(), non_neg_integer()},
          label: non_neg_integer() | nil,
          preds: [{id(), edge_kind()}],
          succs: [{id(), edge_kind()}],
          terminator: terminator()
        }
end
