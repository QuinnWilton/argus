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

  Suppresses `leaked_async_task` for process modules with message-receiving
  callbacks (GenServer, LiveView, LiveComponent, gen_statem) that consume
  task results through their mailbox rather than explicit await/yield.
  Also recognizes `Task.shutdown/1,2` as a valid way to consume a task.

  Requires the OTP extractor for `implements_behaviour` facts.

  ## Output relations

  - `leaked_async_task(func, id)` — async task created but never awaited.
  - `unchecked_start_child(func, id)` — start_child result not checked.

  ## Finding severities

  Both relations are `:warning`: leaked tasks crash their caller or pile
  up unread result messages; unchecked starts make failed launches look
  like success. Neither is a guaranteed failure on every execution.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :unsafe_task

  @impl true
  def description, do: "leaked async tasks and unchecked Task.Supervisor.start_child"

  @impl true
  def rules_file, do: "analyses/unsafe_task.dl"

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

  @impl true
  def finding(:leaked_async_task, [func, id]) do
    Findings.new(
      :warning,
      "Async task never awaited",
      "#{func} starts a task with Task.async (or async_nolink) but nothing " <>
        "awaits or yields it. Task.async links to the caller and always sends " <>
        "a result message: a crashing task takes the caller down, and " <>
        "completed results accumulate unread in the mailbox.",
      at: Findings.at_instr(id),
      at_label: "task started here",
      help: [
        "consume the result with `Task.await/2` (or `Task.yield/2` plus " <>
          "`Task.shutdown/1`), or use `Task.Supervisor.start_child/2` for " <>
          "fire-and-forget work"
      ]
    )
  end

  def finding(:unchecked_start_child, [func, id]) do
    Findings.new(
      :warning,
      "start_child result not checked",
      "#{func} discards the result of Task.Supervisor.start_child. A " <>
        "{:error, reason} return — supervisor at max_children, not yet " <>
        "started, bad child spec — is silently ignored, so failed launches " <>
        "look exactly like successful ones.",
      at: Findings.at_instr(id),
      at_label: "start_child result discarded here",
      help: [
        "match on the result — `{:ok, pid} = Task.Supervisor.start_child(...)` " <>
          "at minimum, or handle `{:error, reason}` explicitly"
      ]
    )
  end
end
