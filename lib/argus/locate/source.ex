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

  @doc "The line of the file as it stands that the bytecode's `line` names."
  @callback line(path :: String.t(), line :: pos_integer()) :: pos_integer()

  @doc "The line of `fragment` at or after `line`, or `line`."
  @callback refine(path :: String.t(), line :: pos_integer(), fragment :: String.t() | nil) ::
              pos_integer()

  @doc "The last line of the `block` the anchor at `line` sits in, or nil."
  @callback block_end(
              path :: String.t(),
              line :: pos_integer(),
              block :: Argus.Findings.block() | nil
            ) ::
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

  @scope {__MODULE__, :scope}

  @doc """
  Runs `fun` with every read of a source file (`read/3`) kept for its
  length: placing a program's findings reads the same files for every
  finding and frame in them, and an Erlang file's tokens are the whole
  file scanned. The files are read as they stand when first asked for;
  what `fun` returns comes back. Nested calls share the outer one's.
  """
  @spec within((-> result)) :: result when result: var
  def within(fun) when is_function(fun, 0) do
    case Process.get(@scope) do
      nil ->
        Process.put(@scope, %{})

        try do
          fun.()
        after
          Process.delete(@scope)
        end

      _open ->
        fun.()
    end
  end

  @doc """
  `compute`'s value for `path` under `kind` (a file's content, its
  tokens, its directives), kept for the length of `within/1` when one is
  open, and computed every time otherwise.
  """
  @spec read(String.t(), atom(), (-> value)) :: value when value: var
  def read(path, kind, compute) when is_function(compute, 0) do
    case Process.get(@scope) do
      nil ->
        compute.()

      kept ->
        case Map.fetch(kept, {kind, path}) do
          {:ok, value} ->
            value

          :error ->
            value = compute.()
            Process.put(@scope, Map.put(kept, {kind, path}, value))
            value
        end
    end
  end
end
