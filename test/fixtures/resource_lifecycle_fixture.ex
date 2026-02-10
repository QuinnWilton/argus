defmodule Argus.Test.Fixtures.FileOpener do
  @moduledoc false

  def open_and_close(path) do
    {:ok, file} = File.open(path)
    data = IO.read(file, :eof)
    File.close(file)
    data
  end

  def open_only(path) do
    {:ok, file} = File.open(path)
    IO.read(file, :eof)
  end
end

defmodule Argus.Test.Fixtures.SocketModule do
  @moduledoc false

  def connect(host, port) do
    {:ok, socket} = :gen_tcp.connect(host, port, [])
    socket
  end

  def close(socket), do: :gen_tcp.close(socket)

  def listen(port), do: :gen_tcp.listen(port, [])
end

defmodule Argus.Test.Fixtures.PortModule do
  @moduledoc false

  def open_port(cmd) do
    Port.open({:spawn, cmd}, [:binary])
  end

  def close_port(port), do: Port.close(port)

  def erlang_open_port(cmd) do
    :erlang.open_port({:spawn, cmd}, [:binary])
  end
end
