defmodule Argus.Schema.Priors do
  @moduledoc """
  Layer-3 classifier facts, written by `Argus.Priors` for questions bytecode cannot \
  settle and exposed through `Argus.Schema`. Each row ends in a probability in \
  thousandths (`permille`); rules choose their thresholds. Priors appear only as \
  positive premises to add heuristic findings or adjust severity, never to remove \
  structural rows. Missing priors are empty relations and preserve baseline findings.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :prior_reads,
        layer: 3,
        fields: [
          {:func, :func_id, "the function"},
          {:source, :symbol,
           "request | storage | config | internal | passthrough | constant — what the function itself reads"},
          {:permille, :number, "the model's probability for `source`, in thousandths"}
        ],
        doc: """
        A classifier's estimate of the external source a sink-containing function reads \
        directly, based on calls and literals. Parameter data is excluded \
        (`Argus.Priors.Questions.Reads`).
        """
      },
      %{
        name: :prior_value_source,
        layer: 3,
        fields: [
          {:func, :func_id, "the function holding the sink"},
          {:sink, :symbol, "atom | deserialization | code — which kind of sink"},
          {:source, :symbol,
           "configured | code | stored | cluster | operator | outside — the likeliest kind of value"},
          {:source_permille, :number, "the model's probability for `source`, in thousandths"},
          {:permille, :number,
           "the probability that the value is not outside data — the mass of every kind but " <>
             "`outside` — in thousandths"}
        ],
        doc: """
        A classifier's estimate of an unbounded sink input's origin: configuration, \
        program text, stored data, cluster messages, tool input, or external input \
        (`Argus.Priors.Questions.ValueSource`). Inferred from names around the call.
        """
      },
      %{
        name: :prior_answers,
        layer: 3,
        fields: [
          {:kind, :symbol,
           "'server' (a GenServer, by module) | 'wait' (a function with a receive that has no after)"},
          {:subject, :symbol, "the server module or the waiting function"},
          {:peer, :symbol, "local | remote | event — the likeliest"},
          {:peer_permille, :number, "the model's probability for `peer`, in thousandths"},
          {:permille, :number,
           "the probability that the answer comes from inside the node, every time: `local`'s, " <>
             "in thousandths"}
        ],
        doc: """
        A classifier's estimate of whether a wait can be answered within the node or \
        depends on external activity. Asked for servers with `handle_call/3` and \
        functions with unbounded receives (`Argus.Priors.Questions.PeerAnswers`).
        """
      },
      %{
        name: :prior_sensitive,
        layer: 3,
        fields: [
          {:subject_kind, :symbol, "'schema_field' | 'config_key'"},
          {:mod, :symbol, "the schema module, or the module reading the key"},
          {:name, :symbol, "the field or key, spelled as schema_field spells it (':email')"},
          {:kind, :symbol, "'secret' | 'personal' | 'none' — the class with the most mass"},
          {:detail, :symbol,
           "credential | password | token (secret); pii | financial | health (personal); " <>
             "secret_reference | public_key | none (none) — the likeliest within `kind`"},
          {:detail_permille, :number, "the model's probability for `detail`, in thousandths"},
          {:permille, :number,
           "the model's probability for `kind`, the sum over its details, in thousandths"}
        ],
        doc: """
        A field or configuration key's estimated sensitivity, based on name, type, and \
        schema (`Argus.Priors.Questions.Sensitivity`). Secret identifiers and public \
        portions are `none`. `permille` sums probability for the broad `kind`; `detail` \
        is its most likely subtype.
        """
      },
      %{
        name: :prior_tooling,
        layer: 3,
        fields: [
          {:mod, :symbol, "the module, inspected"},
          {:kind, :symbol, "product | development | test — the likeliest"},
          {:kind_permille, :number, "the model's probability for `kind`, in thousandths"},
          {:permille, :number,
           "the probability that the module is tooling — the mass of `development` and " <>
             "`test` — in thousandths"}
        ],
        doc: """
        A classifier's estimate of whether a module is product code, developer tooling, \
        or test support (`Argus.Priors.Questions.Tooling`). Asked only when \
        `tooling_module` is undecided; used to lower finding severity in tooling.
        """
      },
      %{
        name: :prior_talks_to_process,
        layer: 3,
        fields: [
          {:mod, :symbol, "the module"},
          {:permille, :number,
           "the model's probability that calling the module's public functions messages or waits on a long-lived process, in thousandths"}
        ],
        doc: """
        A classifier's estimate of whether a module fronts a process or is a helper \
        containing incidental calls (`Argus.Priors.Questions.ProcessRole`). Asked for \
        modules with calls or casts but no callback loop; qualifies inferred coupling \
        dependencies.
        """
      }
    ])
  end
end
