defmodule Argus.Test.Fixtures.Handles do
  @moduledoc false
  # Files, sockets and ports a function opens and loses on some path
  # (failure's resource_dropped, Argus.Extractors.Handles).

  # thousand_island before 45e7b51: sendfile opened a raw fd per call and
  # never closed it, on either transport.
  defmodule Sendfile do
    @moduledoc false
    def tcp(socket, filename, offset, length) do
      with {:ok, fd} <- :file.open(filename, [:raw]) do
        :file.sendfile(fd, socket, offset, length, [])
      end
    end

    def ssl(socket, filename, offset, length) do
      with {:ok, fd} <- :file.open(filename, [:raw]),
           {:ok, data} <- :file.pread(fd, offset, length) do
        case :ssl.send(socket, data) do
          :ok -> {:ok, length}
          {:error, error} -> {:error, error}
        end
      else
        :eof -> {:error, :eof}
        err -> err
      end
    end

    # The fix: `try ... after` closes it on every path.
    def fixed(socket, filename, offset, length) do
      case :file.open(filename, [:raw]) do
        {:ok, fd} ->
          try do
            :file.sendfile(fd, socket, offset, length, [])
          after
            :file.close(fd)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A connect whose next step fails returns the error with the socket
  # still open; closing it on that branch is the fix.
  defmodule Connect do
    @moduledoc false
    def leaky(host, port) do
      with {:ok, sock} <- :gen_tcp.connect(host, port, [:binary, active: false]),
           :ok <- :inet.setopts(sock, active: :once) do
        {:ok, sock}
      end
    end

    def closes(host, port) do
      with {:ok, sock} <- :gen_tcp.connect(host, port, [:binary, active: false]) do
        case :inet.setopts(sock, active: :once) do
          :ok ->
            {:ok, sock}

          err ->
            :gen_tcp.close(sock)
            err
        end
      end
    end

    # Handed to another process, or to a helper: not this function's to close.
    def handed_off(host, port, owner) do
      {:ok, sock} = :gen_tcp.connect(host, port, [:binary])
      :gen_tcp.controlling_process(sock, owner)
    end

    def to_helper(host, port) do
      {:ok, sock} = :gen_tcp.connect(host, port, [:binary])
      handshake(sock)
    end

    defp handshake(sock), do: :gen_tcp.send(sock, "hello")
  end

  defmodule Ports do
    @moduledoc false
    def fire_and_forget(cmd) do
      port = Port.open({:spawn, cmd}, [:binary])
      Port.command(port, "go")
      :ok
    end

    def kept(cmd, state) do
      port = Port.open({:spawn, cmd}, [:binary])
      %{state | port: port}
    end
  end

  # Beside each quieting condition, the nearest shapes that still lose
  # the handle: a raising path beside one that returns, a handle looked
  # at (inspected, compared) rather than taken, and an ok arm that loses
  # what the error arm never had.
  defmodule Adversarial do
    @moduledoc false
    def raise_or_return(path) do
      {:ok, fd} = File.open(path)

      case IO.binread(fd, 1) do
        "" -> raise "empty"
        _ -> :ok
      end
    end

    def badmatch_then_return(path) do
      {:ok, fd} = File.open(path)
      {:ok, _} = :file.read(fd, 1)
      :ok
    end

    def raise_before_open(path, bad?) do
      if bad?, do: raise("bad")
      {:ok, fd} = File.open(path)
      IO.binread(fd, 1)
    end

    def inspected(path) do
      {:ok, fd} = File.open(path)
      IO.inspect(fd, label: "opened")
      :ok
    end

    def logged(path) do
      {:ok, fd} = File.open(path)
      message = "opened #{inspect(fd)}"
      {:ok, message}
    end

    def compared(path, other) do
      {:ok, fd} = File.open(path)
      if fd == other, do: :same, else: :other
    end

    def ok_arm(path) do
      case File.open(path) do
        {:ok, fd} -> IO.binread(fd, 1)
        {:error, _} = e -> e
      end
    end

    def with_else(path) do
      with {:ok, fd} <- File.open(path),
           :ok <- validate(path) do
        File.close(fd)
      end
    end

    def early_error(path, x) do
      {:ok, fd} = File.open(path)

      if x do
        {:error, :x}
      else
        File.close(fd)
        :ok
      end
    end

    defp validate(path), do: if(path == "", do: {:error, :empty}, else: :ok)
  end

  # The answer returned whole, a path that raises, and an error arm that
  # owns no handle: none is a loss.
  defmodule Quiet do
    @moduledoc false
    def whole(path), do: :file.open(path, [:read])

    def ok_tuple(path) do
      case :file.open(path, [:read]) do
        {:ok, _fd} = ok -> ok
        {:error, _} = e -> e
      end
    end

    def raises(path) do
      {:ok, fd} = File.open(path)
      data = IO.binread(fd, :eof)
      if data == "", do: raise("empty")
      File.close(fd)
      data
    end

    # ejabberd's accept loop: the reason of the error arm is no handle,
    # though the compiler takes element 1 out before it tests the tag.
    def accept_loop(listen, proxy?) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} when proxy? ->
          handoff(socket)
          accept_loop(listen, proxy?)

        {:ok, socket} ->
          handoff(socket)
          accept_loop(listen, proxy?)

        {:error, reason} ->
          IO.puts("accept failed: #{inspect(reason)}")
          accept_loop(listen, proxy?)
      end
    end

    defp handoff(socket), do: :gen_tcp.controlling_process(socket, self())

    def sent(path, pid) do
      {:ok, fd} = File.open(path)
      send(pid, {:fd, fd})
    end
  end
end
