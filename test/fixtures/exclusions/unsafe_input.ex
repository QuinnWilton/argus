# Cases for unsafe-input exclusions and nearby defects that must remain reported.
# Asserted by test/exclusions/unsafe_input_test.exs.

# The `after` block of a try runs on both the normal and the exception
# path, and the compiler emits it twice: two :os.cmd calls on one line,
# one sink. The copy is the first's, reported once.
defmodule Excl.UnsafeInput.TryAfterSink.Scratch do
  @moduledoc false
  def with_scratch_dir(path, fun) do
    File.mkdir_p!(path)

    try do
      fun.(path)
    after
      :os.cmd(String.to_charlist("rm -rf " <> path))
    end
  end
end

# decode/1 deserializes a blob only when it is one of the two the
# program wrote itself (compared equal in the guard): the bytes are the
# program's own, not a caller's.
defmodule Excl.UnsafeInput.BoundedDecode.Snapshot do
  @moduledoc false
  @empty :erlang.term_to_binary(%{})
  @default :erlang.term_to_binary(%{mode: :default, limit: 10})

  def decode(blob) when blob in [@empty, @default], do: :erlang.binary_to_term(blob)
  def decode(_blob), do: {:error, :unknown_snapshot}
end

# The same decode taking any blob its caller hands it: binary_to_term/1
# on a caller's bytes can make atoms and funs. What the guard above
# rules out.
defmodule Excl.UnsafeInput.OpenDecode.Snapshot do
  @moduledoc false
  def decode(blob), do: :erlang.binary_to_term(blob)
end

# A LiveView event checks targets through async_stream_nolink (tasks
# bounded by the request's own enumeration) and then notifies: inline
# when asked to, else by Task.Supervisor.start_child on the same uncapped
# supervisor, which every request can repeat without bound. The stream
# does not excuse the start_child: a real bug the analysis must keep
# reporting.
defmodule Excl.UnsafeInput.StreamAndStart.TaskSup do
  @moduledoc false
  def child_spec(_), do: Task.Supervisor.child_spec(name: __MODULE__)
end

defmodule Excl.UnsafeInput.StreamAndStart.Checker do
  @moduledoc false
  def check(target), do: {target, :ok}
  def notify(results), do: IO.inspect(results)
end

defmodule Excl.UnsafeInput.StreamAndStart.CheckLive do
  @moduledoc false
  @behaviour Phoenix.LiveView
  alias Excl.UnsafeInput.StreamAndStart.{Checker, TaskSup}

  def mount(_p, _s, socket), do: {:ok, socket}

  def handle_event("check", %{"targets" => targets, "mode" => mode}, socket) do
    results =
      TaskSup
      |> Task.Supervisor.async_stream_nolink(targets, &Checker.check/1)
      |> Enum.to_list()

    if mode == "now" do
      Checker.notify(results)
    else
      Task.Supervisor.start_child(TaskSup, Checker, :notify, [results])
    end

    {:noreply, Map.put(socket, :results, results)}
  end

  def render(assigns), do: assigns
end
