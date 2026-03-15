defmodule Argus.LLM do
  @moduledoc """
  Shell-out wrapper for LLM CLI tools.

  Sends prompts to an LLM command-line tool via stdin and returns the response.
  Writes the prompt to a temp file and uses shell redirection to pipe it into
  the LLM binary's stdin, since `System.cmd/3` does not support stdin and
  Erlang ports cannot half-close stdin while keeping stdout open.

  ## Binary resolution

  The LLM binary is resolved in order:

  1. `:llm_bin` option
  2. `ARGUS_LLM_BIN` environment variable
  3. `claude` on PATH

  ## Options

  - `:llm_bin` — path to the LLM binary
  - `:llm_timeout` — timeout in milliseconds (default: 120_000)
  - `:llm_args` — extra arguments to pass before `--print` (default: `[]`)
  """

  @default_timeout 120_000

  @doc """
  Sends a prompt to the LLM and returns the response.

  Returns `{:ok, response}` on success or `{:error, reason}` on failure.

  Error reasons:

  - `:llm_not_found` — no LLM binary found
  - `:llm_timeout` — the LLM did not respond within the timeout
  - `{:llm_error, exit_code, output}` — the LLM exited with a non-zero status
  """
  @spec prompt(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def prompt(text, opts \\ []) do
    case resolve_bin(opts) do
      nil ->
        {:error, :llm_not_found}

      bin ->
        if File.exists?(bin) do
          timeout = Keyword.get(opts, :llm_timeout, @default_timeout)
          extra_args = Keyword.get(opts, :llm_args, [])
          run_prompt(bin, extra_args, text, timeout)
        else
          {:error, :llm_not_found}
        end
    end
  end

  @doc """
  Returns true if an LLM binary is available.
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []) do
    case resolve_bin(opts) do
      nil -> false
      path -> File.exists?(path)
    end
  end

  @doc """
  Resolves the LLM binary path from options, environment, or PATH.

  Returns `nil` if no binary is found.
  """
  @spec resolve_bin(keyword()) :: String.t() | nil
  def resolve_bin(opts \\ []) do
    Keyword.get(opts, :llm_bin) ||
      System.get_env("ARGUS_LLM_BIN") ||
      System.find_executable("claude")
  end

  # Writes prompt to a temp file and uses shell redirection to pipe it
  # into the LLM binary's stdin. This avoids argument length limits and
  # works around Erlang ports not supporting stdin half-close.
  defp run_prompt(bin, extra_args, text, timeout) do
    case System.tmp_dir() do
      nil -> {:error, :no_tmp_dir}
      tmp -> do_run_prompt(bin, extra_args, text, timeout, tmp)
    end
  end

  defp do_run_prompt(bin, extra_args, text, timeout, tmp) do
    prompt_file = Path.join(tmp, "argus_llm_#{System.unique_integer([:positive])}")
    File.write!(prompt_file, text)

    args = extra_args ++ ["--print", "-"]

    shell_cmd =
      Enum.map_join([bin | args], " ", &shell_escape/1) <>
        " < " <> shell_escape(prompt_file)

    task = Task.async(fn -> System.cmd("/bin/sh", ["-c", shell_cmd], stderr_to_stdout: true) end)

    try do
      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, {output, 0}} ->
          {:ok, String.trim(output)}

        {:ok, {output, exit_code}} ->
          {:error, {:llm_error, exit_code, output}}

        nil ->
          {:error, :llm_timeout}
      end
    after
      File.rm(prompt_file)
    end
  end

  # Single-quote escaping for POSIX shell. Wraps the string in single quotes
  # and escapes any embedded single quotes.
  defp shell_escape(str) do
    "'" <> String.replace(str, "'", "'\\''") <> "'"
  end
end
