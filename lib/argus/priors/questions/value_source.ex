defmodule Argus.Priors.Questions.ValueSource do
  @moduledoc """
  What the value a sink converts is: a name the operator configures, an
  identifier from the program's own code, bytes the program stored
  itself, a message from its own cluster, a developer's or operator's
  input to a tool — or data from outside the system.

  `unsafe_input` reports a sink no request reaches where the library's
  users can hand it anything: an atom made of an exported function's
  parameter, every `binary_to_term` without `:safe`, code execution the
  exports reach. On real programs most of those are library API doing
  what it is for — a pool's name from its start options, a `dets` file's
  own records, a mix task's `System.cmd`, a message from another node of
  the same cluster — and a few are the bug: tesla's Mint adapter making
  an atom of a URL's scheme, a node name read from a Postgres
  notification, a boot server decoding UDP. The bytecode cannot tell a
  cache's name from a URL's scheme; a reader tells them apart by the
  names around the call, and so, calibrated below, does the model.

  Asked about the functions that hold an unbounded sink, one subject per
  function and kind of sink; the functions of one module ride in one
  request. The state is names: the module, its behaviours and exported
  functions, and for each function the call it makes, what else it
  calls, its literals and who calls it. The question asks what the value
  *is* — "what is the string `binary_to_atom` turns into an atom" — and
  not where the function is used from: a question about use gets an
  answer about the callers.

  The row carries the likeliest kind and its probability, and last the
  probability that the value is not outside data: the mass of every
  other kind. `unsafe_input` reads that mass.

  ## Calibration

  232 rows of `unsafe_input`'s no-request titles, read by hand, over the
  ten evaluation programs (four apps, the Phoenix stack, OTP's kernel,
  stdlib and mnesia), ejabberd and rabbitmq: 212 are not outside data
  (56 an operator's input, 56 stored, 52 configured, 34 code, 14 the
  cluster's) and 20 are. At a mass of 0.9 version 2 moves 68% of the
  212 at 98% precision and leaves 17 of the 20; the three it moves are
  Livebook's git client and editor completion, input from Livebook's
  own user. At 0.95 it moves 51% and leaves all 20. Version 1 named a
  queue among the configured names and had no word for text read at
  compile time: 63% at 98.5%, rabbit's client-declared queue names at
  0.98, router and template compilers answered outside. A second
  question asking whether an outsider can choose the value, as a
  `noul`, calibrated worse than the mass (20% coverage at 98%) and was
  dropped. Showing who calls the function helps here, where the value
  arrives through the arguments: without `called_by`, 65% at 98.6%.
  """

  @behaviour Argus.Priors.Question

  alias Argus.Priors.Questions.Code

  @criteria %{
    configured:
      "A name or setting the program's operator chose: an application or environment setting, " <>
        "a node, host, pool, cache, table or process name given in the program's configuration " <>
        "or start options",
    code:
      "Text from the program's own source code, read when it is compiled or from its own " <>
        "definitions: identifiers, module, function, field and key names, route patterns, " <>
        "template or DSL text",
    stored:
      "Bytes or text this program wrote itself earlier and reads back: its own files, logs, " <>
        "tables, caches, database rows, compiled .beam files or signed cookies",
    cluster:
      "A message from another node or process that is already part of the same system: the " <>
        "cluster's own pub/sub, a node it started, replication between its own nodes",
    operator:
      "Input a developer or administrator types into a tool: a mix task, generator or compiler " <>
        "argument, a release, admin or CLI command, a shell or REPL",
    outside:
      "Data from outside the system at run time: an HTTP request or its parameters, a URL or name " <>
        "a user or client supplies, a message from a client or a connecting peer, a user's upload"
  }

  @sources ~w(configured code stored cluster operator outside)
  @trusted ~w(configured code stored cluster operator)

  @kinds [
    {:unsafe_atom_creation, "atom"},
    {:unsafe_deserialization, "deserialization"},
    {:code_execution, "code"}
  ]

  # Request-entry callbacks, as clientlib/request_entry.dl spells them:
  # a sink there is the request's, and its row is not the one this
  # prior re-tiers.
  @entries %{
    "Plug" => [{"call", 2}],
    "Phoenix.LiveView" => [{"mount", 3}, {"handle_params", 3}, {"handle_event", 3}],
    "Phoenix.LiveComponent" => [{"handle_event", 3}],
    "Phoenix.Channel" => [{"handle_in", 3}],
    "Oban.Worker" => [{"perform", 1}],
    "Broadway" => [{"handle_message", 3}, {"handle_batch", 4}]
  }

  @impl true
  def relation, do: :prior_value_source

  @impl true
  def prompt_version, do: 2

  @impl true
  def relations_read,
    do:
      Code.relations_read() ++
        ~w(unsafe_atom_creation unsafe_deserialization code_execution sink_arg_bounded)a

  @impl true
  def subjects(facts) do
    index = Code.index(facts)

    # A bounded atom or deserialization is no sink; a code sink is one
    # whatever its command (unsafe_input.dl's `sink`).
    bounded =
      for r <- Map.get(facts, :sink_arg_bounded, []),
          r.arg_pos == 0 and r.list_param == "",
          into: MapSet.new(),
          do: site(r.id)

    @kinds
    |> Enum.flat_map(fn {relation, sink} ->
      for r <- Map.get(facts, relation, []),
          sink == "code" or not MapSet.member?(bounded, site(r.id)),
          do: {r.func, sink, r.api}
    end)
    |> Enum.group_by(fn {func, sink, _api} -> {func, sink} end, fn {_, _, api} -> api end)
    |> Enum.filter(fn {{func, _sink}, _apis} ->
      Map.has_key?(index.funcs, func) and not entry?(index, func) and not macro?(index, func)
    end)
    |> Enum.sort()
    |> Enum.map(fn {{func, sink}, apis} ->
      meta = index.funcs[func]

      %{
        id: {func, sink},
        batch_key: meta.mod,
        state: %{
          module: meta.mod,
          module_behaviours: Map.get(index.behaviours, meta.mod, []),
          exported_functions: Code.siblings(index, meta.mod, 25),
          function: Code.display(func),
          sink: sink,
          call: apis |> Enum.uniq() |> Enum.sort() |> Enum.map_join(", ", &spell/1),
          calls: Code.calls(index, func, 25),
          literals: Code.literals(index, func, 20),
          called_by: Code.callers(index, func, 8)
        }
      }
    end)
  end

  @impl true
  def state([first | _] = subjects) do
    %{
      module: first.state.module,
      module_behaviours: first.state.module_behaviours,
      exported_functions: first.state.exported_functions,
      functions:
        Enum.map(
          subjects,
          &Map.take(&1.state, [:function, :call, :calls, :literals, :called_by])
        )
    }
  end

  @impl true
  def questions(subjects) do
    subjects
    |> Enum.with_index()
    |> Map.new(fn {subject, i} ->
      %{function: f, call: call, sink: sink} = subject.state

      {"source__#{i}",
       %{
         type: "choice",
         instructions:
           "#{what(sink, call, f)} Judge from the module's and the function's names, what it calls, " <>
             "its literals and who calls it.",
         criteria: @criteria
       }}
    end)
  end

  defp what("atom", call, f),
    do: "In `#{f}` listed under `functions`, what is the string that #{call} turns into an atom?"

  defp what("deserialization", call, f),
    do: "In `#{f}` listed under `functions`, what are the bytes that #{call} decodes into a term?"

  defp what("code", call, f),
    do: "In `#{f}` listed under `functions`, what is the command or code that #{call} runs?"

  @impl true
  def rows(subjects, answers) do
    subjects
    |> Enum.with_index()
    |> Enum.flat_map(fn {%{id: {func, sink}}, i} ->
      case answers["source__#{i}"] do
        %{"choice" => choice, "probabilities" => probs} when choice in @sources ->
          trusted = Enum.reduce(@trusted, 0.0, &(&2 + probability(probs, &1)))

          [
            [
              func,
              sink,
              choice,
              Integer.to_string(permille(probability(probs, choice))),
              Integer.to_string(permille(trusted))
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

  # A sink's site, however the relation types it.
  defp site(%Argus.InstrId{} = id), do: Argus.InstrId.format(id)
  defp site(id) when is_binary(id), do: id

  # The compiled forms of String.to_atom/1 and List.to_atom/1 are what
  # the facts see; the reader writes the source.
  defp spell(":erlang.binary_to_atom/" <> _), do: "`String.to_atom`"
  defp spell(":erlang.list_to_atom/" <> _), do: "`List.to_atom`"
  defp spell(":erlang.binary_to_term/" <> _), do: "`:erlang.binary_to_term`"
  defp spell(api), do: "`#{api}`"

  # A macro makes its atom at compile time, of the code that uses it;
  # unsafe_input does not report it.
  defp macro?(index, func), do: String.starts_with?(index.funcs[func].name, "MACRO-")

  defp entry?(index, func) do
    case index.funcs[func] do
      nil ->
        false

      %{mod: mod, name: name, arity: arity} ->
        index.behaviours
        |> Map.get(mod, [])
        |> Enum.any?(fn b -> {name, arity} in Map.get(@entries, b, []) end)
    end
  end
end
