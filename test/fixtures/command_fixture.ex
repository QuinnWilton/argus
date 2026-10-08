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

defmodule Argus.Test.Fixtures.CommandMixTask do
  @moduledoc false

  # ex_quality's version resolver: `mix hex.info` runs the hex.info task,
  # and the package it is handed is that task's argument, not code.
  def fetch_version(package), do: System.cmd("mix", ["hex.info", to_string(package)])

  # ex_quality's docs stage: the output path is an option of `mix docs`.
  def build_docs(out) do
    System.cmd("mix", ["docs", "--formatter", "html", "--output", out, "--warnings-as-errors"])
  end
end

defmodule Argus.Test.Fixtures.CommandMixHelper do
  @moduledoc false

  # ex_quality's credo stage: a helper starts every list with the task.
  def credo(strict, name) do
    System.cmd("mix", credo_args(strict, name), env: [{"MIX_ENV", "dev"}])
  end

  defp credo_args(strict, name) do
    args = ["credo", "--format", "json"]
    args = if strict, do: args ++ ["--strict"], else: args
    if name, do: args ++ ["--config-name", name], else: args
  end

  # ex_quality's sobelow stage: the task, then options built from config.
  def sobelow(path, conf, out), do: System.cmd("mix", sobelow_args(path, conf, out))

  defp sobelow_args(path, conf, out) do
    ["sobelow", "--format", "json", "--out", out] ++ root_args(path) ++ conf_args(conf)
  end

  defp root_args(nil), do: []
  defp root_args(path), do: ["--root", path]

  defp conf_args(conf), do: Enum.flat_map(conf, fn {key, value} -> ["--#{key}", value] end)
end

defmodule Argus.Test.Fixtures.CommandMixWrapper do
  @moduledoc false

  # A private wrapper whose every caller names a task that runs no code
  # its arguments name.
  def lint(args), do: mix(["credo" | args])
  def docs(out), do: mix(["docs", "--output", out])

  defp mix(args), do: System.cmd("mix", args, env: [{"MIX_ENV", "dev"}])
end

defmodule Argus.Test.Fixtures.CommandMixCode do
  @moduledoc false

  # `mix run -e` evaluates the code it is handed.
  def eval(code), do: System.cmd("mix", ["run", "-e", code])

  # The caller names the task.
  def task(name, args), do: System.cmd("mix", [name | args])

  # A shell runs its script.
  def shell(input), do: System.cmd("sh", ["-c", input])
end

defmodule Argus.Test.Fixtures.CommandMixTestWrapper do
  @moduledoc false

  # ex_quality's test stage: one caller hands the wrapper `test` and the
  # files to run, which `mix test` loads and runs.
  def coverage(args), do: mix(["coveralls" | args])
  def run_tests(args, files), do: mix(["test"] ++ args ++ files)
  def aggregate, do: mix(["test.coverage"])

  defp mix(args), do: System.cmd("mix", args, env: [{"MIX_ENV", "test"}])
end

defmodule Argus.Test.Fixtures.CommandOpenWrapper do
  @moduledoc false

  # An exported wrapper has callers the module cannot see.
  def mix(args), do: System.cmd("mix", args)
  def lint, do: mix(["credo"])

  # So does a private one the module hands out as a fun.
  def runner, do: &captured_mix/1
  def docs, do: captured_mix(["docs"])

  defp captured_mix(args), do: System.cmd("mix", args, stderr_to_stdout: true)
end
