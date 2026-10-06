defmodule Argus.Clientlib.DictionaryTest do
  @moduledoc """
  The process dictionary: a value put under a literal key and read back
  in the same process is the same value (processes.dl's `dict` source,
  read here through tables.dl's table identity), a table only its maker
  keeps is private to it (kept_in_dictionary), and a table an operation
  names only while a key is unset is set aside where the key was set
  first (clientlib/dictionary.dl's skips_default).
  """
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.{Pipeline, Souffle}
  alias Argus.Test.Fixtures.Dictionary

  @modules [
    Dictionary.TmpOptions,
    Dictionary.CallerTable,
    Dictionary.SharedCallerTable,
    Dictionary.OwnTable,
    Dictionary.OtherProcess,
    Dictionary.ComputedKey
  ]

  defp priv_dl, do: Path.join(:code.priv_dir(:argus_beam), "dl")

  setup_all do
    tmp_dir =
      Path.join(System.tmp_dir!(), "dictionary_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    facts_dir = Path.join(tmp_dir, "facts")
    {:ok, _} = Pipeline.run(@modules, facts_dir, extractors: Argus.Analyses.Races.extractors())
    :ok = Argus.Analysis.derive_stage0(facts_dir)
    :ok = Argus.Analysis.derive_points_to(facts_dir)

    rules_path = Path.join(tmp_dir, "dictionary.dl")

    File.write!(rules_path, """
    .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/otp.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/vocabulary.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/tables.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/order.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/dictionary.dl")}"

    .decl op_table(func: symbol, op: symbol, kind: symbol, ident: symbol)
    .output op_table
    op_table(f, o, k, t) :- ets_op(id, f, _, o, _), ets_table(id, k, t).

    .decl op_any(func: symbol, op: symbol)
    .output op_any
    op_any(f, o) :- ets_op(id, f, _, o, _), may_touch_any_table(id).

    .decl kept(func: symbol)
    .output kept
    kept(f) :- kept_by_its_process("new", n), ets_new(n, f, _).

    .decl public(func: symbol)
    .output public
    public(f) :- table_public("new", n), ets_new(n, f, _).

    .decl skipped(func: symbol, op_func: symbol, name: symbol)
    .output skipped
    skipped(f, g, name) :- skips_default(f, op, ["named", name]), ets_op(op, g, _, _, _).
    """)

    out = Path.join(tmp_dir, "out")
    File.mkdir_p!(out)
    {:ok, results} = Souffle.run(facts_dir, rules_path, output_dir: out)
    %{r: results}
  end

  defp tables(r, func_part, op) do
    for [f, o, k, t] <- r["op_table"], f =~ func_part, o == op, uniq: true, do: {k, t}
  end

  defp any?(r, func_part, op),
    do: Enum.any?(r["op_any"], fn [f, o] -> f =~ func_part and o == op end)

  defp made_in?(r, relation, func_part), do: Enum.any?(r[relation], fn [f] -> f =~ func_part end)

  describe "a value read back from the dictionary" do
    test "is what the same process put: the operand names the table made", %{r: r} do
      # set_option/2 reads the key through a helper; the default arm names
      # the options table beside it.
      assert [{"named", ":dict_options"}, {"new", site}] =
               Enum.sort(tables(r, "TmpOptions:set_option", "insert"))

      assert site =~ "TmpOptions:create_tmp"
    end

    test "a server's callback reads back what its init/1 put", %{r: r} do
      assert [{"new", site}] = tables(r, "OwnTable:handle_call", "update_counter")
      assert site =~ "OwnTable:init"
      refute any?(r, "OwnTable:handle_call", "update_counter")
    end

    test "a key another process put names nothing", %{r: r} do
      assert tables(r, "OtherProcess:count", "update_counter") == []
      assert any?(r, "OtherProcess:count", "update_counter")
    end

    test "a key computed at run time is not followed, a literal one is", %{r: r} do
      assert tables(r, "ComputedKey:run/2", "insert") == []
      assert any?(r, "ComputedKey:run/2", "insert")
      assert [{"new", site}] = tables(r, "ComputedKey:run_literal", "insert")
      assert site =~ "ComputedKey:run_literal"
    end
  end

  describe "a table its maker keeps in its dictionary" do
    test "is private to it when its reference goes nowhere else", %{r: r} do
      assert made_in?(r, "kept", "CallerTable:table")
      refute made_in?(r, "public", "Dictionary.CallerTable:table")
      assert made_in?(r, "kept", "OwnTable:init")
    end

    test "is not, once the reference is sent to another process", %{r: r} do
      refute made_in?(r, "kept", "SharedCallerTable:table")
      assert made_in?(r, "public", "SharedCallerTable:table")
    end

    test "is its maker's alone when no read of its process takes it back", %{r: r} do
      assert made_in?(r, "kept", "OtherProcess:init")
    end
  end

  describe "a table named only while a key is unset" do
    test "is set aside where the key was set first", %{r: r} do
      ops =
        for [f, g, ":dict_options"] <- r["skipped"], f =~ "TmpOptions:validate", uniq: true, do: g

      assert Enum.any?(ops, &(&1 =~ "TmpOptions:set_option"))
      assert Enum.any?(ops, &(&1 =~ "TmpOptions:get_option"))
    end

    test "is kept where nothing set the key, or an erase undid it", %{r: r} do
      refute Enum.any?(r["skipped"], fn [f, _, _] -> f =~ "TmpOptions:reload" end)
      refute Enum.any?(r["skipped"], fn [f, _, _] -> f =~ "TmpOptions:abort" end)
    end
  end
end
