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

  defmodule AuditRepo do
    @moduledoc "A second repo, whose name sorts before FakeRepo's."
    @behaviour Ecto.Repo

    def transaction(multi), do: {:ok, multi}
  end

  defmodule TwoRepos do
    @moduledoc """
    One closure, two repos: the closure goes to FakeRepo, an Ecto.Multi
    to AuditRepo. The call the closure is handed to says which
    transaction runs it: FakeRepo's, and not AuditRepo's.
    """
    def create(user, multi) do
      FakeRepo.transaction(fn ->
        FakeRepo.insert(user)
        :httpc.request(~c"http://hooks/notify")
      end)

      AuditRepo.transaction(multi)
    end
  end

  defmodule TwoClosures do
    @moduledoc """
    The transaction's closure beside another the function builds: the one
    handed to the transaction is its body, the other is not.
    """
    def create(users) do
      names = Enum.map(users, fn user -> user.name end)

      FakeRepo.transaction(fn ->
        FakeRepo.insert(names)
        :httpc.request(~c"http://hooks/notify")
      end)
    end
  end

  defmodule StreamsBeforeCommit do
    @moduledoc """
    akkoma's `ActivityPub.create/2`: the transaction's work streams the
    new post, and the streamer spawns a pusher per topic. The spawn is
    the effect a rollback cannot undo, one finding; what the pusher does
    runs in its own process, beside the transaction.
    """
    def create(post) do
      FakeRepo.transaction(fn ->
        FakeRepo.insert(post)
        stream(["public", "user"], post)
      end)
    end

    def stream(topics, post) do
      for topic <- topics do
        spawn(fn -> push(topic, post) end)
      end
    end

    def push(topic, post) do
      Registry.dispatch(Streamer, topic, fn subscribers ->
        for {pid, _} <- subscribers, do: send(pid, {:post, post})
      end)
    end
  end

  defmodule TaskBeforeCommit do
    @moduledoc """
    A Task started in the transaction: the start is the effect, and the
    webhook the task posts is its own.
    """
    def create(post) do
      FakeRepo.transaction(fn ->
        FakeRepo.insert(post)
        Task.start(fn -> :httpc.request(~c"http://hooks/new") end)
      end)
    end
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
