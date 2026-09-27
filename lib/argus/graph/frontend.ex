defmodule Argus.Graph.Frontend do
  @moduledoc """
  The frontend contract of the query graph: what the rest of it asks of
  a program's beams, answered from the `beam` input (`Argus.Graph.Inputs`).

    * `module_beam(beam_key)` — `{:ok, beam}`: the key's file and the
      digest the frontend set for it (`%{path:, hash:}`), or the bytes
      of a beam held in memory (`%{data:, hash:}`); `:external` for a key
      no beam is set for. What extraction reads (`read/1`). The file is
      read when the key's input moved, never before: the tracked signal
      is the digest, and extraction reads the bytes it names.
    * `module_name(beam_key)` — the module the beam defines, from its
      header alone; nil for a beam that cannot be read.
    * `module_source(beam_key)` — the source file the beam was compiled
      from, per its compile info (relocated under `project_root` when
      the recorded path belongs to another machine), else the beam's own
      path; `:external` for a beam held in memory with none.
    * `program_modules(program)` — the program's modules and the beam
      each is analyzed from: the first key in the program's order that
      defines it.

  A frontend that compiles in memory (planchette's) registers its own
  module answering these queries by name in place of this one.
  """

  use Roux.Query,
    code: [exclude: &Argus.Graph.Reads.schema_module?/1],
    around: {Argus.Graph.Reads, :around}

  alias Roux.Runtime

  @typedoc "What `module_beam` answers for a beam: its file, or its bytes, and its digest."
  @type beam :: %{
          required(:hash) => String.t(),
          optional(:path) => Path.t(),
          optional(:data) => binary()
        }

  defquery :module_beam, key: beam_key, returns: {:ok, beam()} | :external do
    case Runtime.input(db, :beam, beam_key, default: nil) do
      nil -> :external
      %{data: data, hash: hash} -> {:ok, %{data: data, hash: hash}}
      %{hash: hash} when is_binary(beam_key) -> {:ok, %{path: beam_key, hash: hash}}
    end
  end

  defquery :module_name, key: beam_key, returns: module() | nil do
    case Runtime.query(db, :module_beam, beam_key) do
      {:ok, beam} -> beam |> read() |> header_module()
      :external -> nil
    end
  end

  defquery :module_source, key: beam_key, returns: String.t() | :external do
    case Runtime.query(db, :module_beam, beam_key) do
      {:ok, beam} ->
        source_path(beam, Runtime.input(db, :project_root, :all, default: nil))

      :external ->
        :external
    end
  end

  defquery :program_modules, key: program, returns: %{optional(module()) => term()} do
    db
    |> Runtime.input(:program, program, default: [])
    |> Enum.reduce(%{}, fn key, acc ->
      case Runtime.query(db, :module_name, key) do
        nil -> acc
        module -> Map.put_new(acc, module, key)
      end
    end)
  end

  @doc """
  What extraction reads a beam from: its path, or its bytes when it is
  held in memory (`Argus.Pipeline`'s module input).
  """
  @spec read(beam()) :: Path.t() | binary()
  def read(%{path: path}), do: path
  def read(%{data: data}), do: data

  defp header_module(input) do
    target = bytes_or_path(input)

    case :beam_lib.info(target) do
      info when is_list(info) -> Keyword.get(info, :module)
      {:error, :beam_lib, _reason} -> nil
    end
  end

  # The compiler recorded the source absolute-at-compile-time. When the
  # file is not there — a checkout that moved, a release built elsewhere
  # — the longest tail of that path that exists under the project root
  # is it (`lib/app/x.ex` for an app, `apps/app/lib/app/x.ex` for an
  # umbrella member). Failing that, stripped compile_info included, the
  # beam path itself: a visible, honest anchor beats silently dropping
  # the module's findings (its facts still feed every cross-module
  # analysis either way).
  defp source_path(beam, root) do
    target = bytes_or_path(read(beam))

    with {:ok, {_mod, [compile_info: info]}} <- :beam_lib.chunks(target, [:compile_info]),
         source when is_list(source) <- Keyword.get(info, :source, :missing),
         path = Path.expand(to_string(source)),
         {:ok, found} <- recorded_or_relocated(path, root) do
      found
    else
      _ -> Map.get(beam, :path, :external)
    end
  end

  # A beam's bytes, read raw (never queued behind the file server) when
  # it is a file; its path when it cannot be read, for `:beam_lib` to
  # report.
  defp bytes_or_path(<<"FOR1", _::binary>> = bytes), do: bytes

  defp bytes_or_path(path) do
    case :file.read_file(path, [:raw]) do
      {:ok, bytes} -> bytes
      {:error, _} -> String.to_charlist(path)
    end
  end

  defp recorded_or_relocated(path, root) do
    cond do
      File.exists?(path) ->
        {:ok, path}

      root == nil ->
        :error

      true ->
        path
        |> Path.split()
        |> Enum.drop(1)
        |> Stream.iterate(&tl/1)
        |> Enum.take_while(&(&1 != []))
        |> Enum.map(&Path.join([root | &1]))
        |> Enum.find(&File.regular?/1)
        |> case do
          nil -> :error
          found -> {:ok, found}
        end
    end
  end
end
