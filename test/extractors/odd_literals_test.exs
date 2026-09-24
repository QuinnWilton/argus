defmodule Argus.Extractors.OddLiteralsTest do
  @moduledoc """
  Literal terms a beam can hold but real code seldom writes — improper
  lists, nested and at every depth, maps with odd keys, binaries of any
  bytes, terms past inspect's bounds — placed where the extractors read
  literals, and fed through the whole extraction pipeline. A beam is
  input: no literal in it may crash extraction.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.Pipeline

  # A struct literal is a map that implements no Enumerable: a walk that
  # enumerates maps raised on sequin's compile-time Ecto.Query.
  defstruct [:field]

  # Every shipped extractor, declared by an analysis or not.
  defp extractors do
    for mod <- Application.spec(:panoptes, :modules),
        String.starts_with?(Atom.to_string(mod), "Elixir.Argus.Extractors."),
        Code.ensure_loaded?(mod),
        function_exported?(mod, :extract, 1),
        do: mod
  end

  # Atoms the extractors look for, so that an odd term also takes the
  # branches that only a meaningful one reaches.
  @meaningful [
    :ok,
    :error,
    :reply,
    :noreply,
    :stop,
    :continue,
    :hibernate,
    :timeout,
    :state_timeout,
    :postpone,
    :next_event,
    :state_enter,
    :state_functions,
    :handle_event_function,
    :verify,
    :verify_none,
    :verify_peer,
    :named_table,
    :public,
    :protected,
    :heir,
    :strategy,
    :one_for_one,
    :child_spec,
    :restart,
    :type,
    :worker,
    :supervisor,
    :name,
    :via,
    :global,
    :flush,
    :trap_exit,
    :websocket,
    :longpoll,
    :safe,
    nil,
    true,
    false,
    GenServer,
    Supervisor,
    PartitionSupervisor,
    Registry,
    Argus.Extractors.OddLiteralsTest
  ]

  defp leaf do
    one_of([
      member_of(@meaningful),
      atom(:alphanumeric),
      integer(),
      float(),
      binary(max_length: 6),
      constant([]),
      constant(String.duplicate("x", 5000)),
      constant(Enum.to_list(1..80))
    ])
  end

  defp odd_term do
    tree(leaf(), fn child ->
      one_of([
        # Improper: a non-empty list ending in something other than [].
        map({list_of(child, min_length: 1, max_length: 3), leaf()}, fn {init, tail} ->
          init ++ improper_tail(tail)
        end),
        list_of(child, max_length: 4),
        map(list_of(child, max_length: 4), &List.to_tuple/1),
        map_of(child, child, max_length: 3),
        # The shapes the extractors take apart: child specs, actions,
        # options, sockets, routes, init results.
        map(child, &{Argus.Extractors.OddLiteralsTest, &1}),
        map(child, &{PartitionSupervisor, &1}),
        map(child, &%{id: &1, start: {Argus.Extractors.OddLiteralsTest, :start_link, &1}}),
        map(child, &{:ok, {&1, &1}}),
        map(child, &%__MODULE__{field: &1}),
        map({member_of(@meaningful), child}, fn {k, v} -> {k, v} end),
        # Options and specs whose keys are the ones read, with odd values.
        list_of(tuple({member_of(@meaningful), child}), min_length: 1, max_length: 3),
        map_of(member_of(@meaningful), child, max_length: 3),
        map(child, &{:state_timeout, &1, &1}),
        map(child, &{{:timeout, &1}, &1, &1}),
        map(child, &{:reply, &1, &1}),
        map(child, &{"/socket", Argus.Extractors.OddLiteralsTest, &1}),
        map(child, &%{path: &1, plug: &1, plug_opts: &1, verb: &1, helper: &1})
      ])
    end)
  end

  # `[a | []]` is proper; any other tail makes the list improper.
  defp improper_tail([]), do: :tail
  defp improper_tail(tail) when is_list(tail), do: {:tail, tail}
  defp improper_tail(tail), do: tail

  property "no literal crashes extraction" do
    extractors = extractors()

    check all(
            value <- odd_term(),
            max_runs: Argus.Test.Runs.max_runs(10, 30),
            max_shrinking_steps: 20
          ) do
      beams = compile(value)

      assert {:ok, facts} = Pipeline.extract(beams, extractors: extractors)
      assert Map.get(facts, :extraction_error, []) == []

      # The typed decoding every in-process consumer uses, and the rows
      # as the writer spells them.
      assert %{} = Argus.Facts.decode(facts)

      for {_relation, rows} <- facts,
          row <- rows,
          do: assert(row |> Argus.Tsv.encode_row() |> IO.iodata_to_binary() =~ ~r/\n\z/)
    end
  end

  # Logger.Translator holds improper iolists (`[prefix | "  "]`) as
  # literals; the TLS extractor, which reads every instruction of every
  # function, raised on them.
  test "a shipped module with improper literals extracts cleanly" do
    assert {:ok, facts} = Pipeline.extract([Logger.Translator], extractors: extractors())
    assert Map.get(facts, :extraction_error, []) == []
  end

  # Modules that put `value` wherever a literal is read: callback returns,
  # call arguments, patterns' comparisons, attributes, and the functions
  # Phoenix and Ecto compile to literals. One module per behaviour, since
  # their callbacks collide, and an Erlang module for an attribute whose
  # value is the term itself (Elixir wraps a persisted attribute in a
  # list).
  defp compile(value) do
    suffix = System.unique_integer([:positive])
    lit = Macro.escape(value)

    modules =
      [
        server(Module.concat(__MODULE__, "Srv#{suffix}"), lit),
        statem(Module.concat(__MODULE__, "Statem#{suffix}"), lit),
        state_functions(Module.concat(__MODULE__, "StateFns#{suffix}"), lit),
        web(Module.concat(__MODULE__, "Web#{suffix}"), lit),
        dynamic_supervisor(Module.concat(__MODULE__, "DynSup#{suffix}"), lit)
      ] ++
        for {form, n} <- Enum.with_index(supervisor_inits(lit)) do
          supervisor(Module.concat(__MODULE__, "Sup#{n}_#{suffix}"), form, lit)
        end

    {beams, _diagnostics} =
      Code.with_diagnostics(fn ->
        Enum.flat_map(modules, fn quoted ->
          quoted |> Code.compile_quoted() |> Enum.map(&elem(&1, 1))
        end)
      end)

    erlang = erlang_module(:"odd_literals_test_#{suffix}", value)

    for {:defmodule, _, [mod, _]} <- modules do
      :code.purge(mod)
      :code.delete(mod)
    end

    [erlang | beams]
  end

  defp server(name, lit) do
    quote do
      defmodule unquote(name) do
        use GenServer

        Module.register_attribute(__MODULE__, :odd, persist: true)
        @odd unquote(lit)

        def start_link(a), do: GenServer.start_link(__MODULE__, a, name: unquote(lit))
        def init(_), do: {:ok, unquote(lit), unquote(lit)}

        def handle_call(:a, _from, s), do: {:reply, unquote(lit), s, unquote(lit)}

        def handle_call(msg, from, s) do
          GenServer.reply(from, unquote(lit))
          if msg == unquote(lit), do: {:noreply, s}, else: {:stop, unquote(lit), s}
        end

        def handle_cast(m, s), do: {:noreply, [m | unquote(lit)], unquote(lit)}

        def handle_info(m, s) when m == unquote(lit), do: {:noreply, s}

        def handle_info({:DOWN, ref, _, _, _}, s) do
          Process.demonitor(ref, unquote(lit))
          {:noreply, s}
        end

        def handle_info(_m, s), do: {:stop, unquote(lit), s}

        def calls(pid, x) do
          send(pid, unquote(lit))
          send(pid, [x | unquote(lit)])
          GenServer.call(pid, unquote(lit), unquote(lit))
          GenServer.cast(pid, {unquote(lit)})
          :ets.new(:odd, unquote(lit))
          :ets.new(:odd, [x | unquote(lit)])
          :ets.insert(unquote(lit), unquote(lit))
          :ets.lookup(unquote(lit), x)
          Process.monitor(pid, unquote(lit))
          :ssl.connect(~c"h", 1, unquote(lit))
          Supervisor.start_link(unquote(lit), unquote(lit))
          DynamicSupervisor.start_child(pid, unquote(lit))
          :gen_statem.start_link(__MODULE__, unquote(lit), unquote(lit))
          spawn(__MODULE__, :calls, unquote(lit))
          spawn(__MODULE__, :calls, [x | unquote(lit)])
          Registry.register(unquote(lit), unquote(lit), [])
          :mnesia.dirty_write(unquote(lit))
          :mnesia.dirty_read(unquote(lit))
          apply(__MODULE__, :calls, unquote(lit))
          apply(__MODULE__, :calls, [x | unquote(lit)])
          Task.async(fn -> unquote(lit) end)
          :erlang.send_after(1, pid, unquote(lit))
          Process.send_after(pid, unquote(lit), 10, unquote(lit))
          :erlang.binary_to_term(x, unquote(lit))
          IO.puts(unquote(lit))
          GenServer.start_link(__MODULE__, x, unquote(lit))
          GenServer.start_link(__MODULE__, x, [x | unquote(lit)])
          Agent.start_link(fn -> x end, unquote(lit))
          DynamicSupervisor.init(unquote(lit))
          Supervisor.child_spec(unquote(lit), unquote(lit))
          Registry.start_link(unquote(lit))
          Process.flag(:trap_exit, unquote(lit))
          :timer.send_interval(10, unquote(lit))
          :erlang.start_timer(1, pid, unquote(lit))
          Process.cancel_timer(x, unquote(lit))
          Task.Supervisor.async_nolink(pid, fn -> unquote(lit) end)
          :persistent_term.put(unquote(lit), unquote(lit))
          Application.get_env(:app, unquote(lit))

          sinks = [
            String.to_atom(unquote(lit)),
            Code.eval_string(unquote(lit)),
            System.cmd(unquote(lit), unquote(lit)),
            File.read(unquote(lit))
          ]

          send(pid, sinks)
          :erpc.call(x, __MODULE__, :calls, unquote(lit))
          :rpc.call(x, __MODULE__, :calls, unquote(lit))
          Process.register(pid, unquote(lit))
          :global.register_name(unquote(lit), pid)

          receive do
            ^x -> unquote(lit)
          after
            10 -> unquote(lit)
          end

          length(unquote(lit))
          unquote(lit) ++ x
        end

        def handle_continue(_c, s), do: {:noreply, s, {:continue, unquote(lit)}}
        def terminate(_reason, _s), do: unquote(lit)
      end
    end
  end

  defp statem(name, lit) do
    quote do
      defmodule unquote(name) do
        @behaviour :gen_statem

        def callback_mode, do: unquote(lit)
        def init(_), do: {:ok, unquote(lit), unquote(lit), unquote(lit)}

        def handle_event({:call, from}, m, _s, d) when m == unquote(lit),
          do: {:keep_state, d, [{:reply, from, unquote(lit)} | unquote(lit)]}

        def handle_event(:info, _m, _s, d), do: {:next_state, unquote(lit), d, unquote(lit)}
        def handle_event(:cast, _m, _s, d), do: {:keep_state, d, [unquote(lit)]}
        def handle_event(_, _, _, d), do: {:keep_state, d, unquote(lit)}
      end
    end
  end

  defp state_functions(name, lit) do
    quote do
      defmodule unquote(name) do
        @behaviour :gen_statem

        def callback_mode, do: [:state_functions | unquote(lit)]
        def init(_), do: {:ok, :s, unquote(lit), [unquote(lit)]}

        def s({:call, from}, _m, d), do: {:keep_state, d, [{:reply, from, unquote(lit)}]}
        def s(:info, _m, d), do: {:next_state, :s, d, unquote(lit)}
        def s(_type, _m, d), do: {:next_state, unquote(lit), d, [unquote(lit)]}
      end
    end
  end

  # One init form per supervisor: the extractor reads the first tree it
  # finds, so forms sharing a module would hide one another.
  defp supervisor_inits(lit) do
    [
      quote(do: {:ok, unquote(lit)}),
      quote(do: {:ok, {unquote(lit), unquote(lit)}}),
      quote(do: {:ok, {%{strategy: :one_for_one}, unquote(lit)}}),
      quote(do: Supervisor.init(unquote(lit), strategy: :one_for_one)),
      quote(do: Supervisor.init([], unquote(lit))),
      quote(do: Supervisor.init([Argus | unquote(lit)], strategy: :one_for_one)),
      quote(do: Supervisor.init([unquote(lit)], strategy: :one_for_one)),
      quote(do: Supervisor.init([{Argus, unquote(lit)}], strategy: :one_for_one)),
      quote(do: Supervisor.init([%{id: 1, start: {Argus, :f, []}, restart: unquote(lit)}], [])),
      quote(do: Supervisor.init([], [{:strategy, unquote(lit)} | unquote(lit)]))
    ]
  end

  defp supervisor(name, form, lit) do
    quote do
      defmodule unquote(name) do
        use Supervisor

        def start_link(a), do: Supervisor.start_link(__MODULE__, a, name: unquote(lit))
        def init(_arg), do: unquote(form)
        def child_spec(_), do: unquote(lit)
        def start(_type, _args), do: Supervisor.start_link(unquote(lit), strategy: :one_for_one)
      end
    end
  end

  defp dynamic_supervisor(name, lit) do
    quote do
      defmodule unquote(name) do
        use DynamicSupervisor

        def init(_arg), do: DynamicSupervisor.init(unquote(lit))
      end
    end
  end

  defp web(name, lit) do
    quote do
      defmodule unquote(name) do
        def __sockets__, do: unquote(lit)
        def __routes__, do: unquote(lit)
        # Distinct bodies, or the compiler folds the clauses into one.
        def __schema__(:fields), do: unquote(lit)
        def __schema__(:redact_fields), do: [:redacted | unquote(lit)]
        def __schema__(:associations), do: {unquote(lit)}
        def __schema__(_), do: nil
      end
    end
  end

  defp erlang_module(name, value) do
    forms = [
      {:attribute, 1, :module, name},
      {:attribute, 1, :odd, value},
      {:attribute, 1, :export, [f: 0]},
      {:function, 1, :f, 0, [{:clause, 1, [], [], [:erl_parse.abstract(value)]}]}
    ]

    {:ok, ^name, beam} = :compile.forms(forms, [:binary, :return_errors])
    beam
  end
end
