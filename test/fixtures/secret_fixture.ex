defmodule Argus.Test.Fixtures.Secret do
  @moduledoc """
  Fixtures for the secret-exposure analysis.

  Ecto is not a dependency here, so `__schema__/1` is written by hand. That
  is the contract anyway — the analysis reads the compiled function, not the
  macro that usually writes it — and a hand-written clause compiles to the
  same `select_val` dispatch a real schema does.
  """

  defmodule Exposed do
    @moduledoc "Credentials with no redaction anywhere."
    def __schema__(:fields), do: [:id, :name, :sendgrid_api_key, :smtp_password]
    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil
  end

  defmodule PartlyRedacted do
    @moduledoc """
    Redacts one field and not the other. The interesting case: the pattern
    is known here and was not applied, which is an oversight rather than an
    unfamiliar API.
    """
    def __schema__(:fields), do: [:id, :api_key, :client_secret]
    def __schema__(:redact_fields), do: [:api_key]
    def __schema__(_other), do: nil
  end

  defmodule Redacted do
    @moduledoc "Everything sensitive is redacted."
    def __schema__(:fields), do: [:id, :access_token, :password]
    def __schema__(:redact_fields), do: [:access_token, :password]
    def __schema__(_other), do: nil
  end

  defmodule WithEmbed do
    @moduledoc """
    akkoma's `Pleroma.MFA.Settings`: an `embeds_one :totp, TOTP do ... end`
    block whose module (`WithEmbed.Totp`, below) holds the TOTP seed.
    """
    def __schema__(:fields), do: [:enabled, :totp]
    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil

    def __schema__(:type, :enabled), do: :boolean

    def __schema__(:type, :totp),
      do:
        {:parameterized,
         {Ecto.Embedded, %{cardinality: :one, related: Argus.Test.Fixtures.Secret.WithEmbed.Totp}}}

    def __schema__(:association, _field), do: nil
    def __schema__(:embed, _field), do: nil
    def __schema__(:field_source, field), do: field
    def __schema__(:virtual_type, _field), do: nil
  end

  defmodule ResetToken do
    @moduledoc """
    akkoma's `Pleroma.PasswordResetToken`: a schema named for a token,
    whose `token` is the live bearer value of a password reset.
    """
    def __schema__(:fields), do: [:id, :token, :user_id, :used]
    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil
  end

  defmodule Ticker do
    @moduledoc "A `token` that names a currency, in a schema named for no token."
    def __schema__(:fields), do: [:id, :token, :price]
    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil
  end

  defmodule Heuristic do
    @moduledoc """
    A secret the substring table cannot name. `totp_seed` matches none of
    the thirteen fragments, so only a prior reports it — and only when the
    run asks for priors.
    """
    def __schema__(:fields), do: [:id, :totp_seed, :label]
    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil

    # The types, as Ecto compiles them: a dispatch on the key, then one on
    # the field. `Sensitivity` shows them to the model beside the names.
    def __schema__(:type, :id), do: :id
    def __schema__(:type, :totp_seed), do: Argus.Test.Encrypted.Binary
    def __schema__(:type, :label), do: :string
    def __schema__(:association, _field), do: nil
    def __schema__(:embed, _field), do: nil
    def __schema__(:field_source, field), do: field
    def __schema__(:virtual_type, _field), do: nil
  end

  defmodule Typed do
    @moduledoc """
    Every shape of type `__schema__(:type, field)` returns: a primitive, a
    custom type's module, an embed in Ecto's current and older spellings,
    a parameterized type, a collection, and one no reader could name.
    Nothing here is a secret; the extractor's spelling of each is.
    """
    def __schema__(:fields),
      do: [:id, :body, :profile, :history, :status, :tags, :scores, :opaque, :untyped]

    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil

    def __schema__(:type, :id), do: :binary_id
    def __schema__(:type, :body), do: MyApp.Markdown

    def __schema__(:type, :profile),
      do: {:parameterized, {Ecto.Embedded, %{cardinality: :one, related: MyApp.Profile}}}

    def __schema__(:type, :history),
      do: {:parameterized, Ecto.Embedded, %{cardinality: :many, related: MyApp.Change}}

    def __schema__(:type, :status), do: {:parameterized, {Ecto.Enum, %{type: :string}}}
    def __schema__(:type, :tags), do: {:array, :string}
    def __schema__(:type, :scores), do: {:map, :integer}
    def __schema__(:type, :opaque), do: {:weird, 1}
    def __schema__(:association, _field), do: nil
    def __schema__(:embed, _field), do: nil
    def __schema__(:field_source, field), do: field
    def __schema__(:virtual_type, _field), do: nil
  end

  defmodule Ordinary do
    @moduledoc "No field name suggests a secret."
    def __schema__(:fields), do: [:id, :title, :body, :inserted_at]
    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil
  end

  defmodule SecretMetadata do
    @moduledoc """
    Fields that name a secret but hold facts about it: when a reset was
    sent, when a token expires. The token itself is still reported.
    """
    def __schema__(:fields),
      do: [:id, :password_reset_sent_at, :access_token_expires_at, :api_key_count, :access_token]

    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil
  end

  defmodule DerivedExcept do
    @moduledoc """
    `@derive {Inspect, except: [...]}` hides what `redact: true` would:
    the excluded secrets are quiet, and the secret the list forgot is
    reported, with the derive as the place to fix it. sequin's NatsSink
    before 035ee6f, which added `:nkey_seed` to such a list.
    """
    @derive {Inspect, except: [:password, :jwt]}
    defstruct [:id, :host, :password, :jwt, :sendgrid_api_key]

    def __schema__(:fields), do: [:id, :host, :password, :jwt, :sendgrid_api_key]
    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil
  end

  defmodule DerivedOnly do
    @moduledoc "`only:` names what is printed; every secret here is left out."
    @derive {Inspect, only: [:id, :name]}
    defstruct [:id, :name, :client_secret, :access_token]

    def __schema__(:fields), do: [:id, :name, :client_secret, :access_token]
    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil
  end

  defmodule LeakyOnly do
    @moduledoc "`only:` that names a secret prints it."
    @derive {Inspect, only: [:id, :api_key]}
    defstruct [:id, :api_key, :password]

    def __schema__(:fields), do: [:id, :api_key, :password]
    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil
  end

  defmodule EctoDerived do
    @moduledoc """
    What Ecto writes for `redact: true`: the redacted fields, and a derive
    that excludes exactly them. The fix for the other secret is still
    `redact: true`.
    """
    @derive {Inspect, except: [:password]}
    defstruct [:id, :password, :api_key]

    def __schema__(:fields), do: [:id, :password, :api_key]
    def __schema__(:redact_fields), do: [:password]
    def __schema__(_other), do: nil
  end

  defmodule RedactOverridden do
    @moduledoc """
    `redact: true` under the schema's own `@derive Inspect`: Ecto derives
    nothing then, so the redacted field is printed after all.
    """
    @derive Inspect
    defstruct [:id, :password]

    def __schema__(:fields), do: [:id, :password]
    def __schema__(:redact_fields), do: [:password]
    def __schema__(_other), do: nil
  end
end

# The module an `embeds_one :totp, TOTP do ... end` block compiles to
# carries no line (every marker is line 0), as akkoma's
# `Pleroma.MFA.Settings.TOTP` does: Ecto creates it from the block with no
# location. Its seed is reported at `WithEmbed`, whose source holds it.
Module.create(
  Argus.Test.Fixtures.Secret.WithEmbed.Totp,
  quote do
    @moduledoc false
    def __schema__(:fields), do: [:secret, :delivery_type]
    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil
  end,
  file: __ENV__.file,
  line: 0
)
