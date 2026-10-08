defmodule Argus.Test.Fixtures.CommandLiteralJoin do
  @moduledoc false

  # ex_quality's compile stage: each `if` picks one of two literal lists, so
  # the arguments are literal on every path, though no one value reaches.
  def compile(env, warnings_as_errors, force) do
    args =
      ["compile"] ++
        if(warnings_as_errors, do: ["--warnings-as-errors"], else: []) ++
        if(force, do: ["--force"], else: [])

    System.cmd("mix", args, env: [{"MIX_ENV", env}])
  end

  # A shell handed one of two literal scripts.
  def build(verbose?) do
    System.cmd("sh", ["-c"] ++ if(verbose?, do: ["make V=1"], else: ["make"]))
  end
end

defmodule Argus.Test.Fixtures.CommandDynamicJoin do
  @moduledoc false

  # The twin: one path hands the shell the caller's script.
  def build(script, custom?) do
    System.cmd("sh", ["-c"] ++ if(custom?, do: [script], else: ["make"]))
  end
end

defmodule Argus.Test.Fixtures.CommandLiteralHelper do
  @moduledoc false

  # ex_quality's doctor stage: a private helper returns one of two literal
  # lists, and the caller runs what it returns.
  def doctor(config) do
    System.cmd("mix", doctor_args(config), env: [{"MIX_ENV", "dev"}])
  end

  defp doctor_args(config) do
    args = ["doctor", "--raise"]
    if Keyword.get(config, :summary_only, false), do: args ++ ["--summary"], else: args
  end

  # A shell script picked by a helper, which appends to a literal head.
  def lint(config), do: System.cmd("sh", lint_script(config))

  defp lint_script(config), do: ["-c"] ++ lint_target(Keyword.get(config, :strict))

  defp lint_target(true), do: ["make lint STRICT=1"]
  defp lint_target(_other), do: ["make lint"]
end

defmodule Argus.Test.Fixtures.CommandDynamicHelper do
  @moduledoc false

  # The twin: on one path the helper hands back the configured command.
  def lint(config), do: System.cmd("sh", lint_script(config))

  defp lint_script(config) do
    case Keyword.fetch(config, :command) do
      {:ok, command} -> ["-c", command]
      :error -> ["-c", "make lint"]
    end
  end
end
