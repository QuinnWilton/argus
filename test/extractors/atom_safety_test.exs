defmodule Argus.Extractors.ApiCalls.AtomSafetyTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ApiCalls
  alias Argus.Test.Fixtures, as: F

  # A relation's rows for a module, by function: the instruction id is
  # matched against its function rather than spelled, since its index
  # moves with the compiler.
  defp sites(mod, relation) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))

    data
    |> ApiCalls.extract()
    |> Map.get(relation, [])
    |> Enum.map(fn [id, func | rest] ->
      assert id =~ ~r/^#{Regex.escape(func)}#\d+$/
      [func |> String.split(":") |> List.last() | rest]
    end)
    |> Enum.sort()
  end

  describe "extract/1 — unsafe atom creation" do
    test "String.to_atom, binary_to_atom and list_to_atom; to_existing_atom is no sink" do
      # String.to_atom/1 is inlined to :erlang.binary_to_atom/1.
      assert sites(F.UnsafeAtomCreation, :unsafe_atom_creation) == [
               ["binary_to_atom/1", ":erlang.binary_to_atom/1"],
               ["list_to_atom/1", ":erlang.list_to_atom/1"],
               ["to_atom_from_input/1", ":erlang.binary_to_atom/1"]
             ]
    end
  end

  describe "extract/1 — one-shot decompression" do
    test "gunzip reads its first argument, inflate its second; safeInflate is no sink" do
      assert sites(F.Decompression.GzipBodyPlug, :unsafe_decompression) == [
               ["call/2", ":zlib.gunzip/1", "0"]
             ]

      assert sites(F.Decompression.FrameHandler, :unsafe_decompression) == [
               ["handle_data/3", ":zlib.inflate/2", "1"]
             ]

      assert sites(F.Decompression.BoundedFrameHandler, :unsafe_decompression) == []
    end
  end

  describe "extract/1 — unsafe deserialization" do
    test "binary_to_term/1 is unsafe, [:safe] atoms_only, a term-walking decoder validated" do
      # OTP's own docs: `safe` prevents new atoms and new EXTERNAL function
      # references, and "does not guarantee that the data is safe for your
      # application". Paginator CVE-2020-15150 is RCE through this option —
      # a base64 cursor decoded to a fun that Enumerable then invoked. The
      # fix was a validating decoder; `safe` was already present.
      assert sites(F.UnsafeDeserialization, :unsafe_deserialization) == [
               ["decode_atoms_only/1", ":erlang.binary_to_term/2", "atoms_only"],
               ["decode_unsafe/1", ":erlang.binary_to_term/1", "unsafe"],
               ["decode_validated/1", "Plug.Crypto.non_executable_binary_to_term", "validated"]
             ]
    end
  end

  describe "extract/1 — code execution" do
    test "a command or source caller data can reach; a literal one is no sink" do
      # Left out, each runs only what its literal says: literal_os_cmd/0,
      # literal_os_cmd_options/1 and literal_shell/0; System.cmd/2 with a
      # literal program that is no interpreter (static_system_cmd/0,
      # static_command_dynamic_args/1, static_command_no_args/0); and
      # found_program/1, whose program PATH finds for a literal name runs
      # only itself, its arguments argv. bash found the same way still
      # runs the script it is handed, as a literal sh handed one does.
      assert sites(F.CodeExecution, :code_execution) == [
               ["branch_os_cmd/2", ":os.cmd/1"],
               ["dynamic_shell/1", "System.shell/1"],
               ["eval/1", "Code.eval_string/1"],
               ["found_shell/1", "System.cmd/2"],
               ["nested_os_cmd/1", ":os.cmd/1"],
               ["os_cmd/1", ":os.cmd/1"],
               ["partial_os_cmd/1", ":os.cmd/1"],
               ["shell_with_dynamic_script/1", "System.cmd/2"],
               ["system_cmd/2", "System.cmd/2"]
             ]
    end
  end
end
