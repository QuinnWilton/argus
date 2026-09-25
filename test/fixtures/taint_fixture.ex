defmodule Argus.Test.Fixtures.Taint do
  @moduledoc """
  Fixtures for the proven-flow proximity of `unsafe_input`.

  Behaviours are bare `@behaviour` attributes naming modules that do not
  exist here, as in `RequestSurface`: the OTP extractor reads the
  attribute out of the beam. `Store` stands in for a database: whatever
  it returns is fresh data, however it was asked for.
  """

  defmodule Store do
    @moduledoc false
    def load(id), do: Process.get(id)
  end

  defmodule FlowLiveView do
    @moduledoc "Request params reach the sink: through a head pattern, and through a helper from a second clause."
    @behaviour Phoenix.LiveView

    def handle_event("save", %{"name" => name}, socket) do
      _ = String.to_atom("field_" <> name)
      {:noreply, socket}
    end

    def handle_event(_event, params, socket) do
      order_by(params["order_by"])
      {:noreply, socket}
    end

    defp order_by(field), do: String.to_atom(field)
  end

  defmodule FlowTransitive do
    @moduledoc "The job's args reach a sink two calls down, through Map.get."
    @behaviour Oban.Worker

    def perform(job), do: level_one(job)
    def level_one(job), do: level_two(Map.get(job.args, "kind"))
    def level_two(kind), do: String.to_atom(kind)
  end

  defmodule FlowClosureEnv do
    @moduledoc "A request value captured by a closure reaches the sink inside it."
    @behaviour Phoenix.LiveView

    @suffixes ["_id", "_name"]

    def handle_event(_event, %{"prefix" => prefix}, socket) do
      Enum.each(@suffixes, fn suffix -> String.to_atom(prefix <> suffix) end)
      {:noreply, socket}
    end
  end

  # ── Paths that are not flows ──────────────────────────────────────

  defmodule StoreSourcedPlug do
    @moduledoc "The sequin shape: the sink converts a record loaded from storage, inside the callback."
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, _opts) do
      record = Store.load(:current)
      _ = String.to_atom(record.kind)
      conn
    end
  end

  defmodule StoreSourcedAdjacent do
    @moduledoc "One call away, but the helper's input is a stored record."
    @behaviour Phoenix.LiveView

    def handle_params(_params, _uri, socket) do
      convert(Store.load(:current))
      {:noreply, socket}
    end

    def convert(record), do: String.to_atom(record.kind)
  end

  defmodule StoreSourcedWorker do
    @moduledoc "Two calls away, and nothing from the job reaches the sink."
    @behaviour Oban.Worker

    def perform(_job), do: level_one()
    def level_one, do: level_two(Store.load(:current))
    def level_two(record), do: String.to_atom(record.kind)
  end

  defmodule SocketOnly do
    @moduledoc "The socket is the application's; its assigns are not the request."
    @behaviour Phoenix.LiveView

    def handle_event(_event, _params, socket) do
      _ = String.to_atom(socket.assigns.field)
      {:noreply, socket}
    end
  end

  defmodule SessionOnly do
    @moduledoc "mount/3's session is signed by the endpoint, not typed by the client."
    @behaviour Phoenix.LiveView

    def mount(_params, %{"role" => role}, socket) do
      _ = String.to_atom(role)
      {:ok, socket}
    end
  end

  defmodule LiteralAtom do
    @moduledoc "A constant argument derives from nothing."
    @behaviour Phoenix.LiveView

    def handle_event(_event, _params, socket) do
      _ = String.to_atom("fixed")
      {:noreply, socket}
    end
  end

  defmodule ExistingAtom do
    @moduledoc "The safe conversion is not a sink at all."
    @behaviour Phoenix.LiveView

    def handle_event(_event, %{"name" => name}, socket) do
      String.to_existing_atom(name)
      {:noreply, socket}
    end
  end

  defmodule HofElement do
    @moduledoc "Element flow through a higher-order function's closure: the closure runs on each id."
    @behaviour Phoenix.LiveView

    def handle_event(_event, %{"ids" => ids}, socket) do
      Enum.map(ids, fn id -> String.to_atom(id) end)
      {:noreply, socket}
    end
  end

  defmodule GuardAllowlist do
    @moduledoc """
    logflare's SearchLV: the event name reaches the atom only through a
    clause whose guard holds it to two literals. One of two atoms.
    """
    @behaviour Phoenix.LiveView

    def handle_event(direction, _params, socket) when direction in ["backwards", "forwards"] do
      _ = String.to_atom(direction)
      {:noreply, socket}
    end

    def handle_event(_event, _params, socket), do: {:noreply, socket}
  end

  defmodule BodyAllowlist do
    @moduledoc """
    The same allowlist in the body: a short literal list (compiled to
    comparisons), a long one (compiled to :lists.member/2), and a value
    built of the allowed one.
    """
    @behaviour Phoenix.LiveView

    @columns ~w(c01 c02 c03 c04 c05 c06 c07 c08 c09 c10 c11 c12 c13 c14 c15 c16 c17
                c18 c19 c20 c21 c22 c23 c24 c25 c26 c27 c28 c29 c30 c31 c32 c33 c34)

    def handle_event("tab", %{"tab" => tab}, socket) do
      if tab in ["info", "logs"], do: String.to_atom("tab_" <> tab)
      {:noreply, socket}
    end

    def handle_event("sort", %{"by" => column}, socket) do
      if column in @columns, do: String.to_atom(column)
      {:noreply, socket}
    end
  end

  defmodule Allow do
    @moduledoc "hexpm's safe_to_atom/2: an allowlist the caller hands in."
    def safe_to_atom(binary, allowed) when is_binary(binary) do
      if binary in allowed, do: String.to_atom(binary)
    end

    def safe_to_atom(_binary, _allowed), do: nil
  end

  defmodule ParamAllowlist do
    @moduledoc "Every caller of Allow.safe_to_atom/2 hands it a literal list."
    @behaviour Phoenix.LiveView

    @sort ~w(name recent_downloads inserted_at)

    def handle_event("sort", %{"sort" => sort}, socket) do
      _ = Allow.safe_to_atom(sort, @sort)
      {:noreply, socket}
    end
  end

  defmodule OpenAllowlist do
    @moduledoc "A caller hands the allowlist in from the request itself: no bound."
    @behaviour Phoenix.LiveView

    def handle_event("sort", %{"sort" => sort, "allowed" => allowed}, socket) do
      _ = Allow.safe_to_atom(sort, allowed)
      {:noreply, socket}
    end
  end

  defmodule SameLine do
    @moduledoc "Two atoms made on one line of source: one finding for the line."
    @behaviour Phoenix.LiveView

    def handle_event("pair", %{"a" => a, "b" => b}, socket) do
      _ = {String.to_atom(a), String.to_atom(b)}
      {:noreply, socket}
    end
  end

  defmodule SameLineMixed do
    @moduledoc """
    Two atoms made on one line, one of configuration and one of the
    request's own value: two calls one after the other whose arguments
    come from different places, not the compiler's copies of one.
    """
    @behaviour Phoenix.LiveView

    def handle_event("pair", %{"b" => b}, socket) do
      _ = {String.to_atom(Application.get_env(:probe, :default_key)), String.to_atom(b)}
      {:noreply, socket}
    end
  end

  defmodule Controller do
    @moduledoc """
    A Phoenix controller as `use Phoenix.Controller` compiles it: `call/2`
    runs the pipeline, whose `action/2` applies the action the router
    named, read off the conn, so no call edge reaches an action. Each
    exported arity-2 function of a module defining
    `phoenix_controller_pipeline/2` is an action: the conn and the params
    are the request. `show/2` converts a param to an atom (a flow);
    `index/2` converts it safely.
    """
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, opts), do: phoenix_controller_pipeline(conn, opts)

    def phoenix_controller_pipeline(conn, opts), do: action(conn, opts)

    def action(%{private: %{phoenix_action: name}} = conn, _opts),
      do: apply(__MODULE__, name, [conn, conn.params])

    def show(conn, %{"sort" => sort}), do: {conn, String.to_atom(sort)}

    def index(conn, %{"sort" => sort}), do: {conn, String.to_existing_atom(sort)}
  end

  defmodule CookieController do
    @moduledoc """
    A controller reading cookies. `session/2` decodes a cookie it
    fetched signed: the server wrote and signed it, so it is no request
    data. `prefs/2` decodes one it fetched unverified: a flow.
    """
    @behaviour Plug
    @compile {:no_warn_undefined, Plug.Conn}

    def init(opts), do: opts

    def call(conn, opts), do: phoenix_controller_pipeline(conn, opts)

    def phoenix_controller_pipeline(conn, opts), do: action(conn, opts)

    def action(%{private: %{phoenix_action: name}} = conn, _opts),
      do: apply(__MODULE__, name, [conn, conn.params])

    def session(conn, _params) do
      conn = Plug.Conn.fetch_cookies(conn, signed: ["state"])
      :erlang.binary_to_term(conn.cookies["state"], [:safe])
    end

    def prefs(conn, _params) do
      conn = Plug.Conn.fetch_cookies(conn)
      :erlang.binary_to_term(conn.cookies["prefs"], [:safe])
    end
  end

  defmodule PlainPlugHelpers do
    @moduledoc """
    A Plug that is not a controller: its exported arity-2 helper is not
    an action, and nothing a request reaches calls it.
    """
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, _opts), do: conn

    def label(_conn, name), do: String.to_atom(name)
  end
end
