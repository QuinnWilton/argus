# An unread value is unknown, never the default (issue #4): only an
# absent key takes OTP's or the library's default. Each narrowing has
# the shapes that must keep their finding, positive evidence of the
# value the finding needs, beside a quiet one the unread value leaves
# unknown. test/soundness/unread_test.exs asserts them.

# ── A child spec's type, from its argument's options ───────────────────

defmodule Argus.Test.Soundness.Unread.TypedSup do
  @moduledoc """
  A supervisor whose child_spec/1 takes its type from its argument,
  `:worker` by default: registered as a worker where a start's argument
  holds no `:type`.
  """
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: Keyword.get(opts, :type, :worker)
    }
  end

  @impl true
  def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
end

defmodule Argus.Test.Soundness.Unread.UnreadTypeSup do
  @moduledoc "Quiet: a type the extractor cannot read (`||`) is unknown, not the worker default."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: opts[:type] || :worker}
  end

  @impl true
  def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
end

defmodule Argus.Test.Soundness.Unread.TypedStarts do
  @moduledoc false
  use DynamicSupervisor

  alias Argus.Test.Soundness.Unread.{TypedSup, UnreadTypeSup}

  def start_link, do: DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)

  # Must fire: the default, `:worker`.
  def by_default, do: DynamicSupervisor.start_child(__MODULE__, {TypedSup, []})

  # Must fire: the argument says `:worker` itself.
  def as_worker, do: DynamicSupervisor.start_child(__MODULE__, {TypedSup, type: :worker})

  # Quiet: the argument says `:supervisor`; one the extractor cannot read
  # may; a type it cannot read is unknown.
  def as_supervisor, do: DynamicSupervisor.start_child(__MODULE__, {TypedSup, type: :supervisor})
  def handed(opts), do: DynamicSupervisor.start_child(__MODULE__, {TypedSup, opts})
  def unread, do: DynamicSupervisor.start_child(__MODULE__, {UnreadTypeSup, []})

  @impl true
  def init([]), do: DynamicSupervisor.init(strategy: :one_for_one)
end

defmodule Argus.Test.Soundness.Unread.ListTyped do
  @moduledoc "Must fire: the default type in a child list, the argument without `:type`."
  use Supervisor

  alias Argus.Test.Soundness.Unread.TypedSup

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg)

  @impl true
  def init(_arg), do: Supervisor.init([{TypedSup, name: :typed}], strategy: :one_for_one)
end

# ── A computed restart in OTP's tuple form ──────────────────────────────

defmodule Argus.Test.Soundness.Unread.TupleOwner do
  @moduledoc false
  # Makes a named, public table in init/1 with no heir: "ETS table dies
  # with its owner" says whether a supervisor is shown to restart it.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg) do
    :ets.new(:unread_tuple_owner, [:named_table, :public, :set])
    {:ok, nil}
  end
end

defmodule Argus.Test.Soundness.Unread.PermanentTupleOwner do
  @moduledoc false
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg) do
    :ets.new(:unread_permanent_tuple_owner, [:named_table, :public, :set])
    {:ok, nil}
  end
end

defmodule Argus.Test.Soundness.Unread.TupleSup do
  @moduledoc """
  OTP's tuple form built at run time: TupleOwner's restart comes from a
  call, PermanentTupleOwner's is the literal. The first is unknown — its
  table is not shown to come back — where the tuple once read as a
  shorthand of the module its id names, under the default.
  """
  use Supervisor

  alias Argus.Test.Soundness.Unread.{PermanentTupleOwner, TupleOwner}

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg)

  @impl true
  def init(arg) do
    children = [
      {TupleOwner, {TupleOwner, :start_link, [arg]}, restart(), 5000, :worker, [TupleOwner]},
      {:permanent_tuple_owner, {PermanentTupleOwner, :start_link, [arg]}, :permanent, 5000,
       :worker, [PermanentTupleOwner]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp restart, do: Application.get_env(:unread, :restart, :permanent)
end

# ── A DynamicSupervisor's max_children ───────────────────────────────────

# Supervisors a request starts children under (CapsLive). Must fire: no
# cap in options read whole, a literal `:infinity`, no cap in options a
# helper returns. Quiet: a cap, and options merged from the argument,
# which may hold one.
defmodule Argus.Test.Soundness.Unread.Caps.NoCap do
  @moduledoc "No cap in options read whole: the default, :infinity."
  use DynamicSupervisor

  def start_link(arg), do: DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg), do: DynamicSupervisor.init(strategy: :one_for_one)
end

defmodule Argus.Test.Soundness.Unread.Caps.InfinityCap do
  @moduledoc "A literal :infinity."
  use DynamicSupervisor

  def start_link(arg), do: DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg), do: DynamicSupervisor.init(strategy: :one_for_one, max_children: :infinity)
end

defmodule Argus.Test.Soundness.Unread.Caps.HelperOpts do
  @moduledoc "No cap in the options a helper returns."
  use DynamicSupervisor

  def start_link(arg), do: DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg), do: DynamicSupervisor.init(opts())

  defp opts, do: [strategy: :one_for_one]
end

defmodule Argus.Test.Soundness.Unread.Caps.Capped do
  @moduledoc "Quiet: a cap."
  use DynamicSupervisor

  def start_link(arg), do: DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg), do: DynamicSupervisor.init(strategy: :one_for_one, max_children: 50)
end

defmodule Argus.Test.Soundness.Unread.Caps.MergedOpts do
  @moduledoc "Quiet: options merged from the argument, which may hold a cap."
  use DynamicSupervisor

  def start_link(arg), do: DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(arg), do: DynamicSupervisor.init(Keyword.merge([strategy: :one_for_one], arg))
end

defmodule Argus.Test.Soundness.Unread.CapsLive do
  @moduledoc "A request starts a child under each supervisor."
  @behaviour Phoenix.LiveView

  alias Argus.Test.Soundness.Unread.{Caps, TupleOwner}

  def mount(_p, _s, socket), do: {:ok, socket}

  def handle_event("no_cap", _params, socket) do
    DynamicSupervisor.start_child(Caps.NoCap, TupleOwner)
    {:noreply, socket}
  end

  def handle_event("infinity", _params, socket) do
    DynamicSupervisor.start_child(Caps.InfinityCap, TupleOwner)
    {:noreply, socket}
  end

  def handle_event("helper", _params, socket) do
    DynamicSupervisor.start_child(Caps.HelperOpts, TupleOwner)
    {:noreply, socket}
  end

  def handle_event("capped", _params, socket) do
    DynamicSupervisor.start_child(Caps.Capped, TupleOwner)
    {:noreply, socket}
  end

  def handle_event("merged", _params, socket) do
    DynamicSupervisor.start_child(Caps.MergedOpts, TupleOwner)
    {:noreply, socket}
  end

  def render(assigns), do: assigns
end

# ── An Erlang flags map with no strategy ─────────────────────────────────

defmodule Argus.Test.Soundness.Unread.FlagsMapSup do
  @moduledoc "An Erlang-style init/1 whose flags map states no strategy: OTP's one_for_one."
  @behaviour :supervisor

  def start_link, do: :supervisor.start_link(__MODULE__, [])

  @impl true
  def init([]) do
    {:ok,
     {%{intensity: 1, period: 5},
      [%{id: :owner, start: {Argus.Test.Soundness.Unread.TupleOwner, :start_link, [[]]}}]}}
  end
end
