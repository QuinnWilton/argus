# Soundness fixtures (review 2): each shape must keep the severity its
# test states. Probes of the review and adversarial neighbours.
# credo:disable-for-this-file
defmodule Argus.Test.Soundness.G8.TxnRepo2 do
  @behaviour Ecto.Repo
  def transaction(fun), do: fun.()
  def insert(x), do: {:ok, x}
end

defmodule Argus.Test.Soundness.G8.TxnSupStart do
  # The idiomatic "fire the webhook from a supervised task" inside the
  # transaction: the request can leave before commit (and after a
  # rollback). Task.Supervisor is not in the effect model, so with the
  # walk cut at the start nothing is reported at all.
  alias Argus.Test.Soundness.G8.TxnRepo2

  def create(post) do
    TxnRepo2.transaction(fn ->
      {:ok, p} = TxnRepo2.insert(post)
      Task.Supervisor.start_child(MyApp.TaskSup, fn -> :httpc.request(~c"http://hooks/new") end)
      p
    end)
  end
end

defmodule Argus.Test.Soundness.G8.TxnSupNolink do
  alias Argus.Test.Soundness.G8.TxnRepo2

  def create(post) do
    TxnRepo2.transaction(fn ->
      {:ok, p} = TxnRepo2.insert(post)
      Task.Supervisor.async_nolink(MyApp.TaskSup, fn -> :httpc.request(~c"http://hooks/new") end)
      p
    end)
  end
end

defmodule Argus.Test.Soundness.G8.TxnRepo do
  @behaviour Ecto.Repo
  def transaction(fun), do: fun.()
  def insert(x), do: {:ok, x}
end

defmodule Argus.Test.Soundness.G8.TxnTaskAwait do
  # The webhook runs in a Task the transaction awaits: the request leaves
  # the machine before commit AND the transaction holds its pooled
  # connection for the whole HTTP round trip (the outage route). Before
  # ab081662 this was "network I/O inside a transaction" (:error).
  alias Argus.Test.Soundness.G8.TxnRepo

  def create(post) do
    TxnRepo.transaction(fn ->
      TxnRepo.insert(post)
      task = Task.async(fn -> :httpc.request(~c"http://hooks/new") end)
      Task.await(task, 30_000)
    end)
  end
end

defmodule Argus.Test.Soundness.G8.TxnSupAwait do
  alias Argus.Test.Soundness.G8.TxnRepo

  def create(post) do
    TxnRepo.transaction(fn ->
      TxnRepo.insert(post)

      Task.Supervisor.async(MySup, fn -> :httpc.request(~c"http://hooks/new") end)
      |> Task.await()
    end)
  end
end

defmodule Argus.Test.Soundness.Adv.Txn.Repo do
  @behaviour Ecto.Repo
  def transaction(fun), do: fun.()
  def insert(x), do: {:ok, x}
end

defmodule Argus.Test.Soundness.Adv.Txn.Hooks do
  def fire, do: :httpc.request(~c"http://hooks/new")
end

defmodule Argus.Test.Soundness.Adv.Txn.Background do
  # A helper that runs what it is handed in a new process.
  def run(fun), do: Task.start(fun)
end

defmodule Argus.Test.Soundness.Adv.Txn.RawSpawn do
  # (a) A bare spawn of a closure posting the webhook.
  def create(post) do
    Argus.Test.Soundness.Adv.Txn.Repo.transaction(fn ->
      Argus.Test.Soundness.Adv.Txn.Repo.insert(post)
      spawn(fn -> :httpc.request(~c"http://hooks/new") end)
    end)
  end
end

defmodule Argus.Test.Soundness.Adv.Txn.FunRef do
  # (b) A task started on a named function.
  def create(post) do
    Argus.Test.Soundness.Adv.Txn.Repo.transaction(fn ->
      Argus.Test.Soundness.Adv.Txn.Repo.insert(post)
      Task.start(&Argus.Test.Soundness.Adv.Txn.Hooks.fire/0)
    end)
  end
end

defmodule Argus.Test.Soundness.Adv.Txn.Helper do
  # (c) A helper starts the task on the fun it is handed.
  def create(post) do
    Argus.Test.Soundness.Adv.Txn.Repo.transaction(fn ->
      Argus.Test.Soundness.Adv.Txn.Repo.insert(post)
      Argus.Test.Soundness.Adv.Txn.Background.run(fn -> :gen_tcp.connect(~c"hooks", 80, []) end)
    end)
  end
end

defmodule Argus.Test.Soundness.Adv.Txn.Yield do
  # (d) A supervised async_nolink the transaction yields on.
  def create(post) do
    Argus.Test.Soundness.Adv.Txn.Repo.transaction(fn ->
      Argus.Test.Soundness.Adv.Txn.Repo.insert(post)

      task =
        Task.Supervisor.async_nolink(Argus.Test.Soundness.Adv.Txn.Sup, fn ->
          :httpc.request(~c"http://h")
        end)

      Task.yield(task, 5000)
    end)
  end
end

defmodule Argus.Test.Soundness.Adv.Txn.Streams do
  # Quiet: the pusher's own process operations are not reported past the spawn.
  def create(post) do
    Argus.Test.Soundness.Adv.Txn.Repo.transaction(fn ->
      Argus.Test.Soundness.Adv.Txn.Repo.insert(post)
      for topic <- ["a", "b"], do: spawn(fn -> push(topic, post) end)
    end)
  end

  def push(topic, post) do
    Registry.dispatch(Streamer, topic, fn subs -> for {pid, _} <- subs, do: send(pid, post) end)
  end
end
