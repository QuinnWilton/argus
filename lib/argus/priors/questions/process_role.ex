defmodule Argus.Priors.Questions.ProcessRole do
  @moduledoc """
  Whether a module fronts a process, or only contains a call.

  `stateful_module_dep`'s third clause (calls.dl) says a module depends
  on a sibling when it reaches *any* function of it and the sibling has a
  `GenServer.call` or cast *somewhere*: a facade reached through
  delegation, like Oban's Notifier, is caught that way and nothing
  resolved would catch it — and so is a pure ETS reader in a module that
  happens to call a server from its `start_link`, which is where 29 of
  32 of one analysis's false positives came from. The bytecode cannot
  tell the two apart; a reader tells them apart by the module's name,
  behaviours and functions, and so, the calibration spike found, does
  the model: 100% precision at 0.7 on the binary this relation carries,
  18 true positives to one false on the residue.

  Asked about the modules with a call or cast and no callback loop of
  their own. The row is the `noul` answer, "calling this module's public
  functions sends a message to, or waits for a reply from, a long-lived
  process", in thousandths; the six-way role the model also chooses
  stays in the cache for the reader.
  """

  @behaviour Argus.Priors.Question

  alias Argus.InstrId

  @loop_behaviours ~w(GenServer :gen_server gen_server GenStateMachine :gen_statem gen_statem
                      GenEvent :gen_event gen_event GenStage Broadway Supervisor :supervisor
                      supervisor DynamicSupervisor PartitionSupervisor ConsumerSupervisor
                      Phoenix.LiveView Phoenix.LiveComponent Phoenix.Channel Connection
                      Postgrex.SimpleConnection Postgrex.ReplicationConnection NimblePool)

  @callback_shapes ~w(start_link/0 start_link/1 start_link/2 start/1 child_spec/1 init/1 handle_call/3
                      handle_cast/2 handle_info/2 handle_continue/2 terminate/2 callback_mode/0)

  @messaging %{
    "GenServer" => ~w(call cast multi_call stop whereis send_request),
    ":gen_server" => ~w(call cast multi_call stop send_request),
    "GenStateMachine" => ~w(call cast stop),
    ":gen_statem" => ~w(call cast stop send_request),
    "Agent" => ~w(get update get_and_update cast stop),
    "Task" => ~w(async await yield shutdown),
    "Task.Supervisor" => ~w(async async_nolink start_child),
    ":erlang" => ~w(send monitor spawn spawn_link spawn_monitor whereis register)
  }

  @noise_modules ~w(:erlang :elixir_erl_pass :elixir_aliases Kernel Kernel.Utils :maps :lists Access
                    Enum Map String List Keyword Integer Tuple Function :binary :unicode :io_lib IO :io
                    Code Macro Module ArgumentError RuntimeError Exception String.Chars Inspect)

  @roles %{
    process_impl:
      "The module is itself a long-lived process: it implements the callbacks (init, handle_call, handle_info) " <>
        "of a GenServer, gen_statem or similar loop",
    process_facade:
      "A client API for a long-lived process: its public functions send messages to, or wait on, " <>
        "a server this module represents",
    mixed: "Some public functions talk to a process, others are pure computation over data",
    pure_helper:
      "Pure functions over data and structs; calling it never sends a message to or waits on a long-lived process",
    supervisor: "Starts and supervises child processes",
    other: "A Mix task, exception, protocol implementation, macro-only module or test support"
  }

  @impl true
  def relation, do: :prior_talks_to_process

  @impl true
  def prompt_version, do: 1

  @impl true
  def relations_read,
    do:
      ~w(function_def remote_call bif_call local_call closure_def implements_behaviour started_as
           sync_call async_cast supervisor_child named_process process_register)a

  @impl true
  def subjects(facts) do
    index = index(facts)

    index.by_mod
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reject(&loop?(index, &1))
    |> Enum.filter(&(talking(index, &1) != []))
    |> Enum.map(fn mod ->
      ids = index.by_mod[mod] |> Enum.reject(&(generated?(index.funcs[&1]) or closure?(&1)))
      names = ids |> Enum.map(&name_arity(index, &1)) |> Enum.sort()

      %{
        id: mod,
        batch_key: mod,
        state: %{
          module: mod,
          behaviours: Map.get(index.behaviours, mod, []),
          supervised_by: Map.get(index.sup_children, mod, []),
          registered_names: index.registered |> Map.get(mod, []) |> Enum.map(&strip/1),
          defines: Enum.filter(names, &(&1 in @callback_shapes)),
          exported_functions:
            ids
            |> Enum.filter(&index.funcs[&1].exported)
            |> Enum.map(&name_arity(index, &1))
            |> Enum.sort()
            |> Enum.take(40),
          functions_that_message_a_process:
            index
            |> talking(mod)
            |> Enum.map(&name_arity(index, &1))
            |> Enum.sort()
            |> Enum.take(20),
          calls_into_modules: index |> modules_called(mod) |> Enum.take(20),
          called_from_modules: index |> modules_calling(mod) |> Enum.take(15)
        }
      }
    end)
  end

  @impl true
  def state([subject]), do: subject.state
  def state([first | _]), do: first.state

  @impl true
  def questions(subjects) do
    subjects
    |> Enum.with_index()
    |> Enum.flat_map(fn {_subject, i} ->
      [
        {"role__#{i}",
         %{
           type: "choice",
           instructions:
             "What is this module at runtime? Judge from its behaviours, the functions it defines and calls, " <>
               "how other modules use it, and its name.",
           criteria: @roles
         }},
        {"api_messages_a_process__#{i}",
         %{
           type: "noul",
           instructions:
             "Calling this module's public functions sends a message to, or waits for a reply from, a long-lived process."
         }}
      ]
    end)
    |> Map.new()
  end

  @impl true
  def rows(subjects, answers) do
    subjects
    |> Enum.with_index()
    |> Enum.flat_map(fn {%{id: mod}, i} ->
      case answers["api_messages_a_process__#{i}"] do
        %{"noul" => p} when is_number(p) ->
          [[mod, Integer.to_string(Argus.Priors.Questions.Sensitivity.permille(p))]]

        _ ->
          []
      end
    end)
  end

  # ── Index ──────────────────────────────────────────────────────────

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

    registered =
      Enum.map(rows.(:named_process), &{&1.mod, &1.name}) ++
        Enum.map(rows.(:process_register), &{module_of(&1.func), &1.name})

    %{
      funcs: funcs,
      by_mod: group(Map.to_list(funcs), fn {_, m} -> m.mod end, fn {id, _} -> id end),
      behaviours:
        group(rows.(:implements_behaviour) ++ rows.(:started_as), & &1.mod, & &1.behaviour),
      callees: group(edges, &elem(&1, 0), &elem(&1, 1)),
      callers: group(edges, &elem(&1, 1), &elem(&1, 0)),
      closures: group(rows.(:closure_def), & &1.parent_func, & &1.closure_func),
      sync_calls: group(rows.(:sync_call), & &1.caller_func, & &1.callee_mod),
      async_casts: group(rows.(:async_cast), & &1.caller_func, & &1.callee_mod),
      sup_children: group(rows.(:supervisor_child), & &1.child_mod, & &1.sup),
      registered: group(registered, &elem(&1, 0), &elem(&1, 1))
    }
  end

  defp group(rows, key, value) do
    rows |> Enum.group_by(key, value) |> Map.new(fn {k, vs} -> {k, Enum.uniq(vs)} end)
  end

  defp loop?(index, mod),
    do: index.behaviours |> Map.get(mod, []) |> Enum.any?(&(&1 in @loop_behaviours))

  # The module's named functions that message a process: a resolved call
  # or cast, or a call into a messaging API, their closures included.
  defp talking(index, mod) do
    index.by_mod
    |> Map.get(mod, [])
    |> Enum.reject(&(generated?(index.funcs[&1]) or closure?(&1)))
    |> Enum.filter(fn id ->
      Map.has_key?(index.sync_calls, id) or Map.has_key?(index.async_casts, id) or
        Enum.any?(calls(index, id), &messaging?/1)
    end)
  end

  defp messaging?(call) do
    case InstrId.parse_func(call) do
      {:ok, %{module: m, func: f}} -> f in Map.get(@messaging, m, [])
      :error -> false
    end
  end

  defp calls(index, func), do: walk_calls(index, [func], MapSet.new([func]), [])

  defp walk_calls(_index, [], _seen, acc), do: acc |> Enum.reverse() |> Enum.uniq()

  defp walk_calls(index, [f | rest], seen, acc) do
    {closure_calls, real} = index.callees |> Map.get(f, []) |> Enum.split_with(&closure?/1)

    new =
      (closure_calls ++ Map.get(index.closures, f, [])) |> Enum.reject(&MapSet.member?(seen, &1))

    seen = Enum.reduce(new, seen, &MapSet.put(&2, &1))
    walk_calls(index, rest ++ new, seen, Enum.reverse(real) ++ acc)
  end

  defp modules_called(index, mod) do
    index.by_mod
    |> Map.get(mod, [])
    |> Enum.flat_map(&calls(index, &1))
    |> Enum.map(&module_of/1)
    |> Enum.reject(&(&1 == mod or &1 in @noise_modules or String.starts_with?(&1, ":elixir")))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp modules_calling(index, mod) do
    index.by_mod
    |> Map.get(mod, [])
    |> Enum.flat_map(&Map.get(index.callers, &1, []))
    |> Enum.map(&module_of/1)
    |> Enum.reject(&(&1 == mod))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp name_arity(index, id), do: "#{index.funcs[id].name}/#{index.funcs[id].arity}"

  defp generated?(%{name: name}) do
    String.starts_with?(name, "-") or String.starts_with?(name, "__") or
      String.starts_with?(name, "MACRO-") or name == "module_info" or
      String.contains?(name, "(overridable")
  end

  defp closure?(func_id) do
    case InstrId.parse_func(func_id) do
      {:ok, %{func: f}} -> String.starts_with?(f, "-") and String.contains?(f, "-fun-")
      :error -> false
    end
  end

  defp module_of(func_id) do
    case InstrId.parse_func(func_id) do
      {:ok, %{module: m}} -> m
      :error -> func_id
    end
  end

  defp strip(":" <> rest), do: rest
  defp strip(other), do: other
end
