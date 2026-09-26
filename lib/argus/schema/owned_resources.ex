defmodule Argus.Schema.OwnedResources do
  @moduledoc """
  The resources a process owns and loses with it: ETS tables, their
  options and the operations on them, ports, and the sockets it
  controls.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Cache.Reads.record("relations #{__MODULE__}", [
      %{
        name: :ets_new,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID of the :ets.new/2 call"},
          {:func, :symbol, "containing function ID"},
          {:name, :symbol, "table name atom (or \"dynamic\")"}
        ],
        doc: "ETS table creation point."
      },
      %{
        name: :ets_option,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID (same as ets_new)"},
          {:key, :symbol, "option category"},
          {:value, :symbol, "option value as string"}
        ],
        doc: "Parsed option from :ets.new/2."
      },
      %{
        name: :ets_op_param,
        layer: 2,
        fields: [
          {:id, :symbol, "the ETS operation"},
          {:pos, :number, "0-based parameter of the enclosing function that is the table"}
        ],
        doc: "The table operand of an ETS operation is the function's own parameter."
      },
      %{
        name: :ets_op,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:func, :symbol, "containing function ID"},
          {:table_ref, :symbol, "table name atom (or \"dynamic\")"},
          {:op, :symbol, "ETS function name"},
          {:kind, :symbol, "read, write, or delete"}
        ],
        doc: "ETS read/write/delete operation."
      },
      %{
        name: :port_open,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID of the port-opening call"},
          {:func, :symbol, "containing function ID"},
          {:mechanism, :symbol,
           ~s(how the port is opened: "Port.open", "erlang.open_port", "System.cmd", "System.shell", or "os.cmd")},
          {:target, :symbol, "the spawned command / executable / driver, or \"dynamic\""}
        ],
        doc:
          "Port creation point. A port is owned by the opening process and dies " <>
            "when it terminates — so, like an ETS table, it attributes to that " <>
            "process in the supervision tree."
      },
      %{
        name: :handle_dropped,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID of the call that opens the handle"},
          {:func, :symbol, "containing function ID"},
          {:api, :symbol, "the opening call, as `:file.open/2` spells it"},
          {:drop, :symbol, "the first instruction at which some path drops the handle"}
        ],
        doc: """
        The file, socket or port the call at `id` opens is dropped on some \
        path from it: no register holds it any more, or the function \
        returns or tail-calls without it, and on the way it was only read, \
        written, sent on or tested (Argus.Extractors.Handles) — not closed, \
        returned, stored, sent or handed to any other call. A path on which \
        the `{:ok, handle}` answer was never taken apart (its `{:error, _}` \
        arm) owns no handle, and a path that raises drops nothing. The \
        process that opened it owns it until it exits.
        """
      },
      %{
        name: :socket_active,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID of the connect or setopts call"},
          {:func, :symbol, "containing function ID"},
          {:transport, :symbol,
           ~s(the socket's messages: "tcp", "ssl", "inet" (:inet.setopts/2, a TCP or UDP socket\) or "any" (a setopts/2 through a module in a variable\))},
          {:mode, :symbol,
           ~s(the literal :active value: "true" | "once" | "n" | "false"; "default" for a connect whose literal options leave it out, "unset" for such a setopts, "param" or "dynamic")},
          {:param, :number, "the 0-based parameter the options come from, for \"param\"; else -1"}
        ],
        doc: """
        A call that opens a TCP or TLS socket or sets its options, and the \
        `:active` mode its literal options give. An active socket delivers its \
        data and its close (`{:tcp_closed, s}`, `{:ssl_closed, s}`) as messages \
        to the process that controls it. Options built at runtime are "dynamic".
        """
      },
      %{
        name: :socket_opts_arg,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID of the call"},
          {:caller, :symbol, "calling function ID"},
          {:callee, :symbol, "callee function ID (mod:func/arity)"},
          {:pos, :number, "0-based argument position"},
          {:mode, :symbol, "the :active value: true | once | n | false"}
        ],
        doc: """
        A call handing a literal option list with an `:active` entry: what a \
        wrapper's `socket_active` row whose mode is "param" resolves to.
        """
      },
      %{
        name: :socket_wait,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID of the call"},
          {:func, :symbol, "containing function ID"},
          {:api, :symbol, "the call, spelled :gen_tcp.recv/2"},
          {:timeout, :symbol,
           ~s("infinity" (the arity leaves it out, or :infinity is passed\), "bounded", "param" or "dynamic")},
          {:param, :number,
           "the 0-based parameter the timeout comes from, for \"param\"; else -1"}
        ],
        doc: """
        A blocking socket call — a recv, a connect, a TLS handshake — and how \
        long it may wait. `:gen_tcp.connect/3` is bounded only by the operating \
        system's connect timeout.
        """
      }
    ])
  end
end
