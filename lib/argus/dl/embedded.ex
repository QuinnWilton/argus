defmodule Argus.Dl.Embedded do
  @moduledoc """
  argus's Datalog rules (`priv/dl`), carried in this module's code as
  one gzipped literal, for a build with no priv directory on disk (an
  escript). `Argus.Dl.root/0` unpacks them when it needs a directory.

  The tree is read when this module compiles, and each file is an
  external resource: an edit to a rule recompiles it, and moves the
  tree's digest (`digest/0`), which names the directory it unpacks to.
  """

  alias Argus.EmbeddedTree

  @dl Path.expand("../../../priv/dl", __DIR__)

  @files EmbeddedTree.read(@dl, [])

  for {relative, _content} <- @files do
    @external_resource Path.join(@dl, relative)
  end

  @digest EmbeddedTree.digest(@files)
  @payload EmbeddedTree.pack(@files)

  # A rule added to or removed from the tree changes no file this module
  # names as a resource: its listing does.
  @paths Enum.map(@files, &elem(&1, 0))

  @doc false
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__?, do: EmbeddedTree.listing(@dl, []) != @paths

  @doc "The digest of the tree of rules: every file by its path and content."
  @spec digest() :: String.t()
  def digest, do: @digest

  @doc "Every file of the tree, by its path relative to `dl/`, with its content."
  @spec files() :: EmbeddedTree.files()
  def files, do: EmbeddedTree.unpack(@payload)

  @doc "The tree unpacked under `base`, at `<base>/<digest>` (`Argus.EmbeddedTree.unpack!/4`)."
  @spec unpack!(Path.t()) :: Path.t()
  def unpack!(base),
    do: EmbeddedTree.unpack!(base, @digest, files(), "install argus's Datalog rules at")
end
