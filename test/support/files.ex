defmodule Argus.Test.Files do
  @moduledoc """
  Cleanup for large test scratch directories. Native removal avoids queuing
  every file operation behind the test VM's shared file server.
  """

  @spec rm_rf!(Path.t()) :: :ok
  def rm_rf!(path) do
    case System.cmd("rm", ["-rf", "--", Path.expand(path)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "removing #{path} failed (#{status}): #{String.trim(output)}"
    end
  end
end
