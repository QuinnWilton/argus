defmodule Argus.Test.Fixtures.TaskHandles.Collected do
  @moduledoc """
  Linked tasks the program collects, however the handle travels from the
  start to the Task operation: none is reported never awaited.
  """

  # The reported shape (#10): two generators compile to nested
  # Enum.reduce/3 closures consing each task onto the accumulator, and
  # the comprehension's caller awaits the reversed list.
  def two_generators(xs, ys) do
    tasks =
      for x <- xs, y <- ys do
        Task.async(fn -> x + y end)
      end

    Task.await_many(tasks, 180_000)
  end

  def three_generators(xs, ys, zs) do
    tasks = for x <- xs, y <- ys, z <- zs, do: Task.async(fn -> x + y + z end)
    Task.await_many(tasks)
  end

  def filtered(xs) do
    tasks = for x <- xs, x > 1, do: Task.async(fn -> x end)
    Task.await_many(tasks)
  end

  def one_generator(xs) do
    tasks = for x <- xs, do: Task.async(fn -> x end)
    Task.await_many(tasks)
  end

  def map_then_await_capture(xs) do
    xs
    |> Enum.map(fn x -> Task.async(fn -> x end) end)
    |> Enum.map(&Task.await/1)
  end

  def map_then_await_each(xs) do
    tasks = Enum.map(xs, fn x -> Task.async(fn -> x end) end)
    Enum.each(tasks, fn task -> Task.await(task) end)
  end

  def reduce_then_yield_many(xs) do
    xs
    |> Enum.reduce([], fn x, acc -> [Task.async(fn -> x end) | acc] end)
    |> Task.yield_many(5_000)
    |> Enum.map(fn {task, result} -> result || Task.shutdown(task, :brutal_kill) end)
  end

  # A fold keeping a task on one branch and the accumulator on the other.
  def reduce_some(xs) do
    xs
    |> Enum.reduce([], fn x, acc -> if x > 0, do: [Task.async(fn -> x end) | acc], else: acc end)
    |> Task.await_many()
  end

  def foldl(xs) do
    tasks = :lists.foldl(fn x, acc -> [Task.async(fn -> x end) | acc] end, [], xs)
    Task.await_many(tasks)
  end

  def erlang_map(xs) do
    tasks = :lists.map(fn x -> Task.async(fn -> x end) end, xs)
    Task.await_many(tasks)
  end

  def flat_map(xs) do
    tasks = Enum.flat_map(xs, fn x -> [Task.async(fn -> x end), Task.async(fn -> -x end)] end)
    Task.await_many(tasks)
  end

  def tuples(xs) do
    pairs = Enum.map(xs, fn x -> {x, Task.async(fn -> x end)} end)
    Enum.map(pairs, fn {x, task} -> {x, Task.await(task)} end)
  end

  def joined(xs, ys) do
    left = Enum.map(xs, fn x -> Task.async(fn -> x end) end)
    right = for y <- ys, do: Task.async(fn -> y end)
    Task.await_many(left ++ right)
  end

  def helper_awaits(x) do
    task = Task.async(fn -> x end)
    finish(task)
  end

  def factory_awaited(x) do
    task = start(x)
    Task.await(task)
  end

  def in_a_map(x) do
    jobs = Map.put(%{}, :job, Task.async(fn -> x end))
    Task.await(Map.get(jobs, :job))
  end

  def in_the_dictionary(x) do
    Process.put(:job, Task.async(fn -> x end))
    Task.await(Process.get(:job))
  end

  def yield_or_shutdown(x) do
    task = Task.async(fn -> x end)
    Task.yield(task, 1_000) || Task.shutdown(task)
  end

  def ignored(x), do: Task.ignore(Task.async(fn -> x end))

  def supervised(sup, xs) do
    tasks = for x <- xs, y <- [1, 2], do: Task.Supervisor.async(sup, fn -> x * y end)
    Task.await_many(tasks)
  end

  def mfa_starts(xs) do
    tasks = for x <- xs, y <- [1, 2], do: Task.async(Kernel, :+, [x, y])
    Task.await_many(tasks)
  end

  # Library calls value flow follows (TermFlow.Library).
  def zipped(xs) do
    tasks = Enum.map(xs, fn x -> Task.async(fn -> x end) end)
    Enum.zip(xs, tasks) |> Enum.map(fn {_x, task} -> Task.await(task) end)
  end

  def indexed(xs) do
    tasks = for x <- xs, y <- [1, 2], do: Task.async(fn -> x + y end)
    Enum.with_index(tasks) |> Enum.map(fn {task, _i} -> Task.await(task) end)
  end

  def into_a_map(xs) do
    tasks = for x <- xs, into: %{}, do: {x, Task.async(fn -> x end)}
    tasks |> Map.values() |> Task.await_many()
  end

  def streamed(xs) do
    xs
    |> Stream.map(fn x -> Task.async(fn -> x end) end)
    |> Enum.map(&Task.await/1)
  end

  defp finish(task), do: Task.await(task)

  defp start(x), do: Task.async(fn -> x end)
end

defmodule Argus.Test.Fixtures.TaskHandles.Escaped do
  @moduledoc """
  Linked tasks whose handle goes where value flow does not follow it:
  whether they are collected there is not known, and none is reported.
  """

  # A public factory: its callers, possibly outside the program, collect.
  def start_all(xs), do: for(x <- xs, y <- [1, 2], do: Task.async(fn -> x + y end))

  def sent(pid, x), do: send(pid, {:task, Task.async(fn -> x end)})

  def stored(table, x), do: :ets.insert(table, {:task, Task.async(fn -> x end)})

  def called_fun(fun, x), do: fun.(Task.async(fn -> x end))

  # Library calls no summary describes.
  def chunked(xs) do
    tasks = Enum.map(xs, fn x -> Task.async(fn -> x end) end)

    _ =
      Enum.chunk_while(tasks, [], fn t, acc -> {:cont, [t | acc]} end, fn acc ->
        {:cont, acc, []}
      end)

    :ok
  end

  def in_an_agent(agent, x), do: Agent.update(agent, fn _ -> Task.async(fn -> x end) end)

  def persisted(x), do: :persistent_term.put(:task, Task.async(fn -> x end))

  # The fun is called where the call names neither it nor its answer.
  def dynamic_fun(x), do: run(fn -> Task.async(fn -> x end) end)

  defp run(make), do: Task.await(make.())
end

defmodule Argus.Test.Fixtures.TaskHandles.Leaked do
  @moduledoc """
  Linked tasks whose every use value flow sees, none of which collects
  them: each is reported never awaited.
  """

  def mapped_and_dropped(xs) do
    _ = Enum.map(xs, fn x -> Task.async(fn -> x end) end)
    :ok
  end

  def each(xs), do: Enum.each(xs, fn x -> Task.async(fn -> x end) end)

  def two_generators_dropped(xs, ys) do
    _ = for x <- xs, y <- ys, do: Task.async(fn -> x + y end)
    :ok
  end

  def filtered_dropped(xs) do
    _ = for x <- xs, x > 1, do: Task.async(fn -> x end)
    :ok
  end

  def in_a_predicate(xs),
    do: Enum.filter(xs, fn x -> match?(%Task{}, Task.async(fn -> x end)) end)

  def reduced_and_dropped(xs) do
    _ = Enum.reduce(xs, [], fn x, acc -> [Task.async(fn -> x end) | acc] end)
    :ok
  end

  def flat_mapped_and_dropped(xs) do
    _ = Enum.flat_map(xs, fn x -> [Task.async(fn -> x end)] end)
    :ok
  end

  # The enclosing function awaits a task, but not these: crediting any
  # await would hide them.
  def awaits_another(xs) do
    first = Task.async(fn -> :first end)
    _ = for x <- xs, y <- [1, 2], do: Task.async(fn -> x + y end)
    Task.await(first)
  end

  def factory_dropped(x) do
    _ = start(x)
    :ok
  end

  def helper_drops(x) do
    task = Task.async(fn -> x end)
    drop(task)
  end

  def supervised_dropped(sup, xs) do
    _ = for x <- xs, y <- [1, 2], do: Task.Supervisor.async(sup, fn -> x * y end)
    :ok
  end

  defp start(x), do: Task.async(fn -> x end)

  defp drop(_task), do: :ok
end

defmodule Argus.Test.Fixtures.TaskHandles.StateServer do
  @moduledoc """
  A server keeping a task in its state and awaiting it in a later
  callback: the handle travels through the state, and is collected.
  """
  use GenServer

  def init(x), do: {:ok, %{task: nil, x: x}}

  def handle_cast(:start, state), do: {:noreply, %{state | task: Task.async(fn -> state.x end)}}

  def handle_call(:finish, _from, state),
    do: {:reply, Task.await(state.task), %{state | task: nil}}
end

defmodule Argus.Test.Fixtures.TaskHandles.NolinkMapped do
  @moduledoc """
  async_nolink tasks started in an Enum.map closure and collected by the
  enclosing callback: no reply or :DOWN reaches handle_info/2.
  """
  use GenServer

  def start_link(sup), do: GenServer.start_link(__MODULE__, sup)

  def init(sup), do: {:ok, %{sup: sup}}

  def handle_call({:fetch, urls}, _from, state) do
    results =
      urls
      |> Enum.map(fn url -> Task.Supervisor.async_nolink(state.sup, fn -> url end) end)
      |> Task.yield_many(5_000)

    {:reply, results, state}
  end

  def handle_info(:tick, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.TaskHandles.NolinkHelper do
  @moduledoc """
  An async_nolink task a private helper collects: no reply or :DOWN
  reaches handle_info/2.
  """
  use GenServer

  def start_link(sup), do: GenServer.start_link(__MODULE__, sup)

  def init(sup), do: {:ok, %{sup: sup}}

  def handle_call({:run, work}, _from, state) do
    task = Task.Supervisor.async_nolink(state.sup, fn -> work end)
    {:reply, collect(task), state}
  end

  def handle_info(:tick, state), do: {:noreply, state}

  defp collect(task), do: Task.yield(task, 5_000) || Task.shutdown(task)
end

defmodule Argus.Test.Fixtures.TaskHandles.NolinkCollectsAnother do
  @moduledoc """
  Two async_nolink tasks in one callback, only one of them collected:
  the other's reply and :DOWN reach a handle_info/2 that takes neither.
  Collecting any task in the function used to hide it.
  """
  use GenServer

  def start_link(sup), do: GenServer.start_link(__MODULE__, sup)

  def init(sup), do: {:ok, %{sup: sup}}

  def handle_call({:run, work}, _from, state) do
    _ = Task.Supervisor.async_nolink(state.sup, fn -> :background end)
    task = Task.Supervisor.async_nolink(state.sup, fn -> work end)
    {:reply, Task.await(task), state}
  end

  def handle_info(:tick, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.TaskHandles.NolinkThreeArity do
  @moduledoc """
  Task.Supervisor.async_nolink/3 (with options), uncollected: its reply
  and :DOWN reach a handle_info/2 that takes neither.
  """
  use GenServer

  def start_link(sup), do: GenServer.start_link(__MODULE__, sup)

  def init(sup), do: {:ok, %{sup: sup}}

  def handle_cast({:run, work}, state) do
    Task.Supervisor.async_nolink(state.sup, fn -> work end, shutdown: 1_000)
    {:noreply, state}
  end

  def handle_info(:tick, state), do: {:noreply, state}
end
