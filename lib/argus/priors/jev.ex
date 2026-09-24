defmodule Argus.Priors.Jev do
  @moduledoc """
  typesafe.ai's Jev as an `Argus.Priors.Oracle`.

  One endpoint, `POST /v1/systemone`, bearer authentication, JSON in and
  out. The model is pinned: thresholds in the rules were calibrated on
  `jev-1.13.0`, and a newer model answers differently enough that the
  cache is keyed on the name. Rate-limit and overload responses (429, 529)
  and 5xx are retried with exponential backoff; anything else is an error
  the driver records and moves past.

  Requests go over the `:argus_priors` httpc profile rather
  than the default one. httpc queues a keep-alive request behind a busy
  connection rather than open another, so on the default profile a
  driver's requests in flight share the few connections its first burst
  opened and wait on each other; this profile hands each request an idle
  connection or a new one (`max_keep_alive_length: 0`), keeping them
  alive for the next request, up to 64 at once.

  ## Options

  - `:api_key` — default `TYPESAFE_API_KEY` from the environment
  - `:endpoint` — default `#{inspect("https://api.typesafe.ai/v1/systemone")}`
  - `:timeout` — per request, milliseconds (default 60_000)
  - `:max_attempts` — including the first (default 5)
  """

  @behaviour Argus.Priors.Oracle

  @endpoint "https://api.typesafe.ai/v1/systemone"
  @model "jev-1.13.0"
  @env_var "TYPESAFE_API_KEY"
  @profile :argus_priors
  @profile_options [max_sessions: 64, max_keep_alive_length: 0, keep_alive_timeout: 120_000]

  @doc "The pinned model name."
  @spec model() :: String.t()
  def model, do: @model

  @doc "The httpc profile requests go over."
  @spec profile() :: atom()
  def profile, do: @profile

  @doc "The environment variable the key is read from."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc """
  The API key from `opts` or the environment, or `:error`.
  """
  @spec api_key(keyword()) :: {:ok, String.t()} | :error
  def api_key(opts \\ []) do
    case Keyword.get(opts, :api_key) || System.get_env(@env_var) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> :error
    end
  end

  @impl true
  def ask(%{model: _, state: _, questions: _} = request, opts \\ []) do
    with {:ok, key} <- api_key_or_error(opts),
         :ok <- start_clients() do
      body = JSON.encode!(request)
      post(body, key, opts, 1)
    end
  end

  defp api_key_or_error(opts) do
    case api_key(opts) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, {:no_api_key, @env_var}}
    end
  end

  defp start_clients do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      start_profile()
    end
  end

  # Concurrent first requests race to start the profile; the losers see
  # it started. Options are set on every request because a loser can get
  # here before the winner has set them: the call is idempotent and cheap
  # beside the request itself.
  defp start_profile do
    started =
      case :inets.start(:httpc, profile: @profile) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, reason} -> {:error, {:httpc_profile, reason}}
      end

    with :ok <- started do
      :httpc.set_options(@profile_options, @profile)
    end
  end

  defp post(body, key, opts, attempt) do
    endpoint = Keyword.get(opts, :endpoint, @endpoint)
    timeout = Keyword.get(opts, :timeout, 60_000)
    headers = [{~c"authorization", String.to_charlist("Bearer " <> key)}]

    request = {String.to_charlist(endpoint), headers, ~c"application/json", body}
    http_opts = [timeout: timeout, ssl: ssl_opts()]

    case :httpc.request(:post, request, http_opts, [body_format: :binary], @profile) do
      {:ok, {{_, 200, _}, resp_headers, resp}} ->
        decode(resp, resp_headers)

      {:ok, {{_, status, _}, _, resp}} when status in [429, 529] or status >= 500 ->
        retry(body, key, opts, attempt, {:http, status, resp})

      {:ok, {{_, status, _}, _, resp}} ->
        {:error, {:http, status, resp}}

      {:error, reason} ->
        retry(body, key, opts, attempt, reason)
    end
  end

  # The certificate is a wildcard, which :ssl's default hostname check
  # rejects; the :https match function accepts it as browsers do.
  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp retry(body, key, opts, attempt, reason) do
    if attempt >= Keyword.get(opts, :max_attempts, 5) do
      {:error, {:gave_up, reason}}
    else
      Process.sleep(500 * Integer.pow(2, attempt - 1))
      post(body, key, opts, attempt + 1)
    end
  end

  defp decode(resp, headers) do
    case JSON.decode(resp) do
      {:ok, %{"answers" => answers} = decoded} when is_map(answers) ->
        {:ok,
         %{
           answers: answers,
           usage: Map.get(decoded, "usage", %{}),
           model: Map.get(decoded, "model"),
           request_id: header(headers, "x-typesafe-request-id")
         }}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        {:error, {:malformed_json, reason}}
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if to_string(k) == name, do: to_string(v) end)
  end
end
