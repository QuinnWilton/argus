defmodule Argus.Findings.Anchor do
  @moduledoc """
  Where a finding points: an anchor parsed from the IDs a row carries.

  The facts spell locations as strings — an instruction ID
  (`"Mod:fun/2#7"`), a function ID (`"Mod:fun/2"`), a module as
  `inspect/1` prints it (`"MyApp.Cache"`, `":lists"`) — and a column that
  could not be resolved says `"dynamic"`. An anchor is the most precise
  of these a row allows, with the coarser fields filled in from it:

  - `instr` — an `Argus.InstrId` when the row carries an instruction ID.
  - `mfa` — `{module, function, arity}` when the row carries a function
    ID (or names a well-known callback such as `init/1`).
  - `module` — set whenever the row names a module at all.

  Parsing is best-effort by design: an ID that does not parse yields an
  empty anchor (or the next coarser one, for `at_site/2` and
  `at_site_in_func/3`), never an error. Analysis modules reach these
  through `Argus.Findings`' delegates (`Findings.at_site/2`, ...), so one
  alias serves a finding builder.

  ## Atom creation

  Parsing converts module and function name strings back to atoms with
  `String.to_atom/1`. Those names come from BEAM files the caller asked
  Argus to disassemble, so the atoms already exist in this node's atom
  table — parsing does not grow it. Do not feed findings from untrusted
  `.beam` files into a long-lived node; run Argus in a sandbox process
  instead (this is how lowdown consumes uploads).
  """

  alias Argus.InstrId

  @typedoc "Code location attached to a finding, most precise field wins."
  @type t :: %{
          module: module() | nil,
          mfa: mfa() | nil,
          instr: InstrId.t() | nil
        }

  @doc "The anchor that points nowhere."
  @spec empty() :: t()
  def empty, do: %{module: nil, mfa: nil, instr: nil}

  @doc """
  Anchor for an instruction ID string (`"Mod:func/arity#idx"`).

  Unparseable input (a `"dynamic"` placeholder, free-form text) yields an
  empty anchor rather than an error — anchors are best-effort by design.
  """
  @spec at_instr(String.t()) :: t()
  def at_instr(id) when is_binary(id) do
    case InstrId.parse(id) do
      {:ok, instr} ->
        anchor = at_parts(instr.module, instr.func, instr.arity)
        %{anchor | instr: instr}

      :error ->
        empty()
    end
  end

  @doc "Anchor for a function ID string (`\"Mod:func/arity\"`)."
  @spec at_func(String.t()) :: t()
  def at_func(func_id) when is_binary(func_id) do
    case InstrId.parse_func(func_id) do
      {:ok, %{module: module, func: func, arity: arity}} -> at_parts(module, func, arity)
      :error -> empty()
    end
  end

  @doc """
  Anchor for a known callback on a module string.

  Several relations report a module known to implement a specific callback
  (`init/1`, `handle_cast/2`, ...) without carrying a function ID — this
  reconstructs the precise anchor.
  """
  @spec at_mfa(String.t(), atom(), arity()) :: t()
  def at_mfa(module_string, func, arity)
      when is_binary(module_string) and is_atom(func) and is_integer(arity) do
    case module_atom(module_string) do
      nil -> empty()
      module -> %{module: module, mfa: {module, func, arity}, instr: nil}
    end
  end

  @doc ~S|Anchor for a module string (`"MyApp.Cache"` or `":lists"`).|
  @spec at_module(String.t()) :: t()
  def at_module(module_string) when is_binary(module_string) do
    %{module: module_atom(module_string), mfa: nil, instr: nil}
  end

  @doc """
  Anchor for a site ID of either precision, falling back to a module.

  Witness columns hold an instruction ID where the extractor had one and
  a function ID otherwise; extractors mark sites they cannot resolve
  with a `"dynamic"` placeholder. This tries the most precise parse
  first — instruction, then function, then the module fallback — so a
  finding never loses its module anchor to an unresolvable site.

  The second argument is a module string (`"MyApp.Cache"`, `":lists"`).
  When the row names the function the site is in, use
  `at_site_in_func/3`, which falls back to that function instead.
  """
  @spec at_site(String.t(), String.t()) :: t()
  def at_site(id, module_string)
      when is_binary(id) and is_binary(module_string) do
    with %{instr: nil} <- at_instr(id),
         %{mfa: nil} <- at_func(id) do
      at_module(module_string)
    end
  end

  @doc """
  Anchor for a site ID inside a known function, falling back to that
  function.

  Like `at_site/2`, but the fallback is a function ID
  (`"Mod:fun/arity"`) rather than a module string: a row whose site is
  empty or `"dynamic"` still anchors at the function it names. When the
  function ID does not parse either, `module_string` (when given) is the
  last resort.

      iex> Argus.Findings.Anchor.at_site_in_func("M:f/1#3", "M:f/1").instr.idx
      3

      iex> Argus.Findings.Anchor.at_site_in_func("dynamic", ":lists:map/2").mfa
      {:lists, :map, 2}

      iex> Argus.Findings.Anchor.at_site_in_func("", "dynamic", "M").module
      M
  """
  @spec at_site_in_func(String.t(), String.t(), String.t() | nil) :: t()
  def at_site_in_func(site, func_id, module_string \\ nil)
      when is_binary(site) and is_binary(func_id) and
             (is_nil(module_string) or is_binary(module_string)) do
    with %{instr: nil} <- at_instr(site),
         %{mfa: nil} <- at_func(site),
         %{mfa: nil} <- at_func(func_id) do
      if module_string, do: at_module(module_string), else: empty()
    end
  end

  @doc """
  The anchor of the first value in a row that parses as an instruction
  or function ID, or the empty anchor. The generic rendering of a row
  (a relation with no builder, or a row its builder raised on) anchors
  here.

      iex> Argus.Findings.Anchor.from_row(["dynamic", "M:f/1", "M:g/2#4"]).mfa
      {M, :f, 1}

      iex> Argus.Findings.Anchor.from_row(["dynamic", "error"])
      %{module: nil, mfa: nil, instr: nil}
  """
  @spec from_row([String.t()]) :: t()
  def from_row(row) when is_list(row) do
    Enum.find_value(row, empty(), fn value ->
      case at_instr(value) do
        %{instr: nil} ->
          case at_func(value) do
            %{mfa: nil} -> nil
            anchor -> anchor
          end

        anchor ->
          anchor
      end
    end)
  end

  @doc """
  Converts an `inspect/1`-rendered module string back to the module atom.

  Returns `nil` for the `"dynamic"` placeholder and anything else that
  isn't a module rendering — a function ID (`"Foo.Bar:baz/1"`,
  `":lists:map/2"`) included, so a builder that passes one where a
  module belongs gets no anchor rather than an invented module. An
  Erlang module whose name contains `:` or `/` cannot be told from a
  function ID and reads as `nil` too.

      iex> Argus.Findings.Anchor.module_atom("Foo.Bar")
      Foo.Bar

      iex> Argus.Findings.Anchor.module_atom(":lists")
      :lists

      iex> Argus.Findings.Anchor.module_atom("Foo.Bar:baz/1")
      nil
  """
  @spec module_atom(String.t()) :: module() | nil
  def module_atom("dynamic"), do: nil
  def module_atom(""), do: nil
  def module_atom(":"), do: nil

  def module_atom(":" <> erlang_name) do
    name = strip_quotes(erlang_name)

    if name == "" or String.contains?(name, [":", "/"]),
      do: nil,
      else: String.to_atom(name)
  end

  # What `inspect/1` prints for an Elixir module: dot-separated segments,
  # each an uppercase letter then word characters. Anything else it
  # quotes (`:"Elixir.Foo.bar"`), and that goes through the Erlang branch.
  def module_atom(alias_string) do
    if String.match?(alias_string, ~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/),
      do: Module.concat([alias_string]),
      else: nil
  end

  defp at_parts(module_string, func, arity) do
    case module_atom(module_string) do
      nil -> empty()
      module -> %{module: module, mfa: {module, String.to_atom(func), arity}, instr: nil}
    end
  end

  # Quoted Erlang atoms render as :"foo bar" — strip the quotes.
  defp strip_quotes(name) do
    case name do
      <<?", inner::binary>> -> String.trim_trailing(inner, "\"")
      _ -> name
    end
  end
end
