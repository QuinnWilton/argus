defmodule Argus.Test.Fixtures.PortUser do
  @moduledoc false

  # Every port-opening mechanism the extractor recognizes, with a mix of
  # static and runtime targets.

  def spawn_cmd, do: Port.open({:spawn, "cat"}, [:binary])

  def spawn_exe(path), do: Port.open({:spawn_executable, path}, [])

  def erl_port, do: :erlang.open_port({:spawn, "true"}, [])

  def run_cmd, do: System.cmd("ls", ["-la"])

  def shell_it, do: System.shell("echo hi")

  def os_cmd, do: :os.cmd(~c"date")
end
