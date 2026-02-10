defmodule Argus.Analyses.UnsafeTask do
  @moduledoc """
  Unsafe task usage detection.

  Detects two patterns that commonly cause production issues:

  1. **Leaked async tasks** — `Task.async` or `Task.Supervisor.async_nolink`
     calls in functions that never await/yield the result, directly or
     transitively through the call graph.

  2. **Unchecked start_child** — `Task.Supervisor.start_child` calls where
     the result is discarded without error handling. The call is not in tail
     position and no branch instruction follows it, indicating the `{:ok, pid}`
     / `{:error, reason}` result is ignored.

  Suppresses `leaked_async_task` for GenServer modules with `handle_info/2`,
  which consume task results through their mailbox rather than explicit
  await/yield.

  Requires the OTP extractor for `implements_behaviour` facts.

  ## Output relations

  - `leaked_async_task(func, id)` — async task created but never awaited.
  - `unchecked_start_child(func, id)` — start_child result not checked.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :unsafe_task

  @impl true
  def description, do: "leaked async tasks and unchecked Task.Supervisor.start_child"

  @impl true
  def rules_file, do: "unsafe_task.dl"

  @impl true
  def extractors, do: [Argus.Extractors.OTP]

  @impl true
  def output_relations do
    [
      %{
        name: :leaked_async_task,
        fields: [
          {:func, :symbol, "function containing the async call"},
          {:id, :symbol, "instruction ID of the Task.async call"}
        ],
        doc: "Task.async or async_nolink call without corresponding await/yield."
      },
      %{
        name: :unchecked_start_child,
        fields: [
          {:func, :symbol, "function containing the start_child call"},
          {:id, :symbol, "instruction ID of the start_child call"}
        ],
        doc: "Task.Supervisor.start_child result discarded without error handling."
      }
    ]
  end
end
