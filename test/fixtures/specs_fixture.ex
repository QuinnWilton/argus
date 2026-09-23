defmodule Argus.Test.Fixtures.Specs do
  @moduledoc """
  Specs of every shape `Argus.Specs` reduces them to, written through
  local and remote types so resolution is exercised as well.
  """

  @type result :: {:ok, pid()} | {:error, term()}
  @type wrapped(inner) :: {:ok, inner} | :error

  @spec starts() :: result()
  def starts, do: {:error, :nope}

  @spec total() :: :ok
  def total, do: :ok

  @spec bool() :: boolean()
  def bool, do: true

  @spec halts() :: no_return()
  def halts, do: exit(:halt)

  @spec anything() :: term()
  def anything, do: :x

  @spec starts_remote() :: GenServer.on_start()
  def starts_remote, do: :ignore

  @spec wrapped_pid() :: wrapped(pid())
  def wrapped_pid, do: :error

  @spec maybe_nil() :: String.t() | nil
  def maybe_nil, do: nil

  @spec bounded(x) :: x when x: :ok | :done
  def bounded(x), do: x

  def unspecced, do: :ok

  @doc "Calls into the runtime, so the extractor reads the callees' specs too."
  def calls(t) do
    :ets.delete(t, :k)
    GenServer.start_link(__MODULE__, :ok, [])
    :mnesia.dirty_read(t, :k)
  end
end
