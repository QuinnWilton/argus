defmodule Argus.Findings.Names do
  @moduledoc """
  Names as a reader writes them, in a finding's prose.

  The facts spell a function `Mod:fun/2` and a closure
  `Mod:-fun/2-fun-0-/1`; a reader writes `Mod.fun/2`, and wants the
  function a closure was written in. `render/1` rewrites every piece of
  prose a built finding carries (title, detail, at_label, help, related
  labels) once, as the last step of `Argus.Findings.build/2`, so no
  builder has to remember. An instruction ID (`Mod:fun/2#7`) is left as
  it is — it is not a name — and so is a raw column (`site=Mod:fun/2`)
  in a generic finding.

  `call_name/1`, `elsewhere/2` and `rpc_api/1` are for builders that
  compose prose from a row's columns; analysis modules reach them
  through `Argus.Findings`' delegates.
  """

  alias Argus.InstrId

  @generated_name ~r/([A-Za-z0-9_.:]+):-([A-Za-z0-9_?!]+)\/(\d+)-\S*?-\/\d+/
  @function_id ~r/(?<![\w.:@=])(:[a-z][A-Za-z0-9_@]*|[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*):([a-z_][A-Za-z0-9_?!]*)\/(\d+)(?![\d#])/

  @doc """
  A callee as a reader writes it: the facts spell a call target
  `Mod:fun/arity` (`GenServer:call/2`, `:gen_statem:call/3`), prose wants
  `GenServer.call/2` and `:gen_statem.call/3`. Anything else — an API
  already spelled with a dot, a module — is returned as it is.

      iex> Argus.Findings.Names.call_name(":gen_statem:call/3")
      ":gen_statem.call/3"

      iex> Argus.Findings.Names.call_name("GenServer")
      "GenServer"
  """
  @spec call_name(String.t()) :: String.t()
  def call_name(callee) when is_binary(callee) do
    case Regex.run(~r/^(:?[A-Za-z][A-Za-z0-9_.]*):([a-z_][A-Za-z0-9_?!]*\/\d+)$/, callee) do
      [_, mod, fun] -> "#{mod}.#{fun}"
      nil -> callee
    end
  end

  @doc """
  Where a site is, said only when it is not in `func`: `" in Mod.fun/1"`,
  else `""`. An interprocedural finding names the function where a pair
  meets; its halves may sit in helpers that function calls.

      iex> Argus.Findings.Names.elsewhere("M:lookup/1#4", "M:ensure/1")
      " in M.lookup/1"

      iex> Argus.Findings.Names.elsewhere("M:ensure/1#4", "M:ensure/1")
      ""
  """
  @spec elsewhere(String.t(), String.t()) :: String.t()
  def elsewhere(site, func) when is_binary(site) and is_binary(func) do
    case InstrId.func_id_of(site) do
      {:ok, ^func} -> ""
      {:ok, other} -> " in " <> call_name(other)
      :error -> ""
    end
  end

  @doc """
  The API an rpc variant column names: the rules classify a remote call
  as `"rpc"`, `"multicall"` or `"erpc"`; the reader wants the function.
  """
  @spec rpc_api(String.t()) :: String.t()
  def rpc_api("rpc"), do: ":rpc.call"
  def rpc_api("multicall"), do: ":rpc.multicall"
  def rpc_api("erpc"), do: ":erpc.call"
  def rpc_api(other) when is_binary(other), do: other

  @doc """
  A finding with every piece of its prose in plain names (see the
  moduledoc): title, detail, at_label, help and each related frame's
  label.
  """
  @spec render(map()) :: map()
  def render(finding) do
    finding
    |> Map.update!(:title, &plain/1)
    |> Map.update!(:detail, &plain/1)
    |> Map.update!(:at_label, &plain/1)
    |> Map.update!(:help, fn help -> Enum.map(help, &plain/1) end)
    |> Map.update!(:related, fn related ->
      Enum.map(related, &Map.update!(&1, :label, fn label -> plain(label) end))
    end)
  end

  @doc """
  One piece of prose in plain names: a closure becomes the function it
  was written in, and a function ID is written with a dot.

      iex> Argus.Findings.Names.plain("Calls Foo.Bar:run/1 from :lists:map/2#3.")
      "Calls Foo.Bar.run/1 from :lists:map/2#3."

      iex> Argus.Findings.Names.plain("M:-run/1-fun-0-/2 sends.")
      "An anonymous function in M.run/1 sends."
  """
  @spec plain(String.t() | nil) :: String.t() | nil
  def plain(nil), do: nil

  def plain(text) when is_binary(text) do
    text
    |> String.replace(@generated_name, "an anonymous function in \\1:\\2/\\3")
    |> String.replace(~r/(^|\. )an anonymous function/, "\\1An anonymous function")
    |> String.replace(@function_id, "\\1.\\2/\\3")
  end
end
