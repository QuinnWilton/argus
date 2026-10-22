# Soundness fixtures (review 2): each shape must keep the severity its
# test states. Probes of the review and adversarial neighbours.
# credo:disable-for-this-file
defmodule Argus.Test.Soundness.G2.AtomExistingPlug do
  # The request-reached form: a sort parameter made "safe" with
  # to_existing_atom, then suffixed. ?sort=name makes :name_desc; the
  # next request ?sort=name_desc makes :name_desc_desc; and so on, one
  # new atom per request until the table is full and the node aborts.
  @behaviour Plug
  def init(opts), do: opts

  def call(conn, _opts) do
    field = String.to_existing_atom(conn.params["sort"])
    key = String.to_atom(Atom.to_string(field) <> "_desc")
    %{conn | assigns: Map.put(conn.assigns, :order, key)}
  end
end

defmodule Argus.Test.Soundness.G2.AtomExistingChain do
  # `String.to_existing_atom/1` is the usual "safe" conversion of a
  # caller's string: it makes no atom. But an atom MADE of the atom it
  # returns is new — and is itself an existing atom on the next request.
  # A caller sends "x", then "x_cache", then "x_cache_cache", ...: one new
  # atom per request, without limit. The atoms-of-atoms bound treats "the
  # atoms that exist" as a fixed set; here the program grows it on the
  # caller's command.
  def cache_key(params) do
    field = String.to_existing_atom(Map.fetch!(params, "field"))
    String.to_atom(Atom.to_string(field) <> "_cache")
  end

  # The same behind an is_atom guard, as a helper a controller calls.
  def scoped(scope, params) when is_atom(scope) do
    name = String.to_existing_atom(params["name"])
    :"#{scope}_#{name}"
  end
end

defmodule Argus.Test.Soundness.G2.AtomChain do
  # Every atom here is made of an atom — `is_atom/1` says so — but each is
  # made of the LAST one this function made: the set of atoms that exist
  # grows by one per call, without limit. The atoms-of-atoms bound counts
  # the atoms that exist as fixed; a program feeding its own atoms back
  # into the site is unbounded in the number of calls.

  # A server that names each new worker after the previous name.
  use GenServer
  def start_link(base), do: GenServer.start_link(__MODULE__, base, name: __MODULE__)
  def next_name, do: GenServer.call(__MODULE__, :next)
  @impl true
  def init(base), do: {:ok, base}
  @impl true
  def handle_call(:next, _from, last) when is_atom(last) do
    name = :"#{last}_next"
    {:reply, name, name}
  end

  # A path of `depth` names under `base`: the caller picks the depth.
  def nested(base, depth) when is_atom(base) and is_integer(depth) do
    if depth <= 0, do: base, else: nested(:"#{base}.child", depth - 1)
  end
end

defmodule Argus.Test.Soundness.G2.RangeProduct do
  # Each factor is a close integer range (<= 1,024 values, "a thousandth
  # of the default atom table"), but the atom is made of two or three of
  # them: the product is the whole table. A caller that walks the grid
  # interns 1,048,576 atoms — the default cap — and the node aborts.
  def tile(x, y) when x in 0..1023 and y in 0..1023, do: String.to_atom("tile_#{x}_#{y}")

  # Three coordinates of 128 each: 2,097,152 atoms.
  def voxel(x, y, z) when x in 0..127 and y in 0..127 and z in 0..127,
    do: :"voxel_#{x}_#{y}_#{z}"
end

defmodule Argus.Test.Soundness.G1.CookieController2 do
  # As CookieController, with the decode in a helper module (a
  # Prefs.decode/1 two calls away): the unsigned cookie and the param
  # read off the conn fetch_cookies/2 returned are client bytes.
  @behaviour Plug
  @compile {:no_warn_undefined, Plug.Conn}

  def init(opts), do: opts
  def call(conn, opts), do: phoenix_controller_pipeline(conn, opts)
  def phoenix_controller_pipeline(conn, opts), do: action(conn, opts)

  def action(%{private: %{phoenix_action: name}} = conn, _opts),
    do: apply(__MODULE__, name, [conn, conn.params])

  def prefs(conn, _params) do
    conn = Plug.Conn.fetch_cookies(conn, signed: ["session"])
    {conn, Argus.Test.Soundness.G1.Prefs.load(conn.cookies["prefs"])}
  end
end

defmodule Argus.Test.Soundness.G1.Prefs do
  def load(nil), do: %{}
  def load(bytes), do: decode(Base.decode64!(bytes))
  defp decode(bin), do: :erlang.binary_to_term(bin)
end

defmodule Argus.Test.Soundness.G1.CookieController do
  # A controller that verifies its signed session cookie with
  # fetch_cookies/2, then reads OTHER data off the conn fetch_cookies/2
  # returned: an unsigned cookie (still whatever the client sent) and a
  # query param. Both reach a sink: atom exhaustion and binary_to_term.
  @behaviour Plug
  @compile {:no_warn_undefined, Plug.Conn}

  def init(opts), do: opts
  def call(conn, opts), do: phoenix_controller_pipeline(conn, opts)
  def phoenix_controller_pipeline(conn, opts), do: action(conn, opts)

  def action(%{private: %{phoenix_action: name}} = conn, _opts),
    do: apply(__MODULE__, name, [conn, conn.params])

  # The unsigned "prefs" cookie arrives in the same conn as the signed one.
  def prefs(conn, _params) do
    conn = Plug.Conn.fetch_cookies(conn, signed: ["session"])
    :erlang.binary_to_term(conn.cookies["prefs"])
  end

  # A param read off the conn fetch_cookies/2 handed back.
  def theme(conn, _params) do
    conn = Plug.Conn.fetch_cookies(conn, encrypted: ["session"])
    String.to_atom(conn.params["theme"])
  end
end

defmodule Argus.Test.Soundness.G8.CalcView do
  def render(template, assigns), do: render_template(template, assigns)
  def render_template("result.json", assigns), do: __MODULE__."result.json"(assigns)

  def unquote(:"result.json")(assigns) do
    {value, _} = Code.eval_string(assigns.expr)
    %{result: value}
  end
end

defmodule Argus.Test.Soundness.G8.CalcController do
  # The request's own `expr` param is rendered into a JSON template that
  # evaluates it: remote code execution, first-order. Before f3de9041
  # `flow` (:error); after, `rendered` (:warning).
  @behaviour Plug
  alias Argus.Test.Soundness.G8.CalcView

  def init(opts), do: opts
  def call(conn, opts), do: phoenix_controller_pipeline(conn, opts)
  def phoenix_controller_pipeline(conn, opts), do: action(conn, opts)

  def action(%{private: %{phoenix_action: name}} = conn, _opts),
    do: apply(__MODULE__, name, [conn, conn.params])

  def calc(conn, params), do: {conn, CalcView.render("result.json", %{expr: params["expr"]})}
end

defmodule Argus.Test.Soundness.G8.ScopesView do
  # Phoenix.Template's compiled view: `"_scopes.html"/1` of its assigns,
  # dispatched by render/2.
  def render(template, assigns), do: render_template(template, assigns)

  def render_template("_scopes.html", assigns), do: __MODULE__."_scopes.html"(assigns)

  def unquote(:"_scopes.html")(assigns) do
    for scope <- assigns.scopes, do: String.to_atom("scope_" <> scope)
  end
end

defmodule Argus.Test.Soundness.G8.ScopesController do
  # The action renders the request's OWN params into the template: every
  # request mints atoms of the caller's choosing (a first-order flow, no
  # row in between). Before f3de9041 this was `flow` (:error).
  @behaviour Plug
  alias Argus.Test.Soundness.G8.ScopesView

  def init(opts), do: opts
  def call(conn, opts), do: phoenix_controller_pipeline(conn, opts)
  def phoenix_controller_pipeline(conn, opts), do: action(conn, opts)

  def action(%{private: %{phoenix_action: name}} = conn, _opts),
    do: apply(__MODULE__, name, [conn, conn.params])

  def authorize(conn, params) do
    scopes = String.split(params["scope"] || "", " ")
    {conn, ScopesView.render("_scopes.html", %{scopes: scopes})}
  end
end

defmodule Argus.Test.Soundness.G1.BackgroundStreamLive do
  # A request fires off a background fan-out: the stream is enumerated by
  # an unsupervised Task.start process, not by the request, so every
  # click adds another max_concurrency supervised tasks that outlive the
  # request (and nothing bounds how many clicks run at once).
  @behaviour Phoenix.LiveView

  def mount(_p, _s, socket), do: {:ok, socket}

  def handle_event("sync_all", %{"ids" => ids}, socket) do
    Task.start(fn -> fan_out(ids) end)
    {:noreply, socket}
  end

  defp fan_out(ids) do
    Argus.Test.Soundness.G1.BgTaskSup
    |> Task.Supervisor.async_stream_nolink(ids, &sync_one/1, timeout: :infinity)
    |> Stream.run()
  end

  defp sync_one(id), do: Process.sleep(id)

  def render(assigns), do: assigns
end

defmodule Argus.Test.Soundness.G1.BgApp do
  use Supervisor
  def start_link(o), do: Supervisor.start_link(__MODULE__, o, name: __MODULE__)
  @impl true
  def init(_),
    do:
      Supervisor.init([{Task.Supervisor, name: Argus.Test.Soundness.G1.BgTaskSup}],
        strategy: :one_for_one
      )
end

# 5081d52d: a program find_executable/1 finds for a literal name is read as
# that literal name, and a literal non-interpreter command is no sink. But
# several such programs run their arguments as a command: env, sudo, xargs,
# ssh (the remote shell parses the command), docker/kubectl exec.
defmodule Argus.Test.Soundness.G9.FoundWrapper do
  # env runs its first argument as a program with the rest as argv.
  def via_env(cmd, args) do
    env = System.find_executable("env")
    System.cmd(env, [cmd | args])
  end

  # ssh hands the command string to the remote login shell.
  def via_ssh(host, command) do
    ssh = System.find_executable("ssh")
    System.cmd(ssh, [host, command])
  end

  # docker exec ... sh -c script: the shell is in argv, not the command.
  def via_docker(container, script) do
    docker = System.find_executable("docker")
    System.cmd(docker, ["exec", container, "sh", "-c", script])
  end

  # :os.find_executable/2 searches a caller-chosen path: whatever file named
  # ffprobe sits there runs.
  def via_search_path(dir, file) do
    exe = :os.find_executable(~c"ffprobe", String.to_charlist(dir))
    System.cmd(List.to_string(exe), [file])
  end
end

# 5081d52d: interpreters PATH finds that @interpreters does not list.
defmodule Argus.Test.Soundness.G9.FoundMix do
  # `mix run -e` evaluates Elixir code.
  def run_snippet(code) do
    mix = System.find_executable("mix")
    System.cmd(mix, ["run", "-e", code])
  end

  # php -r runs PHP code.
  def php(code) do
    php = System.find_executable("php")
    System.cmd(php, ["-r", code])
  end
end

defmodule Argus.Test.Soundness.G6.RanchAtom do
  @compile {:no_warn_undefined, [{:ranch, :handshake, 1}]}

  # A Ranch protocol written as a hand-entered gen_server loop: it declares
  # only :ranch_protocol, and its handle_info/2 takes the socket's bytes.
  # Every frame a client sends becomes a term: binary_to_term/1 without
  # [:safe] creates atoms (and funs) from network bytes.
  @behaviour :ranch_protocol

  def start_link(ref, transport, opts) do
    {:ok, :proc_lib.spawn_link(__MODULE__, :init, [{ref, transport, opts}])}
  end

  def init({ref, transport, _opts}) do
    {:ok, socket} = :ranch.handshake(ref)
    :ok = transport.setopts(socket, active: :once)
    :gen_server.enter_loop(__MODULE__, [], %{socket: socket, transport: transport})
  end

  def handle_info({:tcp, socket, data}, %{transport: transport} = s) do
    frame = String.to_atom(data)
    :ok = transport.setopts(socket, active: :once)
    {:noreply, Map.put(s, :last, frame)}
  end

  def handle_info({:tcp_closed, _socket}, s), do: {:stop, :normal, s}
  def handle_call(_msg, _from, s), do: {:reply, :ok, s}
  def handle_cast(_msg, s), do: {:noreply, s}
end

defmodule Argus.Test.Soundness.G6.RuntimeOptsCodec do
  # Connects with options built at run time, which show no active mode, and
  # interns a codec name an internal message carries: no socket entry.
  use GenServer

  def init(opts) do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", 4000, opts ++ [active: false])
    {:ok, %{socket: socket}}
  end

  def handle_info({:set_codec, name}, s), do: {:noreply, Map.put(s, :codec, String.to_atom(name))}
end

defmodule Argus.Test.Soundness.G6.GossipTerm do
  # libcluster's Gossip: options joined at run time around a literal part
  # asking for an active socket. Its datagrams are an outside party's.
  use GenServer

  def init(port) do
    options = [:binary, active: true, reuseaddr: true] ++ extra(port)
    {:ok, socket} = :gen_udp.open(port, options)
    {:ok, %{socket: socket}}
  end

  def handle_info({:udp, _socket, _ip, _port, packet}, s),
    do: {:noreply, Map.put(s, :last, :erlang.binary_to_term(packet))}

  defp extra(port), do: if(port > 1024, do: [broadcast: true], else: [])
end

defmodule Argus.Test.Soundness.G6.PassiveWrapper do
  # Hands a wrapper `active: false`: a passive socket sends no messages.
  use GenServer

  def init(_), do: {:ok, %{socket: connect(~c"localhost", 4000, active: false)}}

  def handle_info({:set_codec, name}, s), do: {:noreply, Map.put(s, :codec, String.to_atom(name))}

  defp connect(host, port, opts) do
    {:ok, socket} = :gen_tcp.connect(host, port, opts)
    socket
  end
end

defmodule Argus.Test.Soundness.G6.UdpTerm do
  # A gen_udp server active socket: each datagram's bytes arrive in handle_info/2 as
  # {:udp, _, _, _, Data}, the shape libcluster's gossip strategy uses. Here a helper
  # strips a prefix and binary_to_term/1 (no [:safe]) decodes the rest, so an
  # unauthenticated peer's datagram reaches the deserializer: socket-data, not internal.
  use GenServer

  def start_link(p), do: GenServer.start_link(__MODULE__, p)

  def init(p) do
    {:ok, socket} = :gen_udp.open(p, [:binary, active: true])
    {:ok, %{socket: socket}}
  end

  def handle_info({:udp, _socket, _ip, _port, <<"hb::", _::binary>> = packet}, state) do
    _ = decode(packet)
    {:noreply, state}
  end

  defp decode(<<"hb::", rest::binary>>), do: :erlang.binary_to_term(rest)
end

defmodule Argus.Test.Soundness.G6.InetTcpTerm do
  # A plain gen_server handed an accepted TCP socket, made active with a
  # direct :inet.setopts/2 (active: :once) rather than a transport-module
  # wrapper or gen_udp.open. This is the riak_core_lite handoff-receiver
  # shape: handle_info/2 takes the socket's frame and a helper decodes it
  # with binary_to_term/1 (no [:safe]), so an unauthenticated peer's bytes
  # reach the deserializer.
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [])
  def init(_), do: {:ok, %{}}

  def handle_call({:set_socket, socket}, _from, s) do
    :ok = :inet.setopts(socket, active: :once)
    {:reply, :ok, Map.put(s, :socket, socket)}
  end

  def handle_info({:tcp, socket, data}, s) do
    _ = decode(data)
    :ok = :inet.setopts(socket, active: :once)
    {:noreply, s}
  end

  def handle_info({:tcp_closed, _socket}, s), do: {:stop, :normal, s}

  defp decode(data), do: :erlang.binary_to_term(data)
end

defmodule Argus.Test.Soundness.Adv.Atoms.ChosenInCaller do
  # (a) The lookup is in the caller, the atoms bound in the helper.
  def key(params), do: suffixed(String.to_existing_atom(params["f"]))
  defp suffixed(a) when is_atom(a), do: String.to_atom(Atom.to_string(a) <> "_cache")

  # (b) Erlang's charlist lookup, in the same function.
  def list_key(chars) do
    a = :erlang.list_to_existing_atom(chars)
    :erlang.list_to_atom(:erlang.atom_to_list(a) ++ ~c"_x")
  end

  # (b2) The lookup two calls up.
  def outer(params), do: middle(String.to_existing_atom(params["f"]))
  defp middle(a), do: inner(a)
  defp inner(a) when is_atom(a), do: :"#{a}_inner"
end

defmodule Argus.Test.Soundness.Adv.Atoms.RoomLive do
  # (c) A request reaches the site; the atom came from the socket's
  # assigns (a lookup made at mount, kept in the process's state).
  @behaviour Phoenix.LiveView
  def mount(%{"room" => room}, _s, socket),
    do: {:ok, Map.put(socket, :room, String.to_existing_atom(room))}

  def handle_event("join", _p, socket),
    do: {:noreply, Map.put(socket, :topic, topic(socket.room))}

  defp topic(room) when is_atom(room), do: :"room_#{room}"
end

defmodule Argus.Test.Soundness.Adv.Atoms.Feedback do
  # (d) Mutual recursion: each name made of the last.
  def ping(a, n) when is_atom(a) and n > 0, do: pong(:"#{a}_ping", n - 1)
  def ping(a, _n), do: a
  defp pong(a, n), do: ping(a, n)

  # (e) A fold hands each answer back.
  def chain(base, depth) when is_atom(base),
    do: Enum.reduce(1..depth, base, fn _, acc -> String.to_atom(Atom.to_string(acc) <> ".c") end)

  # (f) Stream.iterate feeds its own atoms back.
  def names(base), do: Stream.iterate(base, fn a -> String.to_atom(Atom.to_string(a) <> "_n") end)

  # (f2) The fold's closure calls the maker.
  def deep(base, depth), do: Enum.reduce(1..depth, base, fn _, acc -> child(acc) end)
  def child(a) when is_atom(a), do: :"#{a}.child"
end

defmodule Argus.Test.Soundness.Adv.Atoms.Meet do
  # (g) One path an atom's name, the other a member of the caller's list.
  def name(x, allowed) do
    bin = if is_atom(x), do: Atom.to_string(x), else: if(x in allowed, do: x, else: "none")
    String.to_atom(bin)
  end

  def go(x), do: name(x, ["a", "b"])

  def decode(x, allowed) do
    bin = if is_atom(x), do: Atom.to_string(x), else: if(x in allowed, do: x, else: "none")
    :erlang.binary_to_term(bin)
  end

  def go2(x), do: decode(x, ["a", "b"])
end

defmodule Argus.Test.Soundness.Adv.Atoms.Products do
  # (h1) A range of 1,024 beside two more values: 2,048 atoms.
  def cell(x, y) when x in 0..1023 and y in 0..1, do: String.to_atom("cell_#{x}_#{y}")

  # (h2) Two ranges written as comparisons.
  def grid(x, y)
      when is_integer(x) and x >= 0 and x < 1000 and is_integer(y) and y >= 0 and y < 1000,
      do: :"grid_#{x}_#{y}"

  # (h3) Two branches of 600 each, joined: 1,200.
  def band(x) when is_integer(x) do
    v = if x < 0, do: pick(x in -600..-1, x), else: pick(x in 0..599, x)
    String.to_atom("band_#{v}")
  end

  defp pick(true, x), do: x
  defp pick(false, _), do: 0

  # (h4) A literal list and a range: 4 x 512.
  def slot(r, c) when r in ~w(a b c d) and c in 0..511, do: String.to_atom("slot_#{r}_#{c}")
end

defmodule Argus.Test.Soundness.Adv.Atoms.Quiet do
  # What the bound is for, kept quiet.
  def small(r, c) when r in ~w(a b) and c in 1..8, do: String.to_atom("s_#{r}_#{c}")
  def pooled(name, i) when is_atom(name) and i in 1..8, do: :"#{name}_#{i}"

  def sup_name(tab) when is_atom(tab),
    do: :erlang.list_to_atom(:erlang.atom_to_list(tab) ++ ~c"_sup")

  def arms(k) do
    s =
      case k do
        :a -> "a"
        :b -> "b"
        :c -> "c"
      end

    String.to_atom("k_" <> s)
  end
end

defmodule Argus.Test.Soundness.Adv.Atoms.Folds do
  # (e') A fold runs an exported maker with its last answer.
  def chain(base, depth), do: Enum.reduce(1..depth, base, &step/2)
  def step(_, acc) when is_atom(acc), do: :"#{acc}.c"

  # (f') Stream.iterate does.
  def names(base), do: Stream.iterate(base, &next/1)
  def next(a) when is_atom(a), do: String.to_atom(Atom.to_string(a) <> "_n")
end

defmodule Argus.Test.Soundness.Adv.Atoms.FoldQuiet do
  # The same maker called once: one atom per atom handed in.
  def once(base), do: tag(base)
  def tag(a) when is_atom(a), do: :"#{a}_tag"
end

defmodule Argus.Test.Soundness.Adv.Cookies.Controller do
  @behaviour Plug
  @compile {:no_warn_undefined, Plug.Conn}

  def init(opts), do: opts
  def call(conn, opts), do: phoenix_controller_pipeline(conn, opts)
  def phoenix_controller_pipeline(conn, opts), do: action(conn, opts)

  def action(%{private: %{phoenix_action: name}} = conn, _opts),
    do: apply(__MODULE__, name, [conn, conn.params])

  # (a) The raw value of the signed cookie: req_cookies holds what the
  # client sent under the verified name.
  def raw(conn, _params) do
    conn = Plug.Conn.fetch_cookies(conn, signed: ["session"])
    Argus.Test.Soundness.Adv.Cookies.Codec.load(conn.req_cookies["session"])
  end

  # (b) The verified name read off a conn other than the one returned.
  def stale(conn, _params) do
    _verified = Plug.Conn.fetch_cookies(conn, signed: ["session"])
    Argus.Test.Soundness.Adv.Cookies.Codec.load(conn.cookies["session"])
  end

  # (c) Options the request chose.
  def chosen(conn, params) do
    conn = Plug.Conn.fetch_cookies(conn, signed: [params["which"]])
    Argus.Test.Soundness.Adv.Cookies.Codec.load(conn.cookies["session"])
  end

  # (d) An unverified cookie through Map.get.
  def via_get(conn, _params) do
    conn = Plug.Conn.fetch_cookies(conn, encrypted: ["token"])
    Argus.Test.Soundness.Adv.Cookies.Codec.load(Map.get(conn.cookies, "prefs"))
  end

  # (e) An unverified cookie through a match.
  def via_match(conn, _params) do
    conn = Plug.Conn.fetch_cookies(conn, signed: ["session"])
    %{"prefs" => prefs} = conn.cookies
    Argus.Test.Soundness.Adv.Cookies.Codec.load(prefs)
  end

  # Quiet: the verified names, three ways.
  def q_get(conn, _params) do
    conn = Plug.Conn.fetch_cookies(conn, encrypted: ["token"])
    Argus.Test.Soundness.Adv.Cookies.Codec.load(Map.get(conn.cookies, "token"))
  end

  def q_match(conn, _params) do
    conn = Plug.Conn.fetch_cookies(conn, signed: ["session"])
    %{"session" => s} = conn.cookies
    Argus.Test.Soundness.Adv.Cookies.Codec.load(s)
  end

  def q_access(conn, _params) do
    conn = Plug.Conn.fetch_cookies(conn, signed: ["a"], encrypted: ["b"])

    {Argus.Test.Soundness.Adv.Cookies.Codec.load(conn.cookies["a"]),
     Argus.Test.Soundness.Adv.Cookies.Codec.load(conn.cookies["b"])}
  end
end

defmodule Argus.Test.Soundness.Adv.Cookies.Codec do
  def load(nil), do: nil
  def load(bytes), do: decode(bytes)
  defp decode(bin), do: :erlang.binary_to_term(bin)
end

defmodule Argus.Test.Soundness.Adv.Tpl.View do
  # A view with three templates, dispatched by name.
  def render(template, assigns), do: render_template(template, assigns)
  def render_template("run.json", assigns), do: __MODULE__."run.json"(assigns)
  def render_template("list.json", assigns), do: __MODULE__."list.json"(assigns)
  def render_template("tags.html", assigns), do: __MODULE__."tags.html"(assigns)

  def unquote(:"run.json")(assigns) do
    {value, _} = Code.eval_string(assigns.expr)
    value
  end

  def unquote(:"list.json")(assigns), do: assigns.items

  def unquote(:"tags.html")(assigns), do: for(t <- assigns.tags, do: String.to_atom("tag_" <> t))
end

defmodule Argus.Test.Soundness.Adv.Tpl.Controller do
  @behaviour Plug
  alias Argus.Test.Soundness.Adv.Tpl.View

  def init(opts), do: opts
  def call(conn, opts), do: phoenix_controller_pipeline(conn, opts)
  def phoenix_controller_pipeline(conn, opts), do: action(conn, opts)

  def action(%{private: %{phoenix_action: name}} = conn, _opts),
    do: apply(__MODULE__, name, [conn, conn.params])

  # (a) The request's own param, into the template the name picks.
  def run(conn, params), do: {conn, View.render("run.json", %{expr: params["expr"]})}

  # (b) The name handed down by a helper.
  def tags(conn, params),
    do: {conn, render_view(conn, "tags.html", %{tags: String.split(params["t"], ",")})}

  defp render_view(_conn, name, assigns), do: View.render(name, assigns)

  # (c) A template function called directly.
  def direct(conn, params), do: {conn, View."run.json"(%{expr: params["e"]})}

  # Quiet: another template's render hands the dispatch the params; they
  # do not reach run.json or tags.html.
  def list(conn, params),
    do:
      {conn,
       View.render("list.json", %{items: params["i"], expr: params["x"], tags: params["y"]})}
end

defmodule Argus.Test.Soundness.Adv.Stream.Sup do
  use Supervisor
  def start_link(o), do: Supervisor.start_link(__MODULE__, o, name: __MODULE__)
  @impl true
  def init(_),
    do:
      Supervisor.init([{Task.Supervisor, name: Argus.Test.Soundness.Adv.Stream.TaskSup}],
        strategy: :one_for_one
      )
end

defmodule Argus.Test.Soundness.Adv.Stream.Background do
  def run(fun), do: Task.start(fun)
end

defmodule Argus.Test.Soundness.Adv.Stream.Live do
  @behaviour Phoenix.LiveView
  def mount(_p, _s, socket), do: {:ok, socket}

  # (a) A bare spawn runs the fan-out.
  def handle_event("a", %{"ids" => ids}, socket) do
    spawn(fn -> fan_a(ids) end)
    {:noreply, socket}
  end

  # (c) A helper starts the process on the fun it is handed.
  def handle_event("c", %{"ids" => ids}, socket) do
    Argus.Test.Soundness.Adv.Stream.Background.run(fn -> fan_c(ids) end)
    {:noreply, socket}
  end

  # (d) The stream is built here and run in a task.
  def handle_event("d", %{"ids" => ids}, socket) do
    stream =
      Task.Supervisor.async_stream_nolink(Argus.Test.Soundness.Adv.Stream.TaskSup, ids, &work/1)

    Task.start(fn -> Stream.run(stream) end)
    {:noreply, socket}
  end

  # Quiet: the request enumerates the stream through a helper.
  def handle_event("q", %{"ids" => ids}, socket) do
    {:noreply, Map.put(socket, :r, check(ids))}
  end

  def render(a), do: a

  defp fan_a(ids),
    do:
      Argus.Test.Soundness.Adv.Stream.TaskSup
      |> Task.Supervisor.async_stream_nolink(ids, &work/1)
      |> Stream.run()

  defp fan_c(ids),
    do:
      Argus.Test.Soundness.Adv.Stream.TaskSup
      |> Task.Supervisor.async_stream(ids, &work/1)
      |> Stream.run()

  defp check(ids),
    do:
      Argus.Test.Soundness.Adv.Stream.TaskSup
      |> Task.Supervisor.async_stream_nolink(ids, &work/1)
      |> Enum.to_list()

  defp work(id), do: Process.sleep(id)
end

defmodule Argus.Test.Soundness.Adv.Stream.Controller do
  # (b) A controller starts a supervised task that runs the fan-out.
  @behaviour Plug
  def init(o), do: o
  def call(conn, opts), do: phoenix_controller_pipeline(conn, opts)
  def phoenix_controller_pipeline(conn, opts), do: action(conn, opts)

  def action(%{private: %{phoenix_action: name}} = conn, _opts),
    do: apply(__MODULE__, name, [conn, conn.params])

  def sync(conn, %{"ids" => ids}) do
    Task.Supervisor.start_child(Argus.Test.Soundness.Adv.Stream.TaskSup, fn -> fan_b(ids) end)
    conn
  end

  defp fan_b(ids),
    do:
      Argus.Test.Soundness.Adv.Stream.TaskSup
      |> Task.Supervisor.async_stream_nolink(ids, &work/1)
      |> Stream.run()

  defp work(id), do: Process.sleep(id)
end

defmodule Argus.Test.Soundness.Adv.Found.Wrappers do
  # Programs PATH finds that run their arguments.
  def via_sudo(cmd), do: System.cmd(System.find_executable("sudo"), ["-n", cmd])
  def via_xargs(cmd, input), do: System.cmd(System.find_executable("xargs"), [cmd], input: input)
  def via_timeout(cmd), do: System.cmd(System.find_executable("timeout"), ["5", cmd])
  def via_lua(code), do: System.cmd(System.find_executable("lua"), ["-e", code])
  def via_awk(prog, file), do: System.cmd(System.find_executable("awk"), [prog, file])
  # The same, named literally.
  def literal_env(cmd), do: System.cmd("env", [cmd])
  # A search path the caller picks, without a conversion.
  def search(dir, file),
    do: System.cmd(:os.find_executable(~c"ffprobe", dir) |> to_string(), [file])
end

defmodule Argus.Test.Soundness.Adv.Found.Quiet do
  # akkoma's ffprobe: a program that runs none of its arguments.
  def dims(file) do
    ffprobe = System.find_executable("ffprobe")
    System.cmd(ffprobe, ["-v", "error", "-show_entries", "stream=width,height", file])
  end

  def literal(file), do: System.cmd("ffprobe", ["-v", "error", file])
end

defmodule Argus.Test.Soundness.Adv.Dunder do
  def __eval__(code), do: Code.eval_string(code)
end

defmodule :acceptor do
  # Minimal stand-in for the acceptor_pool framework's `acceptor` behaviour, so
  # the fixture below can declare `@behaviour :acceptor` and be recognised as
  # an acceptor-pool handler without depending on the acceptor_pool package.
  # The beam records the behaviour name as `:acceptor`, the same name the
  # request-entry rule matches.
  @callback acceptor_init(term(), term(), term()) :: term()
  @callback acceptor_continue(term(), term(), term()) :: term()
  @callback acceptor_terminate(term(), term()) :: term()
end

defmodule Argus.Test.Soundness.G6.AcceptorTerm do
  # The acceptor_pool shape: a module implementing the `acceptor` behaviour
  # takes over a socket the pool accepted and, via gen_server:enter_loop,
  # receives the peer's bytes in handle_info/2. It never opens the socket
  # itself, so socket_active never names it; only the behaviour marks it as a
  # socket-data entry. A helper binary_to_term/1 (no [:safe]) decodes the
  # frame, so an unauthenticated peer's bytes reach the deserializer. This is
  # the partisan_peer_service_server shape.
  use GenServer
  @behaviour :acceptor

  def start_link(_), do: GenServer.start_link(__MODULE__, [])
  def init(_), do: {:ok, %{}}

  def acceptor_init(_sockname, _lsocket, _args), do: {:ok, nil}
  def acceptor_continue(_peername, _socket, _state), do: {:ok, %{}}
  def acceptor_terminate(reason, _state), do: exit(reason)

  def handle_info({:tcp, _socket, data}, s) do
    msg = :erlang.binary_to_term(data)
    {:noreply, Map.put(s, :last, msg)}
  end

  def handle_info({:tcp_closed, _socket}, s), do: {:stop, :normal, s}
end

# A decode reached only when a cryptographic verification the function performs
# succeeds is re-ranked below an ungated decode (secret_gated_decode), never
# dropped (Argus.Extractors.VerificationGate). The gated clauses step down to a
# warning; the ungated and the counterexamples (a decode on the reject branch, a
# MAC that does not gate the decode) keep the top-tier error.
defmodule Argus.Test.Soundness.G10.SignatureGate do
  @moduledoc false

  # secure_compare of a hand-rolled HMAC gates the decode: re-ranked (warning).
  def decode_gated(payload, secret) do
    case String.split(payload, "--", parts: 2) do
      [data, digest] ->
        expected = :crypto.mac(:hmac, :sha256, secret, data) |> Base.url_encode64()

        if Plug.Crypto.secure_compare(digest, expected) do
          {:ok, :erlang.binary_to_term(Base.url_decode64!(data))}
        else
          {:error, :bad_signature}
        end

      _ ->
        {:error, :bad_format}
    end
  end

  # An asymmetric signature verify gates the decode: re-ranked (warning).
  def decode_verify(payload, sig, key) do
    if :crypto.verify(:rsa, :sha256, payload, sig, key) do
      :erlang.binary_to_term(payload)
    else
      {:error, :bad_sig}
    end
  end

  # A MAC compared for equality gates the decode: re-ranked (warning).
  def decode_eq(data, provided, secret) do
    if :crypto.mac(:hmac, :sha256, secret, data) == provided do
      :erlang.binary_to_term(data)
    else
      {:error, :bad_mac}
    end
  end

  # No gate at all: the ungated decode keeps the top-tier error.
  def decode_open(payload), do: :erlang.binary_to_term(payload)

  # A gated decode of the module's own attribute is constant input, as its
  # ungated twin is: no finding.
  @payload :erlang.term_to_binary(%{version: 1})
  @sig "signature"
  def decode_constant(key) do
    if :crypto.verify(:eddsa, :none, @payload, @sig, [key, :ed25519]) do
      :erlang.binary_to_term(@payload)
    else
      {:error, :bad_sig}
    end
  end

  # A checksum the sender computes is no gate: it keeps the error.
  def decode_checksum(data, sum) do
    if :crypto.hash_equals(:crypto.hash(:sha256, data), Base.decode16!(sum)) do
      :erlang.binary_to_term(data)
    else
      {:error, :bad_sum}
    end
  end

  # A token compared before decoding another value is no gate: it keeps the error.
  def decode_after_token(token, expected, blob) do
    if Plug.Crypto.secure_compare(token, expected) do
      :erlang.binary_to_term(blob)
    else
      {:error, :bad_token}
    end
  end

  # The decode is on the REJECT branch: it must not be re-ranked (error).
  def decode_reject(payload, secret) do
    case String.split(payload, "--", parts: 2) do
      [data, digest] ->
        expected = :crypto.mac(:hmac, :sha256, secret, data) |> Base.url_encode64()

        if Plug.Crypto.secure_compare(digest, expected) do
          {:error, :bad}
        else
          :erlang.binary_to_term(Base.url_decode64!(data))
        end

      _ ->
        {:error, :bad_format}
    end
  end

  # A MAC is computed but does not gate the decode: it must not be re-ranked (error).
  def decode_ungated_mac(payload, secret) do
    _mac = :crypto.mac(:hmac, :sha256, secret, payload)
    :erlang.binary_to_term(payload)
  end
end
