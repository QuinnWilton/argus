defmodule Argus.Test.Fixtures.ConstantDecode do
  @moduledoc """
  argus's embedded tree: a module carries a directory tree as one gzipped
  literal it built at compile time, and decodes it with an exported
  function of another module. Every call the program makes hands that
  function a literal, so the bytes it inflates and decodes are the
  program's own.
  """

  defmodule Tree do
    @moduledoc "Packs and unpacks a tree."

    def pack(files), do: :zlib.gzip(:erlang.term_to_binary(files))
    def unpack(payload), do: payload |> :zlib.gunzip() |> :erlang.binary_to_term()

    # A decoder of the bytes themselves, which the program also hands only
    # its own literal.
    def decode(bytes), do: :erlang.binary_to_term(bytes)
  end

  defmodule Embedded do
    @moduledoc "The tree, carried as a literal."

    @payload :zlib.gzip(:erlang.term_to_binary([{"rules.dl", "a(1)."}]))
    @default :erlang.term_to_binary(%{mode: :default})

    def files, do: Tree.unpack(@payload)
    def default, do: Tree.decode(@default)
  end
end

defmodule Argus.Test.Fixtures.OpenDecode do
  @moduledoc """
  The twins, each still reported: a decoder one of whose callers hands it
  a caller's bytes, one the program also hands out as a fun, and one the
  program never calls (a library's API, with no call to judge it by).
  """

  defmodule Tree do
    @moduledoc "Unpacks a tree."

    def unpack(payload), do: payload |> :zlib.gunzip() |> :erlang.binary_to_term()
    def decode(bytes), do: :erlang.binary_to_term(bytes)
    def lone(bytes), do: :erlang.binary_to_term(bytes)
  end

  defmodule Callers do
    @moduledoc "One literal call, and one of each other kind."

    @payload :zlib.gzip(:erlang.term_to_binary([]))

    def files, do: Tree.unpack(@payload)
    def load(bytes), do: Tree.unpack(bytes)

    def default, do: Tree.decode(:erlang.term_to_binary(:default))
    def decoder, do: &Tree.decode/1
  end
end
