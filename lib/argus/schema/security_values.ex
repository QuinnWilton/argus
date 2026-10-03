defmodule Argus.Schema.SecurityValues do
  @moduledoc "Call-site value identities and operation-specific security proofs."

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :security_arg_value,
        layer: 2,
        fields: [
          {:id, :symbol, "call instruction ID"},
          {:func, :symbol, "calling function ID"},
          {:pos, :number, "zero-based argument position"},
          {:value, :symbol, "exact value identity within this function"}
        ],
        doc: """
        A call argument with one identity on every reaching path. Copies retain the \
        identity; different values at a join and unsupported projections have none. \
        Identities name values, not attacker control or a safety property.
        """
      },
      %{
        name: :security_value_origin,
        layer: 2,
        fields: [
          {:value, :symbol, "exact value identity"},
          {:func, :symbol, "owning function ID"},
          {:kind, :symbol, "param, call, literal, or local"},
          {:source, :symbol,
           "parameter index, call site, spelled literal, or write site/register"}
        ],
        doc: """
        An identity's root. A call root names its instruction, so two invocations of \
        the same API remain distinct. Local roots describe supported single writes \
        but make no claim about their contents. Literals use Helpers.spell/1.
        """
      },
      %{
        name: :security_value_field,
        layer: 2,
        fields: [
          {:value, :symbol, "projected value identity"},
          {:parent, :symbol, "identity of the containing value"},
          {:kind, :symbol, "map or tuple"},
          {:key, :symbol, "Helpers.spell/1 map key or zero-based tuple index"}
        ],
        doc: """
        An exact field projection, preserving the containing value's identity. Equal \
        key names in different maps and distinct fields of one call result do not \
        alias. Nested projections form a chain.
        """
      },
      %{
        name: :security_arg_safe,
        layer: 2,
        fields: [
          {:id, :symbol, "call instruction ID"},
          {:func, :symbol, "calling function ID"},
          {:pos, :number, "zero-based argument position"},
          {:property, :symbol, "operation-specific property"}
        ],
        doc: """
        Every reaching value has the named property. html_text means literal text \
        or the output of HTML text escaping, not JavaScript, URL or attribute safety. \
        path_basename means the returned value of Path.basename/1,2 or \
        filename:basename/1,2, not containment: dot components need separate handling. \
        Unknown calls, one guarded branch, and checks of another value do not prove \
        safety. Phoenix.HTML.html_escape requires known binary input because safe \
        tuples pass through it unchanged.
        """
      },
      %{
        name: :security_arg_limit,
        layer: 2,
        fields: [
          {:id, :symbol, "call instruction ID"},
          {:func, :symbol, "calling function ID"},
          {:pos, :number, "zero-based argument position"},
          {:kind, :symbol, "byte_size"},
          {:limit, :number, "inclusive upper bound"}
        ],
        doc: """
        A branch before this call bounds byte_size of this exact argument on every \
        path to the call. The bound applies to input bytes, not decompressed size or \
        allocations made by decoding them. A check after use proves nothing here.
        """
      }
    ])
  end
end
