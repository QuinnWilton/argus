defmodule Argus.Schema.OwnedResources do
  @moduledoc """
  Layer-2 facts for process-owned resources: ETS tables and operations, ports, and \
  controlled sockets. Exposed through `Argus.Schema`.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
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
        name: :ets_options_known,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID (same as ets_new)"}
        ],
        doc: """
        An `:ets.new/2` whose complete options list is known. Only then does a missing \
        `ets_option` row prove an option absent. Partial or runtime lists have no row \
        here; an unreadable `keypos` is `dynamic`, never the default.
        """
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
        name: :ets_read_when_present,
        layer: 2,
        fields: [
          {:read, :symbol, "the read (an ets_op of kind read)"},
          {:witness, :symbol,
           "the first :ets.whereis/1 of the same named table in the function, or else the first instruction that makes it"}
        ],
        doc: """
        An ETS read reached only after confirming the table exists or creating it, \
        directly or through a same-module ensure helper. Every path must establish \
        presence; reads on an unchecked or still-absent path have no row.
        """
      },
      %{
        name: :ets_made_when_absent,
        layer: 2,
        fields: [
          {:func, :symbol, "the function that makes the table"},
          {:name, :symbol, "the named table's atom"},
          {:witness, :symbol,
           "the first :ets.whereis/1 or :ets.info/1,2 of the table in the function"}
        ],
        doc: """
        Every creation of a named table in the function follows a lookup of that same \
        table returning `:undefined`. Includes same-module creation helpers. A creation \
        reachable without the absence check removes the row.
        """
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
        A file, socket, or port handle dropped on some non-raising path without being \
        closed or transferred. Reading, writing, sending data, or testing the handle \
        does not transfer ownership. Error-result paths that never extract a handle are \
        excluded. The resource remains owned until the process exits \
        (`Argus.Extractors.Handles`).
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
        A socket open or options call and its literal `:active` mode. Active sockets \
        deliver data and close messages to their controlling process. Runtime-built \
        options use `dynamic`.
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
        A literal options argument containing `:active`, used to resolve a wrapper's \
        `socket_active` mode `param`.
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
        A blocking socket receive, connect, or TLS handshake and its timeout. \
        `:gen_tcp.connect/3` relies on the operating system's connect timeout.
        """
      }
    ])
  end
end
