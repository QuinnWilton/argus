defmodule Argus.Schema.CodeInjection do
  @moduledoc "Runtime callback origins and call conditions for template compilation."

  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :call_arg_runtime,
        layer: 2,
        fields: [
          {:id, :symbol, "receiving call instruction"},
          {:func, :symbol, "receiving call's function"},
          {:pos, :number, "argument position"},
          {:source, :symbol, "unresolved callback invocation producing the content"},
          {:source_func, :symbol, "function containing that callback invocation"}
        ],
        doc: """
        An argument contains data returned by an unresolved fun invocation. Uses \
        ParamFlow's structural and actual helper-return propagation, independently \
        of parameter taint. A runtime origin does not prove attacker control. Known \
        closures returning constants and unknown ordinary external APIs add none.
        """
      },
      %{
        name: :code_template_site,
        layer: 2,
        fields: [
          {:id, :symbol, "template compiler instruction"},
          {:func, :symbol, "owning function"},
          {:api, :symbol, "template compiler API"}
        ],
        doc: "A string template is compiled or evaluated from argument zero."
      },
      %{
        name: :code_call,
        layer: 2,
        fields: [
          {:id, :symbol, "call instruction"},
          {:func, :symbol, "calling function"},
          {:callee, :symbol, "statically known same-module target or template compiler"}
        ],
        doc: "Calls in a module containing a template compiler, retaining invocation identity."
      },
      %{
        name: :code_arg_identity,
        layer: 2,
        fields: [
          {:id, :symbol, "call instruction"},
          {:func, :symbol, "calling function"},
          {:pos, :number, "argument position"},
          {:kind, :symbol, "param, literal, or unknown"},
          {:value, :symbol, "parameter index or Terms.spell literal"}
        ],
        doc: "Exact argument identity on every reaching path; a derived value is unknown here."
      },
      %{
        name: :code_site_gate,
        layer: 2,
        fields: [
          {:id, :symbol, "call instruction"},
          {:func, :symbol, "owning function"},
          {:param, :number, "parameter required equal to literal, or -1"},
          {:value, :symbol, "required Terms.spell literal, or empty"}
        ],
        doc: """
        One deterministic necessary literal condition on a function parameter for \
        reaching this call. The accepting edge covers all paths to this operation. \
        -1 means no such proof. When several conditions hold, retaining one weakens \
        precision; it never proves an additional exclusion.
        """
      }
    ])
  end
end
