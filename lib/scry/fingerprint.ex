defmodule Scry.Fingerprint do
  @moduledoc """
  What the memoized graph is a function of beyond the beams: the
  environment the driver stamps into the `:env_fingerprint` input.

  Anything that changes an extraction or a solve without changing a
  beam must move a value here, or a warm manifest serves results the
  current toolchain would not compute.
  """

  @typedoc "The `:env_fingerprint` input's value."
  @type env :: %{
          elixir: String.t(),
          otp: String.t(),
          argus: String.t(),
          scry: String.t(),
          argus_schema: pos_integer(),
          souffle: String.t() | nil
        }

  # The environment fingerprint. `souffle?` says whether a solver is on
  # `PATH`; its version rides the fingerprint when it is, and `nil` when
  # it is not, so installing one moves the value.
  @doc false
  # What must invalidate the whole graph when it moves: the runtime the
  # extraction runs on, the argus code (extractors and .dl rules ship
  # without schema bumps, so the app vsn — coarse but correct), this
  # layer's own encoding, the schema, and the solver binary. Souffle's
  # entry doubles as the healing signal for install-after-degrade.
  @spec env(boolean()) :: env()
  def env(souffle?) do
    %{
      elixir: System.version(),
      otp: System.otp_release(),
      argus: app_vsn(:panoptes),
      scry: app_vsn(:scry),
      argus_schema: Argus.Schema.version(),
      souffle: if(souffle?, do: souffle_version(), else: nil)
    }
  end

  defp app_vsn(app) do
    _ = Application.load(app)

    case Application.spec(app, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  defp souffle_version do
    case System.cmd("souffle", ["--version"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> List.first() || "unknown"
      _ -> "unknown"
    end
  rescue
    # available? raced against the binary disappearing — the fingerprint
    # still moves relative to nil, which is all the healing needs.
    ErlangError -> "unknown"
  end
end
