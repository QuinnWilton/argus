defmodule Argus.DlDeclarationsTest do
  @moduledoc """
  Guards the link between `Argus.Schema` and the Souffle declarations.

  Fact declarations are positional. `.decl remote_call(id: symbol, mod:
  symbol, ...)` has to agree with the column order `Argus.Pipeline.Emit`
  writes, and Souffle cannot check that — two `symbol` columns swapped
  parse fine and silently join the wrong values, producing findings that
  are wrong rather than absent. Before these files were generated, the
  declarations were the one part of the schema with no mechanical link
  back to it: 95 hand-written `.input` declarations of 50 distinct
  relations across 19 files.
  """

  use ExUnit.Case, async: true

  alias Argus.{Analysis, Schema, Souffle}

  defp priv_dl, do: Path.join(:code.priv_dir(:argus), "dl")

  describe "generated declaration files" do
    test "base.dl matches Argus.Schema.layer_1/0" do
      assert File.read!(Path.join(priv_dl(), "base.dl")) == Schema.souffle_decls(:layer_1),
             "priv/dl/base.dl is stale — run `mix argus.gen.dl` and commit the result"
    end

    test "layer2.dl matches Argus.Schema.layer_2/0" do
      assert File.read!(Path.join(priv_dl(), "layer2.dl")) == Schema.souffle_decls(:layer_2),
             "priv/dl/layer2.dl is stale — run `mix argus.gen.dl` and commit the result"
    end

    test "every schema relation is declared exactly once across the generated files" do
      declared =
        [:layer_1, :layer_2]
        |> Enum.flat_map(fn layer ->
          Regex.scan(~r/^\.decl\s+([a-z_0-9]+)\(/m, Schema.souffle_decls(layer))
          |> Enum.map(fn [_, name] -> String.to_atom(name) end)
        end)

      assert Enum.sort(declared) == Enum.sort(Schema.names())
      assert length(Enum.uniq(declared)) == length(declared), "a relation is declared twice"
    end
  end

  describe "hand-written declarations" do
    test "no rules file redeclares a schema relation" do
      generated = ["base.dl", "layer2.dl"]
      schema_names = MapSet.new(Schema.names(), &to_string/1)

      offenders =
        priv_dl()
        |> Path.join("**/*.dl")
        |> Path.wildcard()
        |> Enum.reject(&(Path.basename(&1) in generated))
        |> Enum.flat_map(fn path ->
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} ->
            case Regex.run(~r/^\.decl\s+([a-z_0-9]+)\s*\(/, line) do
              [_, name] -> MapSet.member?(schema_names, name)
              nil -> false
            end
          end)
          |> Enum.map(fn {line, n} -> "#{Path.relative_to(path, priv_dl())}:#{n}  #{line}" end)
        end)

      assert offenders == [],
             "these declarations duplicate the schema and can drift from it:\n" <>
               Enum.join(offenders, "\n") <>
               "\n\nInclude base.dl / layer2.dl instead."
    end
  end

  describe "partial functors" do
    # `to_number` and `substr` abort the whole program on input they cannot
    # handle, rather than failing the one rule. A guard in a sibling
    # conjunct does not protect them: Souffle promises no conjunct order,
    # and the magic-set transform demonstrably reorders — seven of sixteen
    # analyses aborted with `to_number("mic")` before the forwarding
    # encoding moved out of a string and into its own number column.
    #
    # This is a static check on purpose. Reproducing the abort needs a real
    # corpus, but the property worth keeping is simply that no rule reaches
    # for a partial functor in the first place.
    @partial_functors ~w(to_number substr)

    test "no rule uses a partial string functor" do
      offenders =
        priv_dl()
        |> Path.join("**/*.dl")
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.reject(fn {line, _} -> String.starts_with?(String.trim(line), "//") end)
          |> Enum.filter(fn {line, _} ->
            Enum.any?(@partial_functors, &String.contains?(line, &1 <> "("))
          end)
          |> Enum.map(fn {line, n} ->
            "#{Path.relative_to(path, priv_dl())}:#{n}  #{String.trim(line)}"
          end)
        end)

      assert offenders == [],
             "these rules call a functor that aborts the program on bad input:\n" <>
               Enum.join(offenders, "\n") <>
               "\n\nEncode the structure as a column instead of parsing it back " <>
               "out of a string. A guard in a sibling conjunct is not a " <>
               "precondition — Souffle may schedule the functor first."
    end
  end

  describe "analysis input sets" do
    # Resolved from Souffle's own transformed RAM, so this is what each
    # analysis genuinely reads, not what it declares — declaring the whole
    # schema is free precisely because Souffle prunes input relations no
    # rule touches, and this test is the evidence for that claim.
    #
    # Pinned deliberately. These sets are the unit of incremental work: a
    # consumer re-solves an analysis when any relation here changes, so an
    # accidental widening is a silent latency regression and a deliberate
    # narrowing is the entire point of the work in flight. Either way it
    # should be visible in a diff.
    @expected %{
      atom_safety: ~w(call_edge code_execution function_def unsafe_atom_creation
                      unsafe_deserialization),
      call_cycle:
        ~w(call_arg call_arg_forward call_edge function_def implements_behaviour sync_call),
      coverage: ~w(async_cast dynamic_child ets_new ets_op function_def implements_behaviour
                   imprecision named_process supervisor supervisor_child sync_call),
      deferred_startup_deadlock:
        ~w(call_arg call_arg_forward call_edge handle_continue_clause init_continues_to
           supervisor supervisor_child sync_call try_start),
      distributed: ~w(call_edge distributed_store_op function_def global_op global_register
                      implements_behaviour node_operation rpc_call),
      error_handling: ~w(bare_rescue call_edge exit_call function_def ignored_error_result
                         implements_behaviour trap_exit),
      ets: ~w(dynamic_child ets_new ets_op ets_option function_def implements_behaviour
              supervisor_child),
      gen_statem: ~w(statem_initial statem_module statem_state statem_transition),
      one_for_one_coupling:
        ~w(async_cast call_arg call_arg_forward call_edge dynamic_child function_def
                               implements_behaviour process_link supervisor supervisor_child
                               supervisor_site sync_call),
      process_bottleneck:
        ~w(call_arg call_arg_forward call_edge function_def implements_behaviour sync_call),
      process_registry: ~w(function_def process_register whereis_call),
      request_surface: ~w(call_edge code_execution function_def implements_behaviour
                          unsafe_atom_creation unsafe_deserialization),
      supervision: ~w(async_cast call_arg call_arg_forward call_edge dynamic_child function_def
                      implements_behaviour supervisor supervisor_child supervisor_site sync_call),
      sync_call_in_init:
        ~w(call_arg call_arg_forward call_edge dynamic_child function_def implements_behaviour
                            supervisor supervisor_child sync_call),
      timeout_chain:
        ~w(call_arg call_arg_forward call_edge function_def implements_behaviour sync_call
                        sync_call_timeout),
      unlinked_spawn: ~w(spawn_call),
      unsafe_task:
        ~w(call_edge call_followed_by_branch function_def implements_behaviour remote_call
           tail_call)
    }

    setup do
      unless Souffle.available?(), do: ExUnit.configure(exclude: [souffle: true])
      :ok
    end

    @tag :souffle
    test "each built-in analysis reads exactly the relations it is pinned to" do
      for mod <- Analysis.builtin_analysis_modules() do
        name = mod.name()
        assert {:ok, actual} = Analysis.input_relations(name)

        expected = Map.fetch!(@expected, name)

        assert Enum.sort(actual) == Enum.sort(expected),
               "#{name} input set changed\n" <>
                 "  added:   #{inspect(actual -- expected)}\n" <>
                 "  removed: #{inspect(expected -- actual)}"
      end
    end

    @tag :souffle
    test "the pin covers every built-in analysis" do
      names = Enum.map(Analysis.builtin_analysis_modules(), & &1.name())
      assert Enum.sort(names) == Enum.sort(Map.keys(@expected))
    end

    @tag :souffle
    test "no analysis reads the instruction relation" do
      # `instruction` is the largest relation by far — 343k rows on a
      # 531-module project — and every row of it moves whenever any function
      # body changes, because an instruction's ID is a raw per-function
      # offset. Any analysis reading it re-solves on every body edit
      # anywhere in the project, and serializes tens of megabytes to do so.
      #
      # Fourteen `instruction(...)` uses in the rule corpus are now zero.
      # Twelve were decoding a call's containing function out of its
      # instruction ID; the call relations carry `caller` themselves now.
      # The last two compared instruction INDEXES to ask whether a branch
      # follows a call, which the emitter answers directly as
      # `call_followed_by_branch`.
      #
      # `instruction` is still emitted and still used — Argus.Cfg,
      # Argus.Dataflow and gloss all need it — but no Datalog rule does, so
      # it no longer gates any analysis's incrementality.
      readers =
        for mod <- Analysis.builtin_analysis_modules(),
            {:ok, rels} = Analysis.input_relations(mod.name()),
            "instruction" in rels,
            do: mod.name()

      assert readers == []
    end
  end
end
