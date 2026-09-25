defmodule Argus.Priors.Questions.Tooling do
  @moduledoc """
  Whether a module is part of the product the deployed system runs, or
  tooling: a developer's tool or support for tests.

  Every analysis reports what it finds wherever it finds it, and a
  build compiles more than the product: blockster's `DevSetup` seeding a
  development database from iex, Phoenix's code reloader, sequin's
  `Havoc` killing processes on purpose, hexpm's fake-data generator. A
  defect there costs a developer's command or a test run, not the
  running system, and every analysis steps such a finding down
  (`Argus.Findings.Tooling`). The bytecode says so only in part — a
  module under `Mix.` or compiled from a test-support directory is
  decided structurally (`tooling_module`) and is not asked — and a
  reader tells the rest from names: the module's own, its functions',
  and those of the modules it calls and that call it. So, calibrated
  below, does the model.

  Asked about every module the structure leaves undecided but a
  protocol's implementation (it defines `__impl__/1`, and is the
  struct's) and a module with no exported function of its own (a struct
  or an exception, which only its name would describe). Each module is
  one request, so its answer does not move with its neighbours and an
  edit asks again only about the module it touched. The question asks
  what the module *is* — product, a developer's tool or test support —
  as one `choice`; the row carries the likeliest kind and its
  probability, and last the probability that the module is tooling: the
  mass of `development` and `test`, which the rules read.

  ## Calibration

  The modules holding a finding over the fifteen evaluation programs
  (four apps, the Phoenix stack, OTP's kernel, stdlib and mnesia,
  ejabberd, rabbitmq, akkoma, mongooseim and vernemq), read by hand: 858
  after the 18 the structure decides (34 findings) and 16 a reader
  cannot call either way (the Erlang shell and its line editor, the
  compiler's front end in stdlib, `peer`, rabbit's chaos server,
  sequin's benchmark statistics), of which 13 are tooling (27
  findings). At 0.9 version 2 re-tiers 9 of them (19 findings) and 8
  rightly; the one it gets wrong is rabbit's `code_version`, which
  patches modules for the running release and reads, by its name and
  calls, as a build tool. At 0.95 it re-tiers 6, 5 rightly. The five it
  leaves are a load tester (`vmq_churney`), a dump helper only a test
  calls, a documentation generator, erlc's compile server and sequin's
  `Havoc` (0.85 and 0.86). Version 1 asked ten modules of a namespace
  per request and did as well at 0.9 (8 of 9, the same `code_version`),
  but a module's answer moved with the neighbours its batch gave it:
  `erl_lint` scored 0.83 in one batch and 0.99 in another. Wording that
  named a compiler among the developer's tools, or code that compiles
  and migrates at run time among the product's, raised the compiler's
  front end without moving `code_version`.
  """

  @behaviour Argus.Priors.Question

  alias Argus.Priors.Questions.Code

  @criteria %{
    product:
      "Part of what the deployed system runs to do its work: its servers, workers, request " <>
        "handlers, schemas and library API, and the admin or command-line commands an operator " <>
        "runs against the live system",
    development:
      "A tool only a developer runs, on their machine or at build time: a code generator or " <>
        "build task, database seeds and development-only setup, a benchmark, a profiling or " <>
        "debugging helper, a development-only page or live reload",
    test:
      "Support that only tests run: test cases and helpers, fixtures, factories, fakes, mocks " <>
        "and stubs, a test client or server, and the test helpers a library ships for its " <>
        "users' tests"
  }

  @kinds ~w(product development test)
  @tooling ~w(development test)

  # What a module calls that says nothing about what it is.
  @noise ~w(:erlang :lists :maps :proplists :io_lib :unicode :binary :string Kernel Kernel.Utils
            Access Enum Map List Keyword String Integer Tuple Atom Function Stream MapSet
            ArgumentError RuntimeError KeyError Exception Protocol String.Chars Inspect
            Inspect.Algebra)

  @impl true
  def relation, do: :prior_tooling

  @impl true
  def prompt_version, do: 2

  @impl true
  def relations_read, do: Code.relations_read() ++ [:tooling_module]

  @impl true
  def subjects(facts) do
    index = Code.index(facts)
    decided = facts |> Map.get(:tooling_module, []) |> MapSet.new(& &1.mod)
    calls = module_calls(facts, index)
    callers = invert(calls)

    index.by_mod
    |> Map.keys()
    |> Enum.reject(&(MapSet.member?(decided, &1) or protocol_impl?(index, &1)))
    |> Enum.sort()
    |> Enum.map(&{&1, Code.siblings(index, &1, 15)})
    # A module with no function of its own to show (a struct, an
    # exception) is asked from its name alone, and a finding is seldom
    # there: it is left as the product.
    |> Enum.reject(fn {_mod, functions} -> functions == [] end)
    |> Enum.map(fn {mod, functions} ->
      %{
        id: mod,
        batch_key: mod,
        state: %{
          module: mod,
          behaviours: index.behaviours |> Map.get(mod, []) |> Enum.sort(),
          functions: functions,
          calls: calls |> Map.get(mod, []) |> Enum.reject(&noise?/1) |> Enum.take(15),
          called_by: callers |> Map.get(mod, []) |> Enum.take(10)
        }
      }
    end)
  end

  # The modules each module's functions call, closures included, sorted.
  defp module_calls(facts, index) do
    facts
    |> Map.get(:remote_call, [])
    |> Enum.flat_map(fn r ->
      case index.funcs[r.caller] do
        %{mod: from} when from != r.mod -> [{from, r.mod}]
        _ -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {mod, tos} -> {mod, tos |> Enum.uniq() |> Enum.sort()} end)
  end

  defp invert(calls) do
    calls
    |> Enum.flat_map(fn {from, tos} -> Enum.map(tos, &{&1, from}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {mod, froms} -> {mod, froms |> Enum.uniq() |> Enum.sort()} end)
  end

  defp noise?(mod), do: mod in @noise or String.starts_with?(mod, ":elixir")

  defp protocol_impl?(index, mod) do
    index.by_mod
    |> Map.get(mod, [])
    |> Enum.any?(&match?(%{name: "__impl__", arity: 1}, index.funcs[&1]))
  end

  @impl true
  def state(subjects) do
    %{modules: Enum.map(subjects, & &1.state)}
  end

  @impl true
  def questions(subjects) do
    subjects
    |> Enum.with_index()
    |> Map.new(fn {%{id: mod}, i} ->
      {"kind__#{i}",
       %{
         type: "choice",
         instructions:
           "What is the module `#{mod}` listed under `modules`: part of the product the " <>
             "deployed system runs, a tool only developers run, or support for tests? Judge " <>
             "from its name, its functions, the modules it calls and the modules that call it.",
         criteria: @criteria
       }}
    end)
  end

  @impl true
  def rows(subjects, answers) do
    subjects
    |> Enum.with_index()
    |> Enum.flat_map(fn {%{id: mod}, i} ->
      case answers["kind__#{i}"] do
        %{"choice" => choice, "probabilities" => probs} when choice in @kinds ->
          tooling = Enum.reduce(@tooling, 0.0, &(&2 + probability(probs, &1)))

          [
            [
              mod,
              choice,
              Integer.to_string(permille(probability(probs, choice))),
              Integer.to_string(permille(tooling))
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
