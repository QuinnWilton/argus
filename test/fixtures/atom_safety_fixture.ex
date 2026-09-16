defmodule Argus.Test.Fixtures.UnsafeAtomCreation do
  @moduledoc false

  def to_atom_from_input(input), do: String.to_atom(input)
  def binary_to_atom(bin), do: :erlang.binary_to_atom(bin)
  def list_to_atom(list), do: :erlang.list_to_atom(list)
  def existing_atom(bin), do: String.to_existing_atom(bin)
end

defmodule Argus.Test.Fixtures.UnsafeDeserialization do
  @moduledoc false

  def decode_unsafe(bin), do: :erlang.binary_to_term(bin)
  # Named for what the option does, not for what it is often assumed to do.
  # `[:safe]` blocks new atoms and new EXTERNAL funs; a fun referencing an
  # already-loaded module passes, which is how Paginator CVE-2020-15150 was
  # RCE *through* this option.
  def decode_atoms_only(bin), do: :erlang.binary_to_term(bin, [:safe])

  # The one that actually clears: it walks the term and rejects executable
  # constructors rather than trusting an option.
  def decode_validated(bin), do: Plug.Crypto.non_executable_binary_to_term(bin, [:safe])
end

defmodule Argus.Test.Fixtures.CodeExecution do
  @moduledoc false

  def eval(code), do: Code.eval_string(code)
  def os_cmd(cmd), do: :os.cmd(cmd)
  def system_cmd(cmd, args), do: System.cmd(cmd, args)
  def static_system_cmd, do: System.cmd("echo", ["hello"])
  def static_command_dynamic_args(args), do: System.cmd("fwup", args)
  def static_command_no_args, do: System.cmd("free", [])
  def shell_with_dynamic_script(script), do: System.cmd("sh", ["-c", script])
end

defmodule Argus.Test.Fixtures.SafeModule do
  @moduledoc false

  def to_existing_atom(input), do: String.to_existing_atom(input)
  def safe_decode(bin), do: Plug.Crypto.non_executable_binary_to_term(bin, [:safe])
  def hello, do: :world
end
