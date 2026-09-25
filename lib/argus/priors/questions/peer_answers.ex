defmodule Argus.Priors.Questions.PeerAnswers do
  @moduledoc """
  Whether the process a wait is on answers every request from within
  the node, or its answer waits on another node, an external program, or
  something that may never happen.

  Two analyses report a wait on a peer whose answer they cannot see
  coming. `blocking` reports a server's callback that calls another
  server with no deadline (`:infinity`) or from handle_cast/2, where the
  caller's own mailbox backs up while it waits; `startup` reports an
  init/1 that reaches a `receive` with no `after`. Whether that is a
  hazard turns on the peer: mnesia's recover server calling its monitor,
  ejabberd's modules calling the hook registry, `code_server` answering
  `code:call/1` — local services that reply to every request — are not
  the peer that hangs; `dist_ac` waiting on another node, a pool
  holding its callers until a connection frees, a port running `df` are.
  The bytecode shows the call and the receive, not what the peer is; a
  reader tells from names, and so, calibrated below, does the model.

  Two kinds of subject, one question each:

  - `server` — a GenServer another module calls: its name, behaviours,
    API, and what its handle_call/3 calls. "When another process calls
    this server, what does its reply wait on?"
  - `wait` — a function with a `receive` that has no `after`: its name,
    what it calls, its literals (the message tags it matches) and who
    calls it. "What is the `receive` waiting for?"

  Both answer one choice: `local` (a process or driver inside the node
  that answers every request), `remote` (another node, a database, the
  network, an external program) or `event` (something that may not
  happen: a free resource, another request, a timer, a person). The row
  carries the likeliest and its probability, and last the probability of
  `local`, which the rules read.

  ## Calibration

  The 47 peers behind blocking's cast and `:infinity` findings and
  startup's init/1 waits over the evaluation programs, ejabberd and
  rabbitmq, read by hand: 37 answer from inside the node, 10 do not
  (`dist_ac`, `global`, `rabbit_amqp_writer`, a DBConnection pool,
  `gen_server:multi_call`'s receive, `peer:init/1`, kernel_config waiting
  for other nodes, ejabberd's captcha and rabbit's disk monitor reading
  a command's output). At 0.8 version 2 marks 78% of the 37 and none of
  the 10, whose highest scored 0.62; at 0.7, 86%. Version 1's `event`
  took "a message another part of the program may send", and the exit a
  wait is sure to get — `supervisor:shutdown/1`'s `:DOWN` after a kill,
  `proc_lib`'s — went there: 43% at 0.7. Naming the exit of a monitored
  or stopped process as `local` fixed it without moving a negative.
  """

  @behaviour Argus.Priors.Question

  alias Argus.Priors.Questions.Code

  @criteria %{
    local:
      "An answer that comes from inside this node every time: a reply from a local server, " <>
        "registry, table or file server, a runtime driver, a helper process it just started " <>
        "for the purpose, or the exit (a DOWN or EXIT) of a process it monitors or has just stopped",
    remote:
      "An answer from another node, a database, the network, or an external program or " <>
        "command: it may be slow or never come",
    event:
      "Something that may not happen soon or at all: a free resource in a pool, another " <>
        "client's request, a lock, a timer, a person, a message only some other part of the " <>
        "program may choose to send"
  }

  @peers ~w(local remote event)

  @servers ~w(GenServer :gen_server gen_server)

  @impl true
  def relation, do: :prior_answers

  @impl true
  def prompt_version, do: 2

  @impl true
  def relations_read, do: Code.relations_read() ++ ~w(recv_start named_process)a

  @impl true
  def subjects(facts) do
    index = Code.index(facts)
    servers(facts, index) ++ waits(facts, index)
  end

  # Every server that answers calls: what its handle_call/3 does is what
  # a caller waits on. The rules find the server a call reaches through
  # registered names and process points-to; asking every server keeps
  # that reasoning in one place, and a server is one request.
  defp servers(facts, index) do
    names = facts |> Map.get(:named_process, []) |> Enum.group_by(& &1.mod, & &1.name)

    index.by_mod
    |> Map.keys()
    |> Enum.filter(&server?(index, &1))
    |> Enum.sort()
    |> Enum.map(fn mod ->
      handlers = index.by_mod |> Map.get(mod, []) |> Enum.filter(&handle_call?(index, &1))

      %{
        id: {"server", mod},
        batch_key: {"server", mod},
        state: %{
          server: mod,
          behaviours: Map.get(index.behaviours, mod, []),
          registered_as: names |> Map.get(mod, []) |> Enum.uniq() |> Enum.sort(),
          api: Code.siblings(index, mod, 30),
          handle_call_calls: handlers |> Enum.flat_map(&Code.calls(index, &1, 40)) |> Enum.uniq(),
          handle_call_literals:
            handlers |> Enum.flat_map(&Code.literals(index, &1, 30)) |> Enum.uniq()
        }
      }
    end)
  end

  # The functions with a receive that has no `after`.
  defp waits(facts, index) do
    facts
    |> Map.get(:recv_start, [])
    |> Enum.filter(&(&1.blocking == 1))
    |> Enum.map(& &1.caller)
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(index.funcs, &1))
    |> Enum.sort()
    |> Enum.map(fn func ->
      meta = index.funcs[func]

      %{
        id: {"wait", func},
        batch_key: {"wait", meta.mod},
        state: %{
          module: meta.mod,
          behaviours: Map.get(index.behaviours, meta.mod, []),
          function: Code.display(func),
          calls: Code.calls(index, func, 25),
          literals: Code.literals(index, func, 25),
          called_by: Code.callers(index, func, 8)
        }
      }
    end)
  end

  defp server?(index, mod) do
    index.behaviours |> Map.get(mod, []) |> Enum.any?(&(&1 in @servers)) or
      index.by_mod |> Map.get(mod, []) |> Enum.any?(&handle_call?(index, &1))
  end

  defp handle_call?(index, func) do
    match?(%{name: "handle_call", arity: 3}, index.funcs[func])
  end

  @impl true
  def state([%{id: {"server", _}} = subject]), do: subject.state

  def state([%{id: {"wait", _}} = first | _] = subjects) do
    %{
      module: first.state.module,
      behaviours: first.state.behaviours,
      functions:
        Enum.map(subjects, &Map.take(&1.state, [:function, :calls, :literals, :called_by]))
    }
  end

  @impl true
  def questions(subjects) do
    subjects
    |> Enum.with_index()
    |> Map.new(fn {subject, i} -> {"peer__#{i}", question(subject)} end)
  end

  defp question(%{id: {"server", mod}}) do
    %{
      type: "choice",
      instructions:
        "When another process calls the server `#{mod}` and waits for its reply, what is that " <>
          "reply waiting on? Judge from the server's name, its API and what its handle_call calls.",
      criteria: @criteria
    }
  end

  defp question(%{id: {"wait", _}, state: %{function: f}}) do
    %{
      type: "choice",
      instructions:
        "In `#{f}` listed under `functions`, a `receive` with no `after` waits for a message. " <>
          "What is it waiting on? Judge from the names, what the function calls, the message " <>
          "tags in its literals and who calls it.",
      criteria: @criteria
    }
  end

  @impl true
  def rows(subjects, answers) do
    subjects
    |> Enum.with_index()
    |> Enum.flat_map(fn {%{id: {kind, subject}}, i} ->
      case answers["peer__#{i}"] do
        %{"choice" => choice, "probabilities" => probs} when choice in @peers ->
          [
            [
              kind,
              subject,
              choice,
              Integer.to_string(permille(probability(probs, choice))),
              Integer.to_string(permille(probability(probs, "local")))
            ]
          ]

        _ ->
          []
      end
    end)
  end

  defp probability(probs, kind) do
    case Map.get(probs, kind) do
      p when is_number(p) -> p
      _ -> 0.0
    end
  end

  defp permille(p), do: Argus.Priors.Questions.Sensitivity.permille(p)
end
