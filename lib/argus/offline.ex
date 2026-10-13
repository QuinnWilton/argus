defmodule Argus.Offline do
  @moduledoc """
  Whether argus may use the network. Offline (`ARGUS_OFFLINE=1`, or
  `--offline` on `mix argus`, `mix argus.flowlog` and the `argus`
  escript), argus makes no network call of its own:

    * it downloads no prebuilt engines (`Argus.FlowLog.Prebuilt`), and
      uses a bundle only when an earlier run downloaded it;
    * Cargo builds the FlowLog toolchain offline (`cargo build
      --offline`), from the crates `~/.cargo` already holds;
    * `priors: :live` answers from the priors cache alone, as
      `:cached_only` does.

  The `:argus` Mix compiler reads `ARGUS_OFFLINE`, as it takes no flags.
  """

  @env "ARGUS_OFFLINE"

  @doc "Whether argus is offline: `ARGUS_OFFLINE` is set, and not to `0` or `false`."
  @spec offline?() :: boolean()
  def offline?, do: System.get_env(@env, "") not in ["", "0", "false"]

  @doc """
  Makes the rest of this VM's run offline, as a command's `--offline`
  does. It sets `ARGUS_OFFLINE`, so the processes argus starts (Cargo)
  see it too.
  """
  @spec enable() :: :ok
  def enable, do: System.put_env(@env, "1")

  @doc "The environment variable that turns offline mode on."
  @spec env_var() :: String.t()
  def env_var, do: @env
end
