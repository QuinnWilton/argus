defmodule Argus.Test.Fixtures.BoundedConversion do
  @moduledoc false
  # Pure calls on values the program bounded keep the bound: the image of a
  # finite set under a function of its arguments alone is finite. Each safe
  # shape has a twin whose input is open, which stays reported.

  # ex_zarr's codec table: one of the guard's atoms, renamed.
  def codec_name(builtin) when is_atom(builtin) do
    case builtin do
      codec when codec in [:builtin_none, :builtin_zlib, :builtin_zstd, :builtin_lz4] ->
        builtin |> Atom.to_string() |> String.replace_prefix("builtin_", "") |> String.to_atom()

      other ->
        other
    end
  end

  def open_codec_name(name),
    do: name |> String.replace_prefix("builtin_", "") |> String.to_atom()

  # ex_ast's quoted-atom literal: an existing atom's name, unescaped.
  def unescape_atom(literal),
    do: literal |> Atom.to_string() |> Macro.unescape_string() |> String.to_atom()

  def unescape_binary(literal), do: literal |> Macro.unescape_string() |> String.to_atom()

  # An element of a bounded list is one of a bounded set too.
  def segment(kind) when kind in [Foo.Bar, Foo.Baz],
    do: kind |> Module.split() |> List.last() |> String.downcase() |> String.to_atom()

  # backpex's name_by_schema/1: Module.split/1 also takes an "Elixir."
  # binary, whose segments are the caller's.
  def open_segment(schema),
    do: schema |> Module.split() |> List.last() |> String.downcase() |> String.to_atom()

  # A function argument is code, not data: what it returns is not a function
  # of the bounded values it is handed.
  def mapped(name) when name in [~c"a", ~c"b"],
    do: :lists.map(&Process.get/1, name) |> List.to_atom()

  def replaced(name, suffix) when name in ["a", "b"] and suffix in ["x", "y"] do
    name
    |> String.replace("a", fn _ -> suffix <> Process.get(:suffix) end)
    |> String.to_atom()
  end
end
