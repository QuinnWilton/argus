defmodule Argus.Extractor.ClauseCallTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ClauseCall
  alias Argus.Pipeline.Disassemble
  alias Argus.Test.Fixtures.ClauseCall.{Router, Server}

  # callee function name => the tags the call to it serves, keyed by
  # each call site's own remote_call row.
  setup_all do
    {:ok, facts} =
      Argus.Pipeline.extract([Server, Router], extractors: [Argus.Extractors.ClauseCall])

    callee_at =
      for [id, _caller, "Argus.Test.Fixtures.ClauseCall.Dest", func, _arity] <-
            Map.fetch!(facts, :remote_call),
          into: %{},
          do: {id, func}

    tags =
      facts
      |> Map.get(:clause_call, [])
      |> Enum.flat_map(fn [id, _func, tag] ->
        case Map.fetch(callee_at, id) do
          {:ok, callee} -> [{callee, tag}]
          :error -> []
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {callee, tags} -> {callee, Enum.sort(tags)} end)

    %{tags: tags}
  end

  test "a call in a clause headed by a tuple serves that tuple's tag", %{tags: tags} do
    assert tags["tuple_tag"] == [":tuple_tag"]
  end

  test "a call in a clause headed by an atom serves that atom", %{tags: tags} do
    assert tags["bare_atom"] == [":bare_atom"]
  end

  test "a clause guarded over several tags serves each of them", %{tags: tags} do
    assert tags["either"] == [":left", ":right"]
  end

  test "two clauses of one tag, told apart by the state, both serve it", %{tags: tags} do
    assert tags["ready"] == [":twice"]
    assert tags["not_ready"] == [":twice"]
  end

  test "a case on the request in the body refines like a clause head", %{tags: tags} do
    assert tags["cased"] == [":cased"]
  end

  test "a call some path reaches with no tag established has no row", %{tags: tags} do
    refute Map.has_key?(tags, "fallback")
  end

  test "a plain function's clauses are told apart by their first argument", %{tags: tags} do
    assert tags["local"] == [":local"]
    assert tags["remote"] == [":remote"]
  end

  test "a call a helper makes has no site in handle_call/3", %{tags: tags} do
    refute Map.has_key?(tags, "helper")
  end

  describe "info_clause_always" do
    alias Argus.Test.Fixtures.TimerLoop, as: T

    # The callees of the handle_info/2 sites that run on every path of
    # their clause that goes on.
    defp always(mod) do
      {:ok, facts} = Argus.Pipeline.extract([mod], extractors: [Argus.Extractors.ClauseCall])

      always =
        facts |> Map.get(:info_clause_always, []) |> Map.new(fn [id, _f, tag] -> {id, tag} end)

      for [id, _caller, callee_mod, func, _arity] <- Map.fetch!(facts, :remote_call),
          tag = Map.get(always, id),
          do: {callee_mod, func, tag}
    end

    test "a re-arm on the clause's one path is always; one on a branch is not" do
      # The badmap raise the compiler puts after `state.interval` is no
      # completion.
      # Process.send_after/3, which Elixir up to 1.19 inlines to :erlang's.
      assert Enum.any?(always(T.ReloadLoop), &match?({_, "send_after", ":reload"}, &1))

      refute Enum.any?(always(T.RetryLoop), &match?({_, "send_after", _}, &1))
    end

    # The local functions the always-sites of `mod`'s handle_info/2 call.
    defp always_local(mod) do
      {:ok, data} = Disassemble.disassemble_path(File.read!(:code.which(mod)))
      facts = ClauseCall.extract(data)

      {:function, _, _, _, instrs} =
        Enum.find(data.functions, &match?({:function, :handle_info, 2, _, _}, &1))

      for [id, _func, _tag] <- Map.get(facts, :info_clause_always, []),
          {:ok, %{idx: idx}} = Argus.InstrId.parse(id),
          {:ok, _m, f, _a} <- [Argus.Extractor.Helpers.match_local_call(Enum.at(instrs, idx))],
          do: f
    end

    test "the sites of one clause that call one function are always together" do
      # ant's three :check_workers clauses each call schedule_check/1.
      assert Enum.count(always_local(T.ThreeClauseLoop), &(&1 == :schedule_check)) == 3
    end

    test "a failure handed to handle_continue/2 leaves the loop to the continue" do
      # xandra: re-armed on success, {:continue, {:disconnected, r}} on error.
      assert :schedule_refresh in always_local(T.ContinueOnError)

      # The same, from a `with`'s `else`, which the compiler lifts into a
      # local fun the clause tail-calls.
      assert :schedule_refresh in always_local(T.WithElseContinue)
    end

    test "a return of {:stop, ...} leaves the loop, and does not count" do
      [{_mod, bin}] =
        Code.compile_string("""
        defmodule Argus.ClauseCallTest.StopsOnError do
          use GenServer
          def init(s), do: {:ok, s}

          def handle_info(:tick, state) do
            case Application.get_env(:probe, :ok, :ok) do
              :ok ->
                Process.send_after(self(), :tick, 1000)
                {:noreply, state}

              reason ->
                {:stop, reason, state}
            end
          end
        end
        """)

      {:ok, data} = Disassemble.disassemble_path(bin)

      assert [[_id, _func, ":tick"] | _] =
               ClauseCall.extract(data)
               |> Map.get(:info_clause_always, [])
               |> Enum.filter(fn [id, _, _] -> String.contains?(id, "handle_info") end)
    end

    test "an Erlang send is a site of its clause" do
      {:ok, facts} =
        Argus.Pipeline.extract([:timer_loop_resend], extractors: [Argus.Extractors.ClauseCall])

      # The `!` in the clause for `report` is that clause's.
      assert Enum.any?(facts[:clause_call], fn [id, _f, tag] ->
               tag == ":report" and String.contains?(id, "handle_info")
             end)
    end
  end
end
