defmodule Argus.Locate.Source.Opaque do
  @moduledoc """
  The rules for a file argus cannot read as source: a beam (the anchor
  of a module that recorded no source file), or a language it has no
  rules for. Every place stays where the bytecode put it: no fragment
  moves a line, no block closes a span, and a guard is a `handler`.
  """

  @behaviour Argus.Locate.Source

  @impl true
  def line(_path, line), do: line

  @impl true
  def refine(_path, line, _fragment), do: line

  @impl true
  def block_end(_path, _line, _block), do: nil

  @impl true
  def guard_keyword(_path, _line), do: nil
end
