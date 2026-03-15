defmodule Argus.LLM.EnrichTest do
  use ExUnit.Case

  alias Argus.LLM.Enrich

  @mock_llm Path.expand("../support/mock_llm.sh", __DIR__)

  setup do
    tmp = Path.join(System.tmp_dir!(), "argus_enrich_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_cleanup(fn -> File.rm_rf!(tmp) end)

    {:ok, facts_dir: tmp}
  end

  defp on_cleanup(fun) do
    ExUnit.Callbacks.on_exit(fun)
  end

  describe "scan_dynamic_sites/1" do
    test "finds dynamic values in sync_call facts", %{facts_dir: dir} do
      File.write!(Path.join(dir, "sync_call.facts"), "MyMod:handle_call/3\tdynamic\n")

      assert {:ok, [site]} = Enrich.scan_dynamic_sites(dir)
      assert site.relation == "sync_call"
      assert site.field_idx == 1
      assert site.func_id == "MyMod:handle_call/3"
    end

    test "finds dynamic values in ets_new facts", %{facts_dir: dir} do
      File.write!(Path.join(dir, "ets_new.facts"), "instr_1\tMyMod:init/1\tdynamic\n")

      assert {:ok, [site]} = Enrich.scan_dynamic_sites(dir)
      assert site.relation == "ets_new"
      assert site.field_idx == 2
      assert site.func_id == "MyMod:init/1"
    end

    test "ignores non-dynamic values", %{facts_dir: dir} do
      File.write!(Path.join(dir, "sync_call.facts"), "MyMod:handle_call/3\tOtherMod\n")

      assert {:ok, []} = Enrich.scan_dynamic_sites(dir)
    end

    test "handles missing facts files gracefully", %{facts_dir: dir} do
      # No files at all — should return empty.
      assert {:ok, []} = Enrich.scan_dynamic_sites(dir)
    end

    test "finds multiple dynamic sites across relations", %{facts_dir: dir} do
      File.write!(Path.join(dir, "sync_call.facts"), "Func1\tdynamic\nFunc2\tActual\n")
      File.write!(Path.join(dir, "async_cast.facts"), "Func3\tdynamic\n")

      assert {:ok, sites} = Enrich.scan_dynamic_sites(dir)
      assert length(sites) == 2

      relations = Enum.map(sites, & &1.relation) |> Enum.sort()
      assert relations == ["async_cast", "sync_call"]
    end
  end

  describe "build_prompt/1" do
    test "includes site context" do
      sites = [
        %{
          relation: "sync_call",
          field_idx: 1,
          field_desc: "GenServer target module",
          func_id: "MyMod:handle_call/3",
          context_instructions: ["#1: move", "#2: call_ext"]
        }
      ]

      prompt = Enrich.build_prompt(sites)
      assert prompt =~ "Site 1"
      assert prompt =~ "MyMod:handle_call/3"
      assert prompt =~ "GenServer target module"
      assert prompt =~ "#1: move"
    end

    test "handles multiple sites" do
      sites = [
        %{
          relation: "sync_call",
          field_idx: 1,
          field_desc: "GenServer target module",
          func_id: "Func1",
          context_instructions: ["#1: move"]
        },
        %{
          relation: "ets_new",
          field_idx: 2,
          field_desc: "ETS table name atom",
          func_id: "Func2",
          context_instructions: ["#5: put_tuple2"]
        }
      ]

      prompt = Enrich.build_prompt(sites)
      assert prompt =~ "Site 1"
      assert prompt =~ "Site 2"
    end
  end

  describe "enrich/2" do
    @tag :llm
    test "replaces dynamic values with enriched ones", %{facts_dir: dir} do
      # Write sync_call with a dynamic value.
      File.write!(Path.join(dir, "sync_call.facts"), "MyMod:handle_call/3\tdynamic\n")

      # Write minimal instruction context.
      File.write!(Path.join(dir, "instruction.facts"), "i1\tMyMod:handle_call/3\t0\tmove\n")
      File.write!(Path.join(dir, "move.facts"), "i1\tx3\tx0\n")
      File.write!(Path.join(dir, "literal_value.facts"), "")

      assert :ok = Enrich.enrich(dir, llm_bin: @mock_llm)

      {:ok, content} = File.read(Path.join(dir, "sync_call.facts"))
      assert content =~ "~MockModule"
      refute content =~ "\tdynamic"
    end

    @tag :llm
    test "preserves non-dynamic rows", %{facts_dir: dir} do
      facts = "Func1\tActualMod\nFunc2\tdynamic\n"
      File.write!(Path.join(dir, "sync_call.facts"), facts)
      File.write!(Path.join(dir, "instruction.facts"), "i1\tFunc2\t0\tmove\n")
      File.write!(Path.join(dir, "move.facts"), "")
      File.write!(Path.join(dir, "literal_value.facts"), "")

      assert :ok = Enrich.enrich(dir, llm_bin: @mock_llm)

      {:ok, content} = File.read(Path.join(dir, "sync_call.facts"))
      assert content =~ "Func1\tActualMod"
    end

    test "is a no-op with no dynamic values", %{facts_dir: dir} do
      File.write!(Path.join(dir, "sync_call.facts"), "Func1\tActualMod\n")

      assert :ok = Enrich.enrich(dir, llm_bin: @mock_llm)

      {:ok, content} = File.read(Path.join(dir, "sync_call.facts"))
      assert content == "Func1\tActualMod\n"
    end

    @tag :llm
    test "writes audit log when enrich_audit: true", %{facts_dir: dir} do
      File.write!(Path.join(dir, "sync_call.facts"), "MyMod:handle_call/3\tdynamic\n")
      File.write!(Path.join(dir, "instruction.facts"), "i1\tMyMod:handle_call/3\t0\tmove\n")
      File.write!(Path.join(dir, "move.facts"), "i1\tx3\tx0\n")
      File.write!(Path.join(dir, "literal_value.facts"), "")

      assert :ok = Enrich.enrich(dir, llm_bin: @mock_llm, enrich_audit: true)

      audit_path = Path.join(dir, "_enrich_audit.tsv")
      assert File.exists?(audit_path)

      {:ok, content} = File.read(audit_path)
      # Header row.
      assert content =~ "relation\tfunc_id\tfield\toriginal\tresolved\tcontext"
      # Data row with the resolution.
      assert content =~ "sync_call\tMyMod:handle_call/3"
      assert content =~ "~MockModule"
    end

    @tag :llm
    test "writes audit log to custom path", %{facts_dir: dir} do
      File.write!(Path.join(dir, "sync_call.facts"), "MyMod:handle_call/3\tdynamic\n")
      File.write!(Path.join(dir, "instruction.facts"), "i1\tMyMod:handle_call/3\t0\tmove\n")
      File.write!(Path.join(dir, "move.facts"), "")
      File.write!(Path.join(dir, "literal_value.facts"), "")

      custom_path = Path.join(dir, "my_audit.tsv")
      assert :ok = Enrich.enrich(dir, llm_bin: @mock_llm, enrich_audit: custom_path)

      assert File.exists?(custom_path)
      refute File.exists?(Path.join(dir, "_enrich_audit.tsv"))
    end

    test "no audit log when enrich_audit not set", %{facts_dir: dir} do
      File.write!(Path.join(dir, "sync_call.facts"), "Func1\tActualMod\n")

      assert :ok = Enrich.enrich(dir, llm_bin: @mock_llm)

      refute File.exists?(Path.join(dir, "_enrich_audit.tsv"))
    end

    test "audit log is header-only when no dynamic sites exist", %{facts_dir: dir} do
      File.write!(Path.join(dir, "sync_call.facts"), "Func1\tActualMod\n")

      assert :ok = Enrich.enrich(dir, llm_bin: @mock_llm, enrich_audit: true)

      audit_path = Path.join(dir, "_enrich_audit.tsv")
      assert File.exists?(audit_path)

      {:ok, content} = File.read(audit_path)
      assert content == "relation\tfunc_id\tfield\toriginal\tresolved\tcontext\n\n"
    end
  end
end
