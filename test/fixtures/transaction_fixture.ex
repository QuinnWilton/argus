defmodule Argus.Test.Fixtures.Transaction do
  @moduledoc """
  Fixtures for the transaction-safety analysis.

  `FakeRepo` declares `@behaviour Ecto.Repo` without depending on Ecto —
  the analysis finds repos by behaviour, so the attribute is all it needs.
  """

  defmodule FakeRepo do
    @moduledoc false
    @behaviour Ecto.Repo

    def transaction(fun), do: fun.()
    def transaction(fun, _opts), do: fun.()
    def insert(x), do: {:ok, x}
  end

  defmodule Unsafe do
    @moduledoc "The bug: an unrollbackable effect inside the transaction."
    def create(user) do
      FakeRepo.transaction(fn ->
        FakeRepo.insert(user)
        :httpc.request(~c"http://hooks/notify")
      end)
    end
  end

  defmodule UnsafeIndirect do
    @moduledoc "Same, but the effect is a call or two down."
    def create(user) do
      FakeRepo.transaction(fn ->
        FakeRepo.insert(user)
        notify(user)
      end)
    end

    def notify(user), do: deliver(user)
    def deliver(_user), do: :httpc.request(~c"http://hooks/notify")
  end

  defmodule Sleeps do
    @moduledoc "Holds a pooled connection doing nothing at all."
    def create(user) do
      FakeRepo.transaction(fn ->
        Process.sleep(5000)
        FakeRepo.insert(user)
      end)
    end
  end

  defmodule LogsOnly do
    @moduledoc """
    Logging inside a transaction is fine and extremely common. If this were
    reported the analysis would be unusable.
    """
    require Logger

    def create(user) do
      FakeRepo.transaction(fn ->
        Logger.info("creating")
        FakeRepo.insert(user)
      end)
    end
  end

  defmodule ReadsConfig do
    @moduledoc """
    Reading config is impure but has nothing to roll back. This is the
    fixture that motivated the read/write dimension — before it, every
    config read in a transaction was reported as a hazard.
    """
    def create(user) do
      FakeRepo.transaction(fn ->
        _ = Application.get_env(:panoptes, :whatever)
        FakeRepo.insert(user)
      end)
    end
  end

  defmodule EffectOutside do
    @moduledoc "The correct shape: commit first, then act."
    def create(user) do
      result = FakeRepo.transaction(fn -> FakeRepo.insert(user) end)
      :httpc.request(~c"http://hooks/notify")
      result
    end
  end
end
