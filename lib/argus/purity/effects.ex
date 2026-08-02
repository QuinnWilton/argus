defmodule Argus.Purity.Effects do
  @moduledoc """
  The effect model: which calls are observable effects, and which are known
  to be free of them.

  A purity claim is a claim about every execution, so the analysis cannot
  simply assume that a call it knows nothing about is harmless. Every real
  purity checker ships an effect model of its standard library — Haskell
  encodes it in types, effect-typed languages in rows; on the BEAM it has to
  be a table, because the runtime offers no way to ask.

  So calls land in one of three buckets:

  - **impure** — a known observable effect. Names the category, so the
    report can say *what* the effect is rather than just that there is one.
  - **pure** — known to compute a value and nothing else.
  - **unknown** — neither. The analysis reports these as *unprovable*
    rather than guessing, which is the difference between a verification
    and an opinion.

  That third bucket is the honest part. Assuming unknown calls are pure
  would make the checker report success far more often and mean nothing;
  assuming they are impure would flag every real program. Saying "I cannot
  see past this" is the only answer that keeps a "verified" worth having.

  ## Scope

  Effects here are *observable*: something outside the function can tell
  they happened. Allocation, arithmetic, matching and exceptions are not
  effects — a function that raises still computes a value or fails and
  leaves nothing behind.
  """

  use Argus.Purity

  # ── Impure: observable effects, by category ──────────────────────
  #
  # Module-level entries cover the whole module; {module, function} entries
  # pick out the impure part of an otherwise-pure one.

  @impure_modules %{
    "IO" => :io,
    ":io" => :io,
    ":io_lib" => :io,
    "File" => :io,
    ":file" => :io,
    ":filelib" => :io,
    "Logger" => :io,
    ":logger" => :io,
    "Port" => :port,
    ":os" => :port,
    "System" => :port,
    ":ets" => :ets,
    ":dets" => :ets,
    ":mnesia" => :ets,
    ":persistent_term" => :ets,
    "Agent" => :process,
    "GenServer" => :process,
    "Task" => :process,
    "Supervisor" => :process,
    "DynamicSupervisor" => :process,
    "Process" => :process,
    "Registry" => :process,
    ":gen_server" => :process,
    ":gen_statem" => :process,
    ":proc_lib" => :process,
    ":timer" => :process,
    ":global" => :node,
    ":rpc" => :node,
    ":net_kernel" => :node,
    ":net_adm" => :node,
    ":erpc" => :node,
    ":rand" => :random,
    ":random" => :random,
    ":crypto" => :random,
    ":httpc" => :network,
    ":gen_tcp" => :network,
    ":gen_udp" => :network,
    ":ssl" => :network,
    ":inet" => :network,
    ":code" => :code_loading,
    "Code" => :code_loading,
    ":application" => :process,
    "Application" => :process,
    ":ct" => :io,
    ":dbg" => :io
  }

  # Individually impure functions in modules that are otherwise fine.
  @impure_functions %{
    # Message passing and process control are BIFs on :erlang.
    {":erlang", "send"} => :process,
    {":erlang", "send_after"} => :process,
    {":erlang", "spawn"} => :process,
    {":erlang", "spawn_link"} => :process,
    {":erlang", "spawn_monitor"} => :process,
    {":erlang", "spawn_opt"} => :process,
    {":erlang", "link"} => :process,
    {":erlang", "unlink"} => :process,
    {":erlang", "monitor"} => :process,
    {":erlang", "demonitor"} => :process,
    {":erlang", "exit"} => :process,
    {":erlang", "register"} => :process,
    {":erlang", "unregister"} => :process,
    {":erlang", "whereis"} => :process,
    {":erlang", "process_flag"} => :process,
    {":erlang", "group_leader"} => :process,
    {":erlang", "halt"} => :process,
    {":erlang", "garbage_collect"} => :process,
    {":erlang", "suspend_process"} => :process,
    {":erlang", "resume_process"} => :process,

    # The process dictionary is mutable per-process state.
    {":erlang", "put"} => :process_dict,
    {":erlang", "get"} => :process_dict,
    {":erlang", "erase"} => :process_dict,
    {":erlang", "get_keys"} => :process_dict,

    # Reading a clock or a counter makes the result depend on when it ran.
    {":erlang", "now"} => :time,
    {":erlang", "time"} => :time,
    {":erlang", "date"} => :time,
    {":erlang", "localtime"} => :time,
    {":erlang", "universaltime"} => :time,
    {":erlang", "monotonic_time"} => :time,
    {":erlang", "system_time"} => :time,
    {":erlang", "timestamp"} => :time,
    {":erlang", "unique_integer"} => :time,
    {":erlang", "make_ref"} => :time,
    {"DateTime", "utc_now"} => :time,
    {"NaiveDateTime", "utc_now"} => :time,
    {"Date", "utc_today"} => :time,
    {"Time", "utc_now"} => :time,

    # Ports and the outside world.
    {":erlang", "open_port"} => :port,
    {":erlang", "port_command"} => :port,
    {":erlang", "port_close"} => :port,

    # Node-visible state.
    {":erlang", "nodes"} => :node,
    {":erlang", "node"} => :node,
    {":erlang", "disconnect_node"} => :node,
    {":erlang", "spawn_request"} => :process,

    # Path is overwhelmingly string manipulation — join, dirname, extname,
    # basename, split, type — and listing the whole module as I/O flagged
    # Path.join/2 as a filesystem effect, which it is not. Only the handful
    # that consult the actual filesystem or the current directory belong
    # here.
    {"Path", "wildcard"} => :io,
    {"Path", "expand"} => :io,
    {"Path", "absname"} => :io,
    {"Path", "safe_relative_to"} => :io,
    {"Path", "relative_to_cwd"} => :io,

    # Kernel's process and dispatch surface. These survive compilation as
    # real remote calls when captured or called dynamically.
    {"Kernel", "send"} => :process,
    {"Kernel", "spawn"} => :process,
    {"Kernel", "spawn_link"} => :process,
    {"Kernel", "spawn_monitor"} => :process,
    {"Kernel", "exit"} => :process,
    {"Kernel", "self"} => :process,
    {"Kernel", "make_ref"} => :time,
    {"Kernel", "node"} => :node
  }

  # ── Open dispatch: the target is not knowable ────────────────────
  #
  # A protocol call resolves to whichever implementation the argument's type
  # provides, and any module can add one. `to_string/1` on a struct runs
  # that struct's String.Chars implementation, which is ordinary user code
  # and can do anything.
  #
  # This is not a hole in the table — no table could close it. It is a
  # different verdict from "unknown": there IS no single answer to look up,
  # so the report should say the dispatch is open rather than implying
  # somebody forgot an entry.

  # Elixir compiles `x.field` — dot access without parentheses — to this
  # helper whenever it cannot prove `x` is a map. At runtime it either reads
  # a map field or, if `x` turns out to be an atom, calls `x.field()` as a
  # remote function. That second branch is a dynamic dispatch hiding behind
  # ordinary-looking syntax, so a function using `x.field` on an untyped
  # value is not statically pure. Using `Map.fetch!/2` instead is both
  # provable and, on a plain map, clearer about intent.
  @dynamic_dispatch_functions [{":elixir_erl_pass", "no_parens_remote"}]

  # `Kernel` is NOT listed pure, and the reason is worth recording because
  # listing it was a real soundness hole found by running this analysis over
  # argus itself. Most of Kernel inlines to BIFs and never appears as a
  # remote call, so the entries that DO survive compilation are exactly the
  # ones that dispatch: inspect/1 and to_string/1 go through a protocol,
  # which is user-extensible code. Kernel also exports send/2, spawn/1,
  # exit/1, apply/3 and self/0.
  #
  # Treating the module as pure meant a function calling inspect/1 could be
  # reported VERIFIED while transitively running arbitrary user code — the
  # precise failure this analysis exists to prevent. Anything in Kernel not
  # named below is now unknown, and therefore unprovable rather than assumed.
  @protocol_functions [
    {"Kernel", "inspect"},
    {"Kernel", "to_string"}
  ]

  @protocol_modules ~w(
    String.Chars List.Chars Inspect Enumerable Collectable
    Jason.Encoder Phoenix.HTML.Safe Ecto.Type
  )

  # ── Pure: known to compute a value and nothing else ──────────────
  #
  # Deliberately conservative. A module is only listed when every exported
  # function is free of observable effects; anything with a `*_!` file
  # variant, a clock read, or a process interaction is left off, and
  # therefore reported as unprovable rather than quietly assumed.

  @pure_modules ~w(
    Enum Map MapSet List Keyword Tuple Range Stream
    String Integer Float Atom Bitwise Base
    Regex URI Version Path
    Exception ArgumentError RuntimeError
    Jason.Encoder
    :lists :maps :sets :ordsets :orddict :dict :gb_trees :gb_sets
    :string :binary :unicode :re :array :queue :proplists :math
    :erl_anno :beam_lib
  )

  # `:erlang` is mostly arithmetic, comparison, and type tests — all pure —
  # with a well-defined impure minority listed above. Treating the module as
  # pure-by-default and subtracting the effects is far more accurate than
  # the reverse, which would make every arithmetic BIF unprovable.
  @pure_by_default_modules ~w(:erlang)

  @type category ::
          :io
          | :process
          | :process_dict
          | :ets
          | :port
          | :node
          | :time
          | :random
          | :network
          | :code_loading

  @type verdict ::
          {:impure, category()} | :pure | {:opaque, :protocol | :dot_dispatch} | :unknown

  @doc """
  Classify a remote call.

      iex> Argus.Purity.Effects.classify("IO", "puts")
      {:impure, :io}

      iex> Argus.Purity.Effects.classify(":erlang", "+")
      :pure

      iex> Argus.Purity.Effects.classify(":erlang", "put")
      {:impure, :process_dict}

      iex> Argus.Purity.Effects.classify("String.Chars", "to_string")
      {:opaque, :protocol}

      iex> Argus.Purity.Effects.classify("MyApp.Repo", "all")
      :unknown
  """
  @spec classify(String.t(), String.t()) :: verdict()
  @pure true
  def classify(module, function) when is_binary(module) and is_binary(function) do
    cond do
      category = Map.get(@impure_functions, {module, function}) -> {:impure, category}
      category = Map.get(@impure_modules, module) -> {:impure, category}
      {module, function} in @dynamic_dispatch_functions -> {:opaque, :dot_dispatch}
      {module, function} in @protocol_functions -> {:opaque, :protocol}
      module in @protocol_modules -> {:opaque, :protocol}
      module in @pure_modules -> :pure
      module in @pure_by_default_modules -> :pure
      true -> :unknown
    end
  end

  @doc "Every impure category, for exhaustiveness checks and reporting."
  @spec categories() :: [category()]
  @pure true
  def categories do
    (Map.values(@impure_modules) ++ Map.values(@impure_functions))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Modules whose calls dispatch to an open set of implementations."
  @spec protocol_modules() :: [String.t()]
  @pure true
  def protocol_modules, do: @protocol_modules

  @doc "Modules treated as free of observable effects."
  @spec pure_modules() :: [String.t()]
  @pure true
  def pure_modules, do: @pure_modules ++ @pure_by_default_modules
end
