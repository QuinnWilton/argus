defmodule Argus.Graph.Environment do
  @moduledoc """
  The values of the graph's environment inputs (`Argus.Graph.Inputs`),
  as a frontend computes them before a run: never inside a query.

    * `solver/2` — the solver on `PATH`, its version and the timeout a
      solve has; nil without one.
    * `code_index/0` — each directory of the code path outside OTP and
      Elixir (and the build's consolidated protocols), named by itself.
    * `app_code/1` — a directory's beams by their stamps: it moves when
      one is rebuilt, and whoever read a module's specs from there looks
      at them again (`Argus.Graph.Reads`'s `installed_specs`), which is
      cheap and comes out equal unless the specs changed.
  """

  alias Roux.Blob

  @doc """
  The solver on `PATH`: `%{bin:, version:, timeout:}`, or nil. Its
  version is asked once for each binary (`Roux.Stamp`), kept in `store`
  across VMs unless the binary is a script (a version manager's shim can
  run another solver without moving).

  `:souffle_timeout` in `opts` sets the timeout (default
  `Argus.Souffle.default_timeout/0`).
  """
  @spec solver(Blob.t() | nil, keyword()) ::
          %{bin: String.t(), version: String.t(), timeout: timeout()} | nil
  def solver(store, opts \\ []) do
    case Keyword.get(opts, :souffle_bin, Argus.Souffle.executable()) do
      nil ->
        nil

      bin ->
        kept = if script?(bin), do: nil, else: store

        version =
          Roux.Stamp.memo({__MODULE__, :solver_version, bin}, [bin], fn -> ask_version(bin) end,
            store: kept
          )

        %{
          bin: bin,
          version: version,
          timeout: Keyword.get(opts, :souffle_timeout, Argus.Souffle.default_timeout())
        }
    end
  end

  defp ask_version(bin) do
    case System.cmd(bin, ["--version"], stderr_to_stdout: true) do
      {out, 0} -> out
      {out, status} -> {:error, {:souffle_version, status, out}}
    end
  rescue
    error -> {:error, {:souffle_version, Exception.message(error)}}
  end

  defp script?(bin) do
    case File.open(bin, [:read, :binary], &IO.binread(&1, 2)) do
      {:ok, "#!"} -> true
      {:ok, _} -> false
      {:error, _} -> true
    end
  end

  @doc """
  Each directory of the code path whose modules' specs are read from
  it and are not the runtime's: `%{dir => name}`, a directory named by
  itself.
  """
  @spec code_index() :: %{optional(String.t()) => String.t()}
  def code_index do
    otp = List.to_string(:code.root_dir()) <> "/"
    elixir = (:elixir |> :code.lib_dir() |> List.to_string() |> Path.dirname()) <> "/"

    for dir <- :code.get_path(),
        dir = dir |> List.to_string() |> Path.expand(),
        not String.starts_with?(dir, otp),
        not String.starts_with?(dir, elixir),
        "consolidated" not in Path.split(dir),
        File.dir?(dir),
        into: %{},
        do: {dir, dir}
  end

  @doc """
  A digest of the stamps (name, size, modification time, inode) of every
  beam in `dir`.
  """
  @spec app_code(Path.t()) :: String.t()
  def app_code(dir) do
    stamps =
      for beam <- dir |> Path.join("*.beam") |> Path.wildcard() |> Enum.sort() do
        case File.stat(beam, time: :posix) do
          {:ok, %File.Stat{size: size, mtime: mtime, inode: inode}} ->
            {Path.basename(beam), size, mtime, inode}

          {:error, reason} ->
            {Path.basename(beam), reason}
        end
      end

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(stamps, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
