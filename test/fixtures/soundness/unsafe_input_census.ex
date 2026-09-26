defmodule Argus.Test.Soundness.Census.UnsafeInput do
  @moduledoc """
  The exclusion census's unsafe_input hole (docs/design/exclusions.md,
  "Soundness surprises") and its adversarial neighbours: a protocol's
  implementation was never a way in, though the program's own protocol
  relays its users' data to each one. Asserted by
  test/soundness/unsafe_input_test.exs.
  """
end

defprotocol Argus.Test.Soundness.Census.UnsafeInput.Key do
  @moduledoc "The census program: a library's key protocol its users call with their data."
  @doc "Turns a key into the atom the library indexes by."
  def to_key(v)
end

defimpl Argus.Test.Soundness.Census.UnsafeInput.Key, for: BitString do
  def to_key(s), do: String.to_atom(s)
end

defimpl Argus.Test.Soundness.Census.UnsafeInput.Key, for: Atom do
  def to_key(a), do: a
end

defmodule Argus.Test.Soundness.Census.UnsafeInput.Named do
  @moduledoc "A struct its users fill."
  defstruct [:name]
end

defprotocol Argus.Test.Soundness.Census.UnsafeInput.Label do
  @moduledoc "A protocol of two arguments, implemented for a struct."
  def label(v, prefix)
end

defimpl Argus.Test.Soundness.Census.UnsafeInput.Label,
  for: Argus.Test.Soundness.Census.UnsafeInput.Named do
  def label(%{name: name}, prefix), do: String.to_atom(prefix <> name)
end

defimpl String.Chars, for: Argus.Test.Soundness.Census.UnsafeInput.Named do
  # Quiet: an implementation of a protocol the program does not define is
  # the runtime's to call, with the program's own values.
  def to_string(%{name: name}), do: Atom.to_string(String.to_atom(name))
end
