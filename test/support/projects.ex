defmodule Argus.Test.Projects do
  @moduledoc """
  The non-Mix fixture projects under `test/projects`, built without
  their build tools: `synthesize!/2` copies one and compiles its Erlang
  with `:compile.file/2` into the layout its tool would have written,
  in well under a second and with no network. The `:rebar3` and
  `:gleam` tests build the same projects with the real tools.

    * `rebar3_app` — an umbrella (`apps/shop`, `apps/ledger`) and a
      dependency in `_checkouts/telemetry`, a stand-in for telemetry
      0.4.3, which the escript carries at another version: into
      `_build/default/lib/<app>/ebin` and
      `_build/default/checkouts/telemetry/ebin`.
    * `gleam_app` — the Erlang a Gleam 1.14 build wrote for its `src/`
      (`erlang/gleam_app`), and a stand-in for one module of
      `gleam_stdlib` (`erlang/gleam_stdlib`: `gleam@dynamic`, with its
      `nil/0`): into `build/dev/erlang/<package>/{_gleam_artefacts,ebin}`,
      compiled from the artefacts as Gleam compiles them.
    * `erlang_mk_app` — `src/` into `ebin/`, `deps/mk_dep/src` into
      `deps/mk_dep/ebin`.
  """

  @projects Path.expand("../projects", __DIR__)

  @doc "The fixture project's own directory."
  @spec source(atom()) :: Path.t()
  def source(name), do: Path.join(@projects, Atom.to_string(name))

  @doc """
  Copies the fixture `name` into `dest` (wiped first), builds it there
  as its tool would, and returns `dest`.
  """
  @spec synthesize!(atom(), Path.t()) :: Path.t()
  def synthesize!(name, dest) do
    File.rm_rf!(dest)
    File.mkdir_p!(dest)
    File.cp_r!(source(name), dest)
    build!(name, dest)
    dest
  end

  @doc "Copies the fixture `name` into `dest` (wiped first), unbuilt."
  @spec copy!(atom(), Path.t()) :: Path.t()
  def copy!(name, dest) do
    File.rm_rf!(dest)
    File.mkdir_p!(dest)
    File.cp_r!(source(name), dest)
    dest
  end

  defp build!(:rebar3_app, root) do
    lib = Path.join(root, "_build/default/lib")

    for app_dir <- Path.wildcard(Path.join(root, "apps/*")) do
      compile_app!(app_dir, Path.join([lib, Path.basename(app_dir), "ebin"]))
    end

    for dep <- Path.wildcard(Path.join(root, "_checkouts/*")) do
      compile_app!(dep, Path.join([root, "_build/default/checkouts", Path.basename(dep), "ebin"]))
    end
  end

  defp build!(:gleam_app, root) do
    erlang = Path.join(root, "build/dev/erlang")

    for package <- Path.wildcard(Path.join(root, "erlang/*")) do
      name = Path.basename(package)
      artefacts = Path.join([erlang, name, "_gleam_artefacts"])
      ebin = Path.join([erlang, name, "ebin"])
      File.mkdir_p!(artefacts)
      File.mkdir_p!(ebin)

      for file <- Path.wildcard(Path.join(package, "*")) do
        case Path.extname(file) do
          ".erl" -> File.cp!(file, Path.join(artefacts, Path.basename(file)))
          ".app" -> File.cp!(file, Path.join(ebin, Path.basename(file)))
        end
      end

      for erl <- Path.wildcard(Path.join(artefacts, "*.erl")), do: compile!(erl, ebin)
    end

    File.rm_rf!(Path.join(root, "erlang"))
  end

  defp build!(:erlang_mk_app, root) do
    compile_app!(root, Path.join(root, "ebin"))

    for dep <- Path.wildcard(Path.join(root, "deps/*")) do
      compile_app!(dep, Path.join(dep, "ebin"))
    end
  end

  # An application's src/*.erl into `ebin`, and its .app from its
  # .app.src (the modules filled in), as rebar3 and erlang.mk write it.
  defp compile_app!(app_dir, ebin) do
    File.mkdir_p!(ebin)

    modules =
      for erl <- app_dir |> Path.join("src/*.erl") |> Path.wildcard(), do: compile!(erl, ebin)

    for app_src <- Path.wildcard(Path.join(app_dir, "src/*.app.src")) do
      {:ok, [{:application, name, props}]} = :file.consult(String.to_charlist(app_src))
      props = Keyword.put(props, :modules, Enum.sort(modules))
      term = {:application, name, props}
      File.write!(Path.join(ebin, "#{name}.app"), :io_lib.format(~c"~tp.~n", [term]))
    end
  end

  defp compile!(erl, ebin) do
    options = [:debug_info, :return_errors, {:outdir, String.to_charlist(ebin)}]

    case :compile.file(String.to_charlist(erl), options) do
      {:ok, module} -> module
      {:ok, module, _warnings} -> module
      {:error, errors, _warnings} -> raise "#{erl} does not compile: #{inspect(errors)}"
    end
  end
end
