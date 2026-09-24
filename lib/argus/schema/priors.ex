defmodule Argus.Schema.Priors do
  @moduledoc """
  Layer 3, the priors: facts no extractor emits — a classifier's answers
  to questions the bytecode cannot settle, written by `Argus.Priors`
  into the facts directory after extraction, or not at all. Every prior
  relation ends in `permille`, the model's probability for the row in
  thousandths, so a rule chooses its own threshold; rules use a prior
  only as a positive premise, to add a heuristic-labelled finding or
  move a severity, never to remove a structural row. Absent priors are
  empty relations, and the findings are exactly those of a run without
  them.

  Layer 3 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    [
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
        Which external source a function itself reads, judged from what it calls \
        and its literals; its arguments do not count, whoever calls it \
        (Argus.Priors.Questions.Reads). Asked about the functions that hold a \
        sink, so unsafe_input can tell a helper that converts a stored record \
        from one that converts whatever it is handed.
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
        What a field or configuration key holds, judged from its name, its type \
        and the schema around it (Argus.Priors.Questions.Sensitivity); a secret's \
        id, name or public half is `none`, not a secret. `kind` is the \
        class a rule consumes and `permille` its total probability, so a field \
        the model is sure is a secret but splits between token and credential \
        is a secret at the sum; `detail` is the likeliest finer kind within it.
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
        Whether a module fronts a process — its API sends to or waits on a \
        server — or is a helper that merely contains a call somewhere \
        (Argus.Priors.Questions.ProcessRole). Asked about the modules with a \
        call or cast but no callback loop, which is what the module-level \
        dependency in calls.dl cannot tell apart; coupling doubts a dependency \
        inferred that way when the answer is no.
        """
      }
    ]
  end
end
