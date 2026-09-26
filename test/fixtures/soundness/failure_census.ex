defmodule Argus.Test.Soundness.Census.Failure do
  @moduledoc """
  The exclusion census's failure hole (docs/design/exclusions.md,
  "Soundness surprises") and its adversarial neighbours: an Elixir `if`
  over an rpc's answer compiles to a select over false and nil, which was
  read as a match, never as a boolean; and a predicate returning a
  wrapper's rpc answer was nobody's to report. A node that is gone answers
  `{:badrpc, :nodedown}`, which is true. Asserted by
  test/soundness/failure_test.exs.
  """
end

defmodule Argus.Test.Soundness.Census.Failure.Proto do
  @moduledoc "A proto module: one :rpc.call per function."
  def alive(node, pid), do: :rpc.call(node, Process, :alive?, [pid])
end

defmodule Argus.Test.Soundness.Census.Failure.Cluster do
  @moduledoc """
  The census program: the facade's predicate returns the proto's answer,
  so alive?/2 says a process on a gone node is alive.
  """
  def alive?(node, pid), do: Argus.Test.Soundness.Census.Failure.Proto.alive(node, pid)
end

defmodule Argus.Test.Soundness.Census.Failure.Router do
  @moduledoc "An `if` over the rpc, over a `&&`, and over the facade's non-predicate."
  alias Argus.Test.Soundness.Census.Failure.Proto

  def route(node, pid, msg) do
    if :rpc.call(node, Process, :alive?, [pid]), do: send(pid, msg), else: {:error, :dead}
  end

  def ping(node, pid), do: :rpc.call(node, Process, :alive?, [pid]) && :ok

  def forward(node, pid, msg) do
    if Proto.alive(node, pid), do: send(pid, msg), else: {:error, :dead}
  end

  def reap(node, pid) do
    unless :rpc.call(node, Process, :alive?, [pid]), do: :gone
  end
end

defmodule Argus.Test.Soundness.Census.Failure.SafeRouter do
  @moduledoc "Quiet: the answer is matched, the :badrpc included."
  def route(node, pid, msg) do
    case :rpc.call(node, Process, :alive?, [pid]) do
      true -> send(pid, msg)
      false -> {:error, :dead}
      {:badrpc, reason} -> {:error, reason}
    end
  end
end

defmodule Argus.Test.Soundness.Census.Failure.SafeProto do
  @moduledoc "Takes the :badrpc itself: no wrapper."
  def alive(node, pid) do
    case :rpc.call(node, Process, :alive?, [pid]) do
      {:badrpc, _} -> false
      answer -> answer
    end
  end
end

defmodule Argus.Test.Soundness.Census.Failure.SafeCluster do
  @moduledoc "Quiet: the predicate returns an answer its callee already made a boolean."
  def alive?(node, pid), do: Argus.Test.Soundness.Census.Failure.SafeProto.alive(node, pid)
end
