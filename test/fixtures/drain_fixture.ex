defmodule Argus.Test.Fixtures.Drain do
  @moduledoc false
  # Broadway producers draining (shutdown's drain_keeps_fetching).

  # broadway_sqs before 5b8f18a: the drain cancels the poll and clears
  # the field the fetch clause asks to be nil.
  defmodule CancelsOnly do
    @moduledoc false
    @behaviour Broadway.Producer

    def handle_demand(incoming, %{demand: demand} = state) do
      handle_receive_messages(%{state | demand: demand + incoming})
    end

    def handle_info(:receive_messages, state) do
      handle_receive_messages(%{state | receive_timer: nil})
    end

    @impl true
    def prepare_for_draining(%{receive_timer: receive_timer} = state) do
      receive_timer && Process.cancel_timer(receive_timer)
      {:noreply, [], %{state | receive_timer: nil}}
    end

    defp handle_receive_messages(%{receive_timer: nil, demand: demand} = state) when demand > 0 do
      messages = fetch(demand)
      timer = Process.send_after(self(), :receive_messages, 1_000)
      {:noreply, messages, %{state | demand: demand - length(messages), receive_timer: timer}}
    end

    defp handle_receive_messages(state), do: {:noreply, [], state}

    defp fetch(demand), do: Enum.to_list(1..demand)
  end

  # The fix: a draining flag, and a first clause that takes it.
  defmodule Flagged do
    @moduledoc false
    @behaviour Broadway.Producer

    def handle_demand(incoming, %{demand: demand} = state) do
      handle_receive_messages(%{state | demand: demand + incoming})
    end

    @impl true
    def prepare_for_draining(%{receive_timer: receive_timer} = state) do
      receive_timer && Process.cancel_timer(receive_timer)
      {:noreply, [], %{state | receive_timer: nil, draining: true}}
    end

    defp handle_receive_messages(%{draining: true} = state), do: {:noreply, [], state}

    defp handle_receive_messages(%{receive_timer: nil, demand: demand} = state) when demand > 0 do
      timer = Process.send_after(self(), :receive_messages, 1_000)
      {:noreply, Enum.to_list(1..demand), %{state | demand: 0, receive_timer: timer}}
    end

    defp handle_receive_messages(state), do: {:noreply, [], state}
  end

  # A drain that clears a field no fetch tests closes nothing and opens
  # nothing: no finding.
  defmodule OtherField do
    @moduledoc false
    @behaviour Broadway.Producer

    def handle_demand(_incoming, state), do: {:noreply, [], state}

    @impl true
    def prepare_for_draining(%{flush_timer: timer} = state) do
      Process.cancel_timer(timer)
      {:noreply, [], %{state | flush_timer: nil}}
    end
  end

  # Beside the quieting condition (a flag the fetch reads), the nearest
  # shapes that still fetch: a flag set and never read, a counter reset
  # that demand undoes, a drain that clears the ref without cancelling.
  defmodule FlagUnread do
    @moduledoc false
    @behaviour Broadway.Producer

    def handle_demand(incoming, %{demand: demand} = state),
      do: fetch(%{state | demand: demand + incoming})

    @impl true
    def prepare_for_draining(%{receive_timer: timer} = state) do
      timer && Process.cancel_timer(timer)
      {:noreply, [], %{state | receive_timer: nil, draining: true}}
    end

    defp fetch(%{receive_timer: nil, demand: demand} = state) when demand > 0,
      do: {:noreply, Enum.to_list(1..demand), %{state | demand: 0}}

    defp fetch(state), do: {:noreply, [], state}
  end

  defmodule CounterReset do
    @moduledoc false
    @behaviour Broadway.Producer

    def handle_demand(incoming, %{demand: demand} = state),
      do: fetch(%{state | demand: demand + incoming})

    @impl true
    def prepare_for_draining(%{receive_timer: timer} = state) do
      timer && Process.cancel_timer(timer)
      {:noreply, [], %{state | receive_timer: nil, demand: 0}}
    end

    defp fetch(%{receive_timer: nil, demand: demand} = state) when demand > 0,
      do: {:noreply, Enum.to_list(1..demand), %{state | demand: 0}}

    defp fetch(state), do: {:noreply, [], state}
  end

  defmodule NoCancel do
    @moduledoc false
    @behaviour Broadway.Producer

    def handle_demand(incoming, %{demand: demand} = state),
      do: fetch(%{state | demand: demand + incoming})

    @impl true
    def prepare_for_draining(state), do: {:noreply, [], %{state | receive_timer: nil}}

    defp fetch(%{receive_timer: nil, demand: demand} = state) when demand > 0,
      do: {:noreply, Enum.to_list(1..demand), %{state | demand: 0}}

    defp fetch(state), do: {:noreply, [], state}
  end
end
