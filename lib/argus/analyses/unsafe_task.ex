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
  # ErrorHandling for `trap_exit`: a process trapping exits does see a
  # linked task crash, so yield_on_linked_task stays quiet for it.
  def extractors,
    do: [
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.ErrorHandling,
      Argus.Extractors.CallbackTag
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :nolink_messages_unhandled,
        fields: [
          {:mod, :symbol, "the process module"},
          {:start, :symbol, "function starting the async_nolink task"},
          {:handler, :symbol, "its handle_info/2"},
          {:missing, :symbol, "'reply' ({ref, result}) or 'down' ({:DOWN, ...})"}
        ],
        key: [:mod, :start],
        doc: "An async_nolink task's reply or :DOWN message has no handle_info clause."
      },
      %{
        name: :leaked_async_task,
        fields: [
          {:func, :symbol, "function containing the async call"},
          {:id, :symbol, "instruction ID of the Task.async call"}
        ],
        doc: "Task.async or async_nolink call without corresponding await/yield."
      },
      %{
        name: :yield_on_linked_task,
        fields: [
          {:func, :symbol, "function that starts and yields on the task"},
          {:id, :symbol, "instruction ID of the Task.async call"}
        ],
        doc: "A linked task is collected with Task.yield in a caller that does not trap exits."
      },
      %{
        name: :linked_task_in_library,
        fields: [
          {:func, :symbol, "library function that starts the task"},
          {:id, :symbol, "instruction ID of the Task.async call"}
        ],
        doc:
          "Task.async in a function that is not a process callback links the task to an unknown caller."
      }
    ]
  end

  @impl true
  def finding(:yield_on_linked_task, [func, id]) do
    Findings.new(
      :warning,
      "Task.yield on a linked task cannot see it crash",
      "#{func} starts a task with Task.async (or Task.Supervisor.async), which " <>
        "links it to the caller, and collects it with Task.yield. yield's " <>
        "{:exit, reason} result is documented for a crashed task, but the link " <>
        "delivers the crash to this process first: unless it traps exits, the " <>
        "branch handling a failed task never runs — the caller is already down.",
      at: Findings.at_instr(id),
      at_label: "linked task started here",
      help: [
        "use `Task.Supervisor.async_nolink/2` so a crash reaches `Task.yield` as {:exit, reason}",
        "or trap exits in this process and handle the {:EXIT, ...} messages"
      ]
    )
  end

  def finding(:linked_task_in_library, [func, id]) do
    Findings.new(
      :info,
      "Task.async in library code links to an unknown caller",
      "#{func} is a plain function, not a process callback, so the task it starts " <>
        "with Task.async is linked to whichever process called it. A caller that " <>
        "traps exits then receives the task's exit as an {:EXIT, pid, :normal} " <>
        "message that Task.await never consumes, and a crashing task takes the " <>
        "caller down with it.",
      at: Findings.at_instr(id),
      at_label: "linked task started in library code",
      help: [
        "use `Task.async_stream/3` or `Task.Supervisor.async_nolink/2`, " <>
          "or document that callers must not trap exits"
      ]
    )
  end

  def finding(:nolink_messages_unhandled, [mod, start, handler, missing]) do
    what =
      case missing do
        "reply" -> "the task's reply, `{ref, result}`"
        _ -> "the task's exit, `{:DOWN, ref, :process, pid, reason}`"
      end

    Findings.new(
      :warning,
      "async_nolink task's messages have no handle_info clause",
      "#{start} starts a task with Task.Supervisor.async_nolink from #{mod}'s " <>
        "callbacks and does not collect it there, so #{what} lands in " <>
        "#{handler} — which matches other messages and has no clause for it. " <>
        "The first task to finish is a FunctionClauseError.",
      at: Findings.at_func(start),
      at_label: "async_nolink started here",
      help: [
        "add `handle_info({ref, result}, state) when is_reference(ref)` and " <>
          "`handle_info({:DOWN, ref, :process, _pid, reason}, state)` clauses",
        "or collect the task where it is started with Task.yield/2 and Task.shutdown/1"
      ]
    )
  end

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
end
