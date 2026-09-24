# The clause each call runs in, in the shapes a first argument is
# dispatched on: a tuple tag, a bare atom, a guard over several tags, two
# clauses of one tag, a case on the request in the body, a helper that
# does the dispatching, a catch-all — and a plain function's clauses.

defmodule Argus.Test.Fixtures.ClauseCall.Dest do
  @moduledoc false
  def tuple_tag, do: :ok
  def bare_atom, do: :ok
  def either, do: :ok
  def ready, do: :ok
  def not_ready, do: :ok
  def cased, do: :ok
  def helper, do: :ok
  def fallback, do: :ok
  def local, do: :ok
  def remote, do: :ok
end

defmodule Argus.Test.Fixtures.ClauseCall.Server do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.ClauseCall.Dest

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:tuple_tag, _n}, _from, state), do: {:reply, Dest.tuple_tag(), state}
  def handle_call(:bare_atom, _from, state), do: {:reply, Dest.bare_atom(), state}

  def handle_call({tag, _n}, _from, state) when tag in [:left, :right],
    do: {:reply, Dest.either(), state}

  def handle_call({:twice, _n}, _from, %{ready: true} = state), do: {:reply, Dest.ready(), state}
  def handle_call({:twice, _n}, _from, state), do: {:reply, Dest.not_ready(), state}

  def handle_call({:via_helper, _} = request, _from, state),
    do: {:reply, dispatch(request), state}

  def handle_call(request, _from, state) do
    case request do
      {:cased, _} -> {:reply, Dest.cased(), state}
      _other -> {:reply, Dest.fallback(), state}
    end
  end

  defp dispatch({:via_helper, _}), do: Dest.helper()
end

defmodule Argus.Test.Fixtures.ClauseCall.Router do
  @moduledoc false
  alias Argus.Test.Fixtures.ClauseCall.Dest

  def route(:local, n), do: {Dest.local(), n}
  def route(:remote, n), do: {Dest.remote(), n}
end
