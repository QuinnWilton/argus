defmodule Argus.Specs.Source do
  @moduledoc """
  Where the specs of the modules a program calls are read from: a
  module's beam, found in the project's own ebins (its program's, then
  its dependencies', in order), then in the installed OTP, then among
  the runtime's own Elixir applications — never on the VM's code path.

  The code path is the analyzing VM's, not the project's. An escript
  carries its own dependencies (telemetry, among others), which a
  project may depend on at another version; looked up on the code path,
  a call into the project's telemetry would be read against the
  escript's. And a project's ebins are never put on the code path,
  where they would collide with those copies. So `new/1` indexes the
  project's ebins and the installed OTP's by file name, once per run,
  and a module found nowhere there is unknown.

  `Argus.Specs.installed/2` reads through a source when the run's memo
  carries one (`Argus.Pipeline`'s `specs_source:`); without one it reads
  the code path, as an in-VM caller analyzing the VM's own code wants.
  """

  @enforce_keys [:index]
  defstruct [:index]

  @typedoc "Each beam's path, by its module's name, the first ebin's winning."
  @type t :: %__MODULE__{index: %{optional(String.t()) => Path.t()}}

  @typedoc """
  What reading a module's beam gives: its bytes and a stamp of the file
  they came from, or of the runtime for a module the runtime carries in
  an archive.
  """
  @type read :: {:ok, binary(), term()} | :error

  # The runtime's own applications: their modules live wherever the
  # runtime does (inside an escript's archive, for one that embeds
  # Elixir), and are read through the code server.
  @runtime_apps [:elixir, :eex, :logger, :mix, :ex_unit, :iex]

  @doc """
  The source for a project (`Argus.Project`: its program's ebins, then
  its dependencies'), or for a list of ebins, in order.
  """
  @spec new(Argus.Project.t() | [Path.t()]) :: t()
  def new(%Argus.Project{apps: apps, deps: deps}), do: new(Enum.map(apps ++ deps, &elem(&1, 1)))

  def new(ebins) when is_list(ebins) do
    # A directory's listing, not a wildcard: thousands of names, and
    # filelib's pattern matching is most of a warm run's listing time.
    index =
      for dir <- ebins ++ otp_ebins(),
          name <- beams_in(dir),
          reduce: %{} do
        index -> Map.put_new(index, Path.basename(name, ".beam"), Path.join(dir, name))
      end

    %__MODULE__{index: index}
  end

  defp beams_in(dir) do
    case :prim_file.list_dir(dir) do
      {:ok, names} ->
        for name <- names, name = List.to_string(name), String.ends_with?(name, ".beam"), do: name

      {:error, _} ->
        []
    end
    |> Enum.sort()
  end

  # The installed OTP's ebins: the code path's entries under its root.
  defp otp_ebins do
    root = List.to_string(:code.root_dir()) <> "/"

    for dir <- :code.get_path(),
        dir = List.to_string(dir),
        String.starts_with?(dir, root),
        do: dir
  end

  @doc """
  The beam `module` is read from: `{:ok, path}` from the project's ebins
  or OTP's, `{:ok, :runtime}` for a module of the runtime's own Elixir
  applications, or `:error` for one found nowhere.
  """
  @spec which(t(), module()) :: {:ok, Path.t() | :runtime} | :error
  def which(%__MODULE__{index: index}, module) when is_atom(module) do
    case Map.fetch(index, Atom.to_string(module)) do
      {:ok, path} -> {:ok, path}
      :error -> if runtime?(module), do: {:ok, :runtime}, else: :error
    end
  end

  @doc """
  The beam of `module` with a stamp of where it came from (the file's
  path, modification time and size; the runtime's version for a
  runtime module), or `:error`.
  """
  @spec read(t(), module()) :: read()
  def read(source, module) do
    case which(source, module) do
      {:ok, :runtime} ->
        case :code.get_object_code(module) do
          {^module, binary, _file} -> {:ok, binary, {:runtime, System.version()}}
          :error -> :error
        end

      {:ok, path} ->
        with {:ok, %File.Stat{mtime: mtime, size: size}} <- File.stat(path, time: :posix),
             {:ok, binary} <- File.read(path) do
          {:ok, binary, {path, mtime, size}}
        else
          _ -> :error
        end

      :error ->
        :error
    end
  end

  @doc """
  A stamp of where `module` would be read from. Recently changed files are
  hashed because a stat timestamp cannot distinguish writes in one second.
  """
  @spec stamp(t(), module()) :: term()
  def stamp(source, module) do
    case which(source, module) do
      {:ok, :runtime} ->
        case :code.which(module) do
          path when is_list(path) -> file_stamp(List.to_string(path))
          other -> {:runtime, module, other, System.version()}
        end

      {:ok, path} ->
        file_stamp(path)

      :error ->
        :non_existing
    end
  end

  @doc false
  @spec file_stamp(Path.t()) :: term()
  def file_stamp(path) do
    case Roux.Stamp.stamp(path) do
      :absent ->
        {path, :absent}

      {_size, mtime, _inode, ctime} = stamp ->
        if max(mtime, ctime) < System.os_time(:second) - 2 do
          {path, stamp}
        else
          case File.read(path) do
            {:ok, bytes} -> {path, stamp, :crypto.hash(:sha256, bytes)}
            {:error, _} -> {path, :absent}
          end
        end
    end
  end

  defp runtime?(module) do
    case :persistent_term.get({__MODULE__, :runtime}, nil) do
      nil ->
        Enum.each(@runtime_apps, &Application.load/1)

        modules =
          for app <- @runtime_apps,
              module <- Application.spec(app, :modules) || [],
              into: MapSet.new(),
              do: module

        :persistent_term.put({__MODULE__, :runtime}, modules)
        MapSet.member?(modules, module)

      modules ->
        MapSet.member?(modules, module)
    end
  end
end
