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
  def decode_safe(bin), do: :erlang.binary_to_term(bin, [:safe])
end

defmodule Argus.Test.Fixtures.CodeExecution do
  @moduledoc false

  def eval(code), do: Code.eval_string(code)
  def os_cmd(cmd), do: :os.cmd(cmd)
  def system_cmd(cmd, args), do: System.cmd(cmd, args)
end

defmodule Argus.Test.Fixtures.SafeModule do
  @moduledoc false

  def to_existing_atom(input), do: String.to_existing_atom(input)
  def safe_decode(bin), do: :erlang.binary_to_term(bin, [:safe])
  def hello, do: :world
end
