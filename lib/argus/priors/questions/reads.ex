defmodule Argus.Priors.Questions.Reads do
  @moduledoc """
  What a function itself reads: the request, storage, configuration, the
  running system, or nothing beyond its arguments.

  `unsafe_input` proves a flow from a request parameter to a sink where
  the summaries can follow it, and otherwise reports a call path — real
  as a path, unproven as a data flow. On the sequin corpus every such
  path led to a sink converting a record loaded from Postgres or Redis.
  A reader tells `convert(Store.load(id))` from `convert(params["kind"])`
  by what the function calls; so, it turns out, does the model: the
  calibration spike measured 95% precision at a probability of 0.7 on
  functions read from beams, once the question asked what the function
  *reads* and stopped showing it who calls it (shown the callers, it
  answered the question it was asked instead — a helper called from
  `handle_event` does return request data).

  Asked only about the functions that hold a sink and are not themselves
  request entries: the few places the answer changes a finding. The
  functions of one module ride in one request; the state is names —
  the module, its behaviours and functions, each function's calls,
  literals and message tags — and never instruction ids or line numbers.
  """

  @behaviour Argus.Priors.Question

  alias Argus.InstrId

  @sources ~w(request storage config internal passthrough constant)

  @criteria %{
    request:
      "Reads the current request or message itself through a web or job framework API: " <>
        "the conn, params, a socket's client-pushed values, or job arguments",
    storage: "Reads a database, cache, ETS table or file",
    config: "Reads application configuration or environment variables",
    internal:
      "Reads the running system's own state: another process (a GenServer.call or Agent read), " <>
        "VM, node or process information, telemetry",
    passthrough:
      "Reads no source: computes from its arguments, whatever they contain, and literals",
    constant: "Reads no source and ignores its arguments: returns literals or module attributes"
  }

  # Request-entry callbacks, as clientlib/request_entry.dl spells them;
  # Elixir spellings only, since every one of these behaviours is Elixir's.
  @entries %{
    "Plug" => [{"call", 2}],
    "Phoenix.LiveView" => [{"mount", 3}, {"handle_params", 3}, {"handle_event", 3}],
    "Phoenix.LiveComponent" => [{"handle_event", 3}],
    "Phoenix.Channel" => [{"handle_in", 3}],
    "Oban.Worker" => [{"perform", 1}],
    "Broadway" => [{"handle_message", 3}, {"handle_batch", 4}]
  }

  @noise_erlang ~w(get_module_info error raise throw exit make_fun apply element setelement
                   tuple_size byte_size bit_size hd tl length map_size self node put get erase
                   is_atom is_binary is_list is_map is_tuple is_integer is_float is_function is_pid
                   integer_to_binary binary_to_integer atom_to_binary binary_to_list list_to_binary
                   iolist_to_binary abs rem div trunc round max min function_exported module_loaded)
  @noise_modules ~w(Kernel Kernel.Utils :maps :lists Access)

  @impl true
  def relation, do: :prior_reads

  @impl true
  def prompt_version, do: 2

  @impl true
  def relations_read,
    do:
      ~w(function_def remote_call bif_call local_call closure_def literal_value tuple_literal
           implements_behaviour started_as unsafe_atom_creation unsafe_deserialization code_execution)a

  @impl true
  def subjects(facts) do
    index = index(facts)

    facts
    |> sink_functions()
    |> Enum.reject(&entry?(index, &1))
    |> Enum.filter(&Map.has_key?(index.funcs, &1))
    |> Enum.sort()
    |> Enum.map(fn func ->
      meta = index.funcs[func]

      %{
        id: func,
        batch_key: meta.mod,
        state: %{
          module: meta.mod,
          module_behaviours: Map.get(index.behaviours, meta.mod, []),
          sibling_functions: siblings(index, meta.mod, func),
          function: "#{meta.name}/#{meta.arity}",
          exported: meta.exported,
          calls:
            index
            |> calls(func)
            |> Enum.reject(&noise_call?/1)
            |> Enum.map(&pretty/1)
            |> Enum.take(30),
          literals:
            index |> literals(func) |> Enum.reject(&noise_literal?(&1, meta.mod)) |> Enum.take(20)
        }
      }
    end)
  end

  @impl true
  def state([first | _] = subjects) do
    %{
      module: first.state.module,
      module_behaviours: first.state.module_behaviours,
      sibling_functions: first.state.sibling_functions,
      functions:
        Enum.map(subjects, &Map.take(&1.state, [:function, :exported, :calls, :literals]))
    }
  end

  @impl true
  def questions(subjects) do
    subjects
    |> Enum.with_index()
    |> Enum.flat_map(fn {subject, i} ->
      f = subject.state.function

      [
        {"origin__#{i}",
         %{
           type: "choice",
           instructions:
             "For the function `#{f}` listed under `functions`: which external source does it itself read, " <>
               "judging from what it calls and its literals? Values that arrive through its arguments " <>
               "do not count, whatever they contain and whoever calls it.",
           criteria: @criteria
         }},
        {"reads_request__#{i}",
         %{
           type: "noul",
           instructions:
             "The function `#{f}` itself reads the current request or message through a framework API, " <>
               "not counting its arguments."
         }},
        {"reads_storage__#{i}",
         %{
           type: "noul",
           instructions: "The function `#{f}` itself reads a database, cache, ETS table or file."
         }}
      ]
    end)
    |> Map.new()
  end

  @impl true
  def rows(subjects, answers) do
    subjects
    |> Enum.with_index()
    |> Enum.flat_map(fn {%{id: func}, i} ->
      case answers["origin__#{i}"] do
        %{"choice" => source, "probabilities" => probs} when source in @sources ->
          p = probs |> Map.get(source, 0.0) |> Argus.Priors.Questions.Sensitivity.permille()
          [[func, source, Integer.to_string(p)]]

        _ ->
          []
      end
    end)
  end

  # ── The index the state is built from ─────────────────────────────

  defp index(facts) do
    rows = &Map.get(facts, &1, [])

    funcs =
      Map.new(rows.(:function_def), fn r ->
        {r.func, %{mod: r.mod, name: r.name, arity: r.arity, exported: r.exported == 1}}
      end)

    edges =
      Enum.map(rows.(:remote_call), &{&1.caller, "#{&1.mod}:#{&1.func}/#{&1.arity}"}) ++
        Enum.map(rows.(:bif_call), &{&1.caller, "#{&1.mod}:#{&1.func}/#{&1.arity}"}) ++
        for(r <- rows.(:local_call), Map.has_key?(funcs, r.target), do: {r.caller, r.target})

    literals =
      Enum.map(rows.(:literal_value), &{func_of(&1.id), &1.val}) ++
        Enum.map(rows.(:tuple_literal), &{func_of(&1.id), &1.tag})

    %{
      funcs: funcs,
      by_mod: group(Map.to_list(funcs), fn {_, m} -> m.mod end, fn {id, _} -> id end),
      behaviours:
        group(rows.(:implements_behaviour) ++ rows.(:started_as), & &1.mod, & &1.behaviour),
      callees: group(edges, &elem(&1, 0), &elem(&1, 1)),
      closures: group(rows.(:closure_def), & &1.parent_func, & &1.closure_func),
      literals: group(literals, &elem(&1, 0), &elem(&1, 1))
    }
  end

  defp group(rows, key, value) do
    rows |> Enum.group_by(key, value) |> Map.new(fn {k, vs} -> {k, Enum.uniq(vs)} end)
  end

  defp sink_functions(facts) do
    [:unsafe_atom_creation, :unsafe_deserialization, :code_execution]
    |> Enum.flat_map(&Map.get(facts, &1, []))
    |> Enum.map(& &1.func)
    |> Enum.uniq()
  end

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

  # What the function calls, its closures' calls included and the closures
  # themselves elided: a reader sees `Enum.map(..., &Repo.get/1)` as one
  # function reading storage.
  defp calls(index, func), do: walk_calls(index, [func], MapSet.new([func]), [])

  defp walk_calls(_index, [], _seen, acc), do: acc |> Enum.reverse() |> Enum.uniq()

  defp walk_calls(index, [f | rest], seen, acc) do
    {closure_calls, real} = index.callees |> Map.get(f, []) |> Enum.split_with(&closure?/1)

    new =
      (closure_calls ++ Map.get(index.closures, f, [])) |> Enum.reject(&MapSet.member?(seen, &1))

    seen = Enum.reduce(new, seen, &MapSet.put(&2, &1))
    walk_calls(index, rest ++ new, seen, Enum.reverse(real) ++ acc)
  end

  defp literals(index, func) do
    children = for {parent, kids} <- index.closures, parent == func, kid <- kids, do: kid
    Enum.uniq(Enum.flat_map([func | children], &Map.get(index.literals, &1, [])))
  end

  defp siblings(index, mod, func) do
    index.by_mod
    |> Map.get(mod, [])
    |> Enum.reject(&(&1 == func or generated?(index.funcs[&1])))
    |> Enum.map(&"#{index.funcs[&1].name}/#{index.funcs[&1].arity}")
    |> Enum.sort()
    |> Enum.take(25)
  end

  defp generated?(%{name: name}) do
    String.starts_with?(name, "-") or String.starts_with?(name, "__") or
      String.starts_with?(name, "MACRO-") or name in ~w(module_info) or
      String.contains?(name, "(overridable")
  end

  defp closure?(func_id) do
    case InstrId.parse_func(func_id) do
      {:ok, %{func: f}} -> String.starts_with?(f, "-") and String.contains?(f, "-fun-")
      :error -> false
    end
  end

  defp noise_call?(call) do
    case InstrId.parse_func(call) do
      {:ok, %{module: ":erlang", func: f}} -> f in @noise_erlang
      {:ok, %{module: m}} -> String.starts_with?(m, ":elixir") or m in @noise_modules
      :error -> true
    end
  end

  defp noise_literal?(val, mod) do
    val in [
      "nil",
      "true",
      "false",
      "[]",
      "%{}",
      mod,
      ":ok",
      ":error",
      ":__block__",
      ":__aliases__"
    ] or
      String.starts_with?(val, "#") or String.starts_with?(val, "<<") or byte_size(val) > 48
  end

  defp func_of(%InstrId{module: m, func: f, arity: a}), do: "#{m}:#{f}/#{a}"

  defp func_of(s) when is_binary(s) do
    case InstrId.func_id_of(s) do
      {:ok, id} -> id
      :error -> s
    end
  end

  defp pretty(func_id) do
    case InstrId.parse_func(func_id) do
      {:ok, %{module: m, func: f, arity: a}} -> "#{m}.#{f}/#{a}"
      :error -> func_id
    end
  end
end
