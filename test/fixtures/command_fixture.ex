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
  @moduledoc """
  A library's documented wrappers. A hidden export only the program calls
  takes what the program hands it (`internal_export` in unsafe_input.dl);
  a documented one is the library's API.
  """

  # An exported wrapper has callers the module cannot see.
  def mix(args), do: System.cmd("mix", args)
  def lint, do: mix(["credo"])

  # So does a private one the module hands out as a fun.
  def runner, do: &captured_mix/1
  def docs, do: captured_mix(["docs"])

  defp captured_mix(args), do: System.cmd("mix", args, stderr_to_stdout: true)
end

defmodule Argus.Test.Fixtures.CommandDataArgs do
  @moduledoc """
  A shell handed a literal script and the caller's data after it, as the
  script's positional parameters. argus's toolchain probes a process with
  `kill -0 "$1"`: the shell expands the quoted `"$1"` into one word that
  only `kill` sees, as an argument, whatever the caller hands in.
  """

  @probe ~S(kill -0 "$1" 2>/dev/null)

  def alive?(pid), do: System.cmd("/bin/sh", ["-c", @probe, "sh", pid])

  # The same through a private helper every caller hands a literal script.
  def stat(path), do: shell(~S(stat -c %s "$1" && wc -l "$1"), [path])

  defp shell(script, args), do: System.cmd("sh", ["-c", script, "sh" | args])
end

defmodule Argus.Test.Fixtures.CommandCodeArgs do
  @moduledoc """
  The twins: a literal script that runs its positional parameters as
  code. `"$@"` as a command word runs the program the caller names (argus's
  cargo guard), an unquoted `$1` is split and globbed, and `eval`, a
  wrapper and an interpreter run the string they are handed.
  """

  def run_guarded(program, args),
    do: System.cmd("/bin/sh", ["-c", ~S("$@" </dev/null & wait "$!"), "sh", program | args])

  def unquoted(arg), do: System.cmd("sh", ["-c", "kill -0 $1", "sh", arg])
  def evaluated(code), do: System.cmd("sh", ["-c", ~S(eval "$1"), "sh", code])
  def wrapped(cmd), do: System.cmd("sh", ["-c", ~S(nohup "$1" &), "sh", cmd])
  def interpreted(code), do: System.cmd("bash", ["-c", ~S(python3 -c "$1"), "bash", code])
  def substituted(arg), do: System.cmd("sh", ["-c", ~S|echo "$(cat "$1")"|, "sh", arg])
end

defmodule Argus.Test.Fixtures.CommandFixedInput do
  @moduledoc """
  Programs whose name and arguments no caller hands in: a program a helper
  finds on the PATH, and one the configuration names, each with literal
  arguments. argus's `rustc -vV` is this shape. Each is live code
  reachable from an export, and neither runs what a caller chooses.
  """

  def rustc_version, do: System.cmd(rustc(), ["-vV"])

  def tool_version, do: System.cmd(Application.fetch_env!(:my_app, :tool), ["--version"])

  defp rustc, do: System.find_executable("rustc") || "/usr/bin/rustc"
end

defmodule Argus.Test.Fixtures.CommandUnknownProgram do
  @moduledoc """
  The twin: a program no literal names, handed the caller's argument. It
  may be a shell or an interpreter, which runs that argument as code.
  """

  def lint(file), do: System.cmd(linter(), ["--quiet", file])

  defp linter, do: Path.join(System.user_home!(), "bin/lint")
end

defmodule Argus.Test.Fixtures.CommandRequest do
  @moduledoc "Subprocesses a request reaches."

  defmodule Jobs do
    @moduledoc "Jobs the program stored."
    def load(id), do: :persistent_term.get({__MODULE__, id})
  end

  defmodule ProgramPlug do
    @moduledoc "The request names the program: a flow."
    @behaviour Plug

    def init(opts), do: opts
    def call(conn, _opts), do: System.cmd(conn.params["program"], [])
  end

  defmodule DataPlug do
    @moduledoc "The request's value is a quoted positional parameter of a literal script."
    @behaviour Plug

    def init(opts), do: opts

    def call(conn, _opts),
      do: System.cmd("sh", ["-c", ~S(kill -0 "$1"), "sh", conn.params["pid"]])
  end

  defmodule FixedPlug do
    @moduledoc "A request's path to a program and script made of literals and configuration."
    @behaviour Plug

    def init(opts), do: opts
    def call(conn, _opts), do: {conn, restart()}

    def restart,
      do: System.cmd(Application.fetch_env!(:my_app, :supervisor_ctl), ["restart", "web"])
  end

  defmodule StoredPlug do
    @moduledoc "A request's path to a script made of a stored record: kept as a path."
    @behaviour Plug

    def init(opts), do: opts
    def call(conn, _opts), do: {conn, run(Jobs.load(:nightly))}

    def run(job), do: :os.cmd(String.to_charlist(job.script))
  end
end
