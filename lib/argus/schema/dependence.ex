defmodule Argus.Schema.Dependence do
  @moduledoc """
  Layer-2 data and control dependencies for calls, shared-state operations, and returns \
  (`Argus.Extractors.Dependence`). Exposed through `Argus.Schema`.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :site_depends,
        layer: 2,
        fields: [
          {:site, :instr_id,
           "a shared-state operation: a name lookup, claim or release, an ETS or dirty Mnesia op"},
          {:func, :func_id, "the function containing it"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol,
           "the parameter's position, the callee's function ID, or the shared-state operation's instruction ID"}
        ],
        doc: """
        An operation controlled by a test on the source or receiving data derived from \
        it. A site source is another shared-state operation's result, such as the check \
        in a check-then-act sequence.
        """
      },
      %{
        name: :call_decided,
        layer: 2,
        fields: [
          {:caller, :func_id, "the calling function"},
          {:callee, :func_id, "the callee, or a closure the caller builds"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"}
        ],
        doc: """
        A call controlled by a test on the source. Closure construction counts as a \
        call. Function-level.
        """
      },
      %{
        name: :call_arg_depends,
        layer: 2,
        fields: [
          {:caller, :func_id, "the calling function"},
          {:callee, :func_id, "the callee, or a closure the caller builds"},
          {:arg_pos, :number,
           "0-based argument position, or the closure's environment parameter"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"}
        ],
        doc: """
        A call argument dependent on the source through data or control flow. Unlike \
        `call_arg_derived`, includes control dependence and call-result sources. \
        Function-level.
        """
      },
      %{
        name: :returns_depends,
        layer: 2,
        fields: [
          {:func, :func_id, "the function"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"}
        ],
        doc: """
        A return value dependent on the source, such as a parameter or call result.
        """
      },
      %{
        name: :returns_reads,
        layer: 2,
        fields: [
          {:func, :func_id, "the function"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"}
        ],
        doc: """
        The data-only subset of `returns_depends`: the return contains data from the \
        source. Returning a status selected by a test on the source does not qualify.
        """
      },
      %{
        name: :site_reads,
        layer: 2,
        fields: [
          {:site, :instr_id, "a shared-state operation, as site_depends"},
          {:func, :func_id, "the function containing it"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"}
        ],
        doc: """
        The data-only subset of `site_depends`: operation arguments contain data from \
        the source. Running an operation because of a test on the source does not \
        qualify.
        """
      },
      %{
        name: :sink_reads,
        layer: 2,
        fields: [
          {:site, :instr_id, "a sink call: atom creation, deserialization or code execution"},
          {:func, :func_id, "the function containing it"},
          {:arg_pos, :number, "0-based argument position"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"}
        ],
        doc: """
        A sink argument's data sources (`Argus.Extractors.Dependence`). Follows data \
        through runtime calls beyond the propagators recognized by `sink_arg_derived`, \
        such as `Macro.underscore/1` before atom creation.
        """
      },
      %{
        name: :call_arg_reads,
        layer: 2,
        fields: [
          {:caller, :func_id, "the calling function"},
          {:callee, :func_id, "the callee"},
          {:arg_pos, :number, "0-based argument position"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"}
        ],
        doc: """
        The data-only subset of `call_arg_depends`, for calls but not closures. \
        Function-level.
        """
      },
      %{
        name: :field_decides,
        layer: 2,
        fields: [
          {:func, :func_id, "the function"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"},
          {:pos, :number,
           "the tuple element tested, from 0: an ETS row's key is 0, a Mnesia record's 1"}
        ],
        doc: """
        A test on tuple element `pos` of the source, or data derived from that element. \
        Shape-only tests do not count. Key comparisons use the key position; \
        `:ets.lookup_element/3` results use position 1. Function-level.
        """
      },
      %{
        name: :field_compared,
        layer: 2,
        fields: [
          {:func, :func_id, "the function"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"},
          {:pos, :number, "the tuple element tested, as field_decides"},
          {:other_kind, :symbol, "param | call | site"},
          {:other_source, :symbol, "as site_depends"}
        ],
        doc: """
        A comparison between tuple element `pos` of one source and data derived from \
        another. Comparisons with untracked values have no row. Function-level.
        """
      },
      %{
        name: :effect_decided,
        layer: 2,
        fields: [
          {:func, :func_id, "the function"},
          {:kind, :symbol, "param | call | site"},
          {:source, :symbol, "as site_depends"}
        ],
        doc: """
        A send or external runtime effect controlled by a test on the source. Includes \
        process, port, file, network, and node effects classified by \
        `Argus.Purity.Effects`; excludes logging. Project calls use `call_decided`. \
        Function-level.
        """
      }
    ])
  end
end
