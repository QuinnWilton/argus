defmodule Argus.Locate.Source do
  @moduledoc """
  The last step of placing a finding, taken in its source file.

  A finding is placed by its bytecode (`Argus.Located`): the line of its
  instruction, of its function, or of its module. What the bytecode
  cannot say, the source can, when there is one to read:

    * `refine/3` — the line of a fragment the finding names
      (`at_source`: the field of a schema, whose generated functions all
      carry the `schema` line), at or after the bytecode's line;
    * `block_end/3` — the last line of the block the finding says its
      anchor sits in (`to_block`), for a span the bytecode left open;
    * `guard_keyword/2` — the keyword of the guard the anchor sits in,
      for the `{guard}` in a finding's prose (bytecode cannot tell a
      `rescue` from a `catch`).

  Each language reads its own source: `for/1` picks the rules by the
  file's extension — `Argus.Locate.Source.Elixir` for `.ex` and `.exs`,
  `Argus.Locate.Source.Erlang` for `.erl` and `.hrl` — and
  `Argus.Locate.Source.Opaque` for everything else (a beam path, the
  anchor of a module that recorded no source), which keeps the
  bytecode's place. Every rule fails closed: a shape it does not find,
  or a file it cannot read, leaves the place as the bytecode put it.
  """

  @typedoc "The block a finding says its anchor sits in (`Argus.Findings`)."
  @type block :: :guard | :receive | :clause | :function

  @doc "The line of `fragment` at or after `line`, or `line`."
  @callback refine(path :: String.t(), line :: pos_integer(), fragment :: String.t() | nil) ::
              pos_integer()

  @doc "The last line of the `block` the anchor at `line` sits in, or nil."
  @callback block_end(path :: String.t(), line :: pos_integer(), block :: block() | nil) ::
              pos_integer() | nil

  @doc "The keyword of the guard the anchor at `line` sits in, or nil."
  @callback guard_keyword(path :: String.t(), line :: pos_integer()) :: String.t() | nil

  @doc """
  The rules that read the source at `path`, by its extension.

      iex> Argus.Locate.Source.for("lib/app/worker.ex")
      Argus.Locate.Source.Elixir

      iex> Argus.Locate.Source.for("src/app_worker.erl")
      Argus.Locate.Source.Erlang

      iex> Argus.Locate.Source.for("_build/default/lib/app/ebin/app.beam")
      Argus.Locate.Source.Opaque
  """
  @spec for(String.t()) :: module()
  def for(path) when is_binary(path) do
    case Path.extname(path) do
      ext when ext in [".ex", ".exs"] -> Argus.Locate.Source.Elixir
      ext when ext in [".erl", ".hrl"] -> Argus.Locate.Source.Erlang
      _other -> Argus.Locate.Source.Opaque
    end
  end
end
