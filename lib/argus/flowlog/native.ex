defmodule Argus.FlowLog.Native do
  @moduledoc """
  The Rust sources argus builds its FlowLog toolchain from
  (`native/flowlog`), carried in this module's code as one gzipped
  literal, the way `Argus.Dl.Embedded` carries the rules: a Mix build, a
  Hex dependency and an escript all build from the same bytes.

    * `tool/` — `argus-flowlog-tool`: inspects a program (its inputs and
      outputs, or the diagnostic that rejects it) and generates the
      sources of the engine that hosts it.
    * `engine/` — the engine template: the host every program's engine
      shares, completed per program by the tool's generated module and
      glue.

  Both pin FlowLog to one revision and carry their `Cargo.lock`, so every
  machine builds the same toolchain from the same sources. `digest/0`
  names them, and with them what a solve of any program means: it is part
  of every program's digest (`Argus.Graph.Programs`).
  """

  alias Argus.EmbeddedTree

  @native Path.expand("../../../native/flowlog", __DIR__)

  # Only sources travel: a developer's `target/` or a generated module in
  # the template are build products.
  @except ["target/", "engine/src/program.rs", "engine/src/glue.rs"]

  @files EmbeddedTree.read(@native, @except)

  for {relative, _content} <- @files do
    @external_resource Path.join(@native, relative)
  end

  @digest EmbeddedTree.digest(@files)
  @payload EmbeddedTree.pack(@files)
  @paths Enum.map(@files, &elem(&1, 0))

  @doc false
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__?, do: EmbeddedTree.listing(@native, @except) != @paths

  @doc "The digest of the toolchain's sources: every file by its path and content."
  @spec digest() :: String.t()
  def digest, do: @digest

  @doc "Every source file, by its path relative to `native/flowlog`, with its content."
  @spec files() :: EmbeddedTree.files()
  def files, do: EmbeddedTree.unpack(@payload)

  @doc """
  The FlowLog revision the toolchain pins, as its `Cargo.toml`s name it.
  """
  @spec flowlog_revision() :: String.t()
  def flowlog_revision do
    {_, manifest} = List.keyfind(files(), "engine/Cargo.toml", 0)
    [_, rev] = Regex.run(~r/flowlog-runtime = \{[^}]*rev = "([^"]+)"/, manifest)
    rev
  end

  @doc "The sources unpacked under `base`, at `<base>/<digest>` (`Argus.EmbeddedTree.unpack!/4`)."
  @spec unpack!(Path.t()) :: Path.t()
  def unpack!(base),
    do: EmbeddedTree.unpack!(base, @digest, files(), "install the FlowLog toolchain sources at")
end
