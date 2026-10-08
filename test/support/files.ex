defmodule Argus.Test.Files do
  @moduledoc """
  Scratch directories for tests. Native removal avoids queuing every file
  operation behind the test VM's shared file server.
  """

  @doc """
  A new directory under the system's temporary one, removed when the
  calling test or test module ends: for a `setup_all`, which ExUnit's
  `@tag :tmp_dir` does not reach.
  """
  @spec tmp_dir!(String.t()) :: Path.t()
  def tmp_dir!(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> rm_rf!(dir) end)
    dir
  end

  # Found once: a command named without a path is searched for along the
  # PATH, through the file server, every time it runs.
  @rm System.find_executable("rm")

  @doc "Removes `path`, or each of `paths`, and everything under it."
  @spec rm_rf!(Path.t() | [Path.t()]) :: :ok
  def rm_rf!([]), do: :ok

  def rm_rf!(paths) when is_list(paths) do
    case System.cmd(@rm, ["-rf", "--" | Enum.map(paths, &Path.expand/1)], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise "removing #{inspect(paths)} failed (#{status}): #{String.trim(output)}"
    end
  end

  def rm_rf!(path), do: rm_rf!([path])

  @doc """
  Removes the directories ExUnit's `@tag :tmp_dir` left under `tmp/` in
  earlier runs, with one command. ExUnit empties a test's directory as
  the test starts, file by file through the VM's file server, where the
  run's tests queue behind each other's: hundreds of megabytes a run.
  Like ExUnit's own, this takes a directory another run in the same
  checkout is still writing in.
  """
  @spec rm_tmp_dirs!() :: :ok
  def rm_tmp_dirs! do
    root = Path.expand("tmp")
    rm_rf!(for name <- ls(root), String.ends_with?(name, "Test"), do: Path.join(root, name))
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end
end
