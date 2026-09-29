defmodule Argus.Schema.Web do
  @moduledoc """
  Layer-2 web facts: Phoenix routes, Ecto fields and redaction, derived Inspect output, \
  and LiveView connection checks. Exposed through `Argus.Schema`.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :http_route,
        layer: 2,
        fields: [
          {:router, :symbol, "the router module"},
          {:verb, :symbol, "the HTTP method"},
          {:path, :symbol, "the route path, with its placeholders"},
          {:plug, :symbol, "the controller or LiveView"},
          {:action, :symbol, "the action or live action"}
        ],
        doc: """
        A route from `Phoenix.Router.__routes__/0`. Pipeline information is compiled \
        into dispatch code, so this relation alone cannot establish authentication.
        """
      },
      %{
        name: :connected_guarded,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID of the call"},
          {:func, :symbol, "containing function ID"}
        ],
        doc: """
        A call restricted to the connected branch of `Phoenix.LiveView.connected?/1` or \
        a non-nil `get_connect_params/1` result. Excludes the disconnected branch and \
        code after branches rejoin. Used to distinguish connected mount work from static \
        rendering (`Argus.Extractors.LiveView`).
        """
      },
      %{
        name: :pubsub_call,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID of the call"},
          {:func, :symbol, "containing function ID"},
          {:op, :symbol, "subscribe | unsubscribe"},
          {:via, :symbol,
           "pubsub (Phoenix.PubSub, :pg), the module whose subscribe/1,2 or " <>
             "unsubscribe/1 it is, or apply (a module held in a value)"}
        ],
        doc: """
        A subscription, unsubscription, group join, or group leave. Includes PubSub and \
        `:pg` APIs, module subscription wrappers (`via`), and dynamic module calls \
        (`apply`), as recognized by `Argus.Extractors.LiveView`.
        """
      },
      %{
        name: :schema_field,
        layer: 2,
        fields: [
          {:mod, :symbol, "the schema module"},
          {:field, :symbol, "a persisted field"},
          {:type, :symbol,
           "its Ecto type as a reader is told it: 'string', a custom type's module, " <>
             "'embeds_one Mod', 'array of string'; 'dynamic' when __schema__/2 does not say"}
        ],
        doc: """
        An Ecto field and its type from `__schema__/1,2`. Datalog rules do not read the \
        type; `Argus.Priors.Questions.Sensitivity` uses it to classify the field.
        """
      },
      %{
        name: :lineless_schema,
        layer: 2,
        fields: [
          {:mod, :symbol, "the schema module"}
        ],
        doc: """
        An Ecto schema whose `__schema__/1` has only line-0 markers. Findings for such \
        generated embedded schemas anchor at the embedding schema.
        """
      },
      %{
        name: :redacted_field,
        layer: 2,
        fields: [
          {:mod, :symbol, "the schema module"},
          {:field, :symbol, "a field declared redact: true"}
        ],
        doc: """
        An Ecto field marked `redact: true`. Ecto hides it from inspection unless a \
        separately derived Inspect implementation controls the output. Redaction \
        defaults to off; consumers check for absence.
        """
      },
      %{
        name: :inspect_derived,
        layer: 2,
        fields: [
          {:mod, :symbol, "the struct module"}
        ],
        doc: """
        A derived Inspect implementation, including Ecto's redaction derive. \
        `inspect_shows` determines the visible fields. Hand-written implementations have \
        no row.
        """
      },
      %{
        name: :inspect_shows,
        layer: 2,
        fields: [
          {:mod, :symbol, "the struct module"},
          {:field, :symbol, "a field its derived Inspect prints"}
        ],
        doc: """
        A field visible through derived Inspect after `except:` and `only:` filtering. \
        For an `inspect_derived` struct, absent fields are hidden.
        """
      }
    ])
  end
end
