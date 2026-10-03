defmodule Argus.Test.Fixtures.SharedStoreClaim do
  defmodule Claim do
    @compile {:no_warn_undefined, ConCache}
    def claim(cache, key) do
      case ConCache.get(cache, key) do
        nil ->
          ConCache.put(cache, key, true)
          :ok

        _ ->
          {:error, :already_used}
      end
    end
  end

  defmodule Helpers do
    @compile {:no_warn_undefined, ConCache}
    def verify(cache, key) do
      with :ok <- unused(cache, key), :ok <- mark(cache, key) do
        {:ok, key}
      end
    end

    defp unused(cache, key) do
      case ConCache.get(cache, normalize(key)) do
        nil -> :ok
        _ -> {:error, :already_used}
      end
    end

    defp mark(cache, key) do
      ConCache.put(cache, normalize(key), true)
      :ok
    end

    defp normalize(key), do: "claim:" <> String.downcase(key)
  end

  defmodule Atomic do
    @compile {:no_warn_undefined, ConCache}
    def claim(cache, key) do
      ConCache.isolated(cache, key, fn ->
        case ConCache.get(cache, key) do
          nil ->
            ConCache.put(cache, key, true)
            :ok

          _ ->
            {:error, :already_used}
        end
      end)
    end
  end

  defmodule WrongLock do
    @compile {:no_warn_undefined, ConCache}
    def claim(cache, key) do
      ConCache.isolated(cache, :unrelated, fn ->
        case ConCache.get(cache, key) do
          nil ->
            ConCache.put(cache, key, true)
            :ok

          _ ->
            {:error, :already_used}
        end
      end)
    end
  end

  defmodule DifferentKey do
    @compile {:no_warn_undefined, ConCache}
    def claim(cache) do
      case ConCache.get(cache, :first) do
        nil ->
          ConCache.put(cache, :second, true)
          :ok

        _ ->
          {:error, :already_used}
      end
    end
  end

  defmodule DifferentStore do
    @compile {:no_warn_undefined, ConCache}
    def claim(key) do
      case ConCache.get(:first, key) do
        nil ->
          ConCache.put(:second, key, true)
          :ok

        _ ->
          {:error, :already_used}
      end
    end
  end

  defmodule Unused do
    @compile {:no_warn_undefined, ConCache}
    def fill(cache, key) do
      case ConCache.get(cache, key) do
        nil -> ConCache.put(cache, key, true)
        _ -> :ok
      end

      :ok
    end
  end

  defmodule Refresh do
    @compile {:no_warn_undefined, ConCache}
    def refresh(cache, key) do
      case ConCache.get(cache, key) do
        nil ->
          {:error, :missing}

        _ ->
          ConCache.put(cache, key, true)
          :ok
      end
    end
  end

  defmodule WrongNormalization do
    @compile {:no_warn_undefined, ConCache}
    def claim(cache, key) do
      with :ok <- unused(cache, key), :ok <- mark(cache, key), do: {:ok, key}
    end

    defp unused(cache, key) do
      case ConCache.get(cache, read_key(key)) do
        nil -> :ok
        _ -> {:error, :used}
      end
    end

    defp mark(cache, key) do
      ConCache.put(cache, write_key(key), true)
      :ok
    end

    defp read_key(key), do: "read:" <> key
    defp write_key(key), do: "write:" <> key
  end

  defmodule DifferentFields do
    @compile {:no_warn_undefined, ConCache}
    def claim(left, right, key) do
      case ConCache.get(left.cache, key) do
        nil ->
          ConCache.put(right.cache, key, true)
          :ok

        _ ->
          {:error, :used}
      end
    end
  end

  defmodule RepeatedReader do
    @compile {:no_warn_undefined, ConCache}
    def claim(cache) do
      unused(cache, :first)

      case unused(cache, :second) do
        :ok ->
          ConCache.put(cache, :first, true)
          :ok

        _ ->
          {:error, :used}
      end
    end

    defp unused(cache, key) do
      case ConCache.get(cache, key) do
        nil -> :ok
        _ -> {:error, :used}
      end
    end
  end

  defmodule SuccessWithErrorDetails do
    @compile {:no_warn_undefined, ConCache}
    def claim(cache, key) do
      with :ok <- unused(cache, key) do
        ConCache.put(cache, key, true)
        {:ok, key}
      end
    end

    defp unused(cache, key) do
      case ConCache.get(cache, key) do
        nil -> :ok
        value -> {:error, value}
      end
    end
  end

  defmodule AtomicComputedCache do
    @compile {:no_warn_undefined, ConCache}
    def claim(opts, key) do
      cache = cache_name(opts)

      ConCache.isolated(cache, key, fn ->
        case ConCache.get(cache, key) do
          nil ->
            ConCache.put(cache, key, true)
            :ok

          value ->
            {:error, value}
        end
      end)
    end

    defp cache_name(opts), do: Keyword.get(opts, :name, :claims)
  end

  defmodule ChangedSentinel do
    @compile {:no_warn_undefined, ConCache}
    def claim(cache, key) do
      case Argus.Test.Fixtures.SharedStoreClaim.SentinelLookup.lookup(cache, key) do
        nil ->
          ConCache.put(cache, key, true)
          :ok

        _ ->
          {:error, :used}
      end
    end
  end

  defmodule SentinelLookup do
    @compile {:no_warn_undefined, ConCache}
    def lookup(cache, key) do
      case ConCache.get(cache, key) do
        nil -> :not_found
        value -> value
      end
    end
  end

  defmodule ReusedCallback do
    @compile {:no_warn_undefined, ConCache}
    def claim(cache, key) do
      fun = fn ->
        case ConCache.get(cache, key) do
          nil ->
            ConCache.put(cache, key, true)
            :ok

          _ ->
            {:error, :used}
        end
      end

      ConCache.isolated(cache, key, fun)
      ConCache.isolated(cache, :unrelated, fun)
    end
  end

  defmodule Owner do
    @compile {:no_warn_undefined, ConCache}
    use GenServer
    def start_link, do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def claim(key), do: GenServer.call(__MODULE__, {:claim, key})
    @impl true
    def init(:ok), do: {:ok, :cache}

    @impl true
    def handle_call({:claim, key}, _from, cache) do
      answer =
        case ConCache.get(cache, key) do
          nil ->
            ConCache.put(cache, key, true)
            :ok

          _ ->
            {:error, :already_used}
        end

      {:reply, answer, cache}
    end
  end
end
