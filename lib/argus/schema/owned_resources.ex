defmodule Argus.Schema.OwnedResources do
  @moduledoc """
  The resources a process owns and loses with it: ETS tables, their
  options and the operations on them, and ports.

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
      }
    ])
  end
end
