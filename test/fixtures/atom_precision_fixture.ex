defmodule Argus.Test.Fixtures.AtomPrecision do
  # Documented: its exports are a library's API, which callers outside the
  # program call whatever the library's own calls pass (`public_token/1`).
  @moduledoc "Atom-making functions a library documents for its callers."
  @colours [:black, :red, :green, :yellow, :blue, :magenta, :cyan, :white]

  def ansi(n) when n in 90..97, do: String.to_atom("light_#{Enum.at(@colours, n - 90)}")
  def table(n), do: String.to_atom("light_#{Enum.at(@colours, n)}")
  def table_fetch(n), do: String.to_atom("light_#{Enum.fetch!(@colours, n)}")
  def table_nth(n), do: String.to_atom("light_#{:lists.nth(n, @colours)}")
  def table_default(n), do: String.to_atom("light_#{Enum.at(@colours, n, :default)}")

  def unknown_default(n, other),
    do: String.to_atom("light_#{Enum.at(@colours, n, other)}")

  def runtime_table(colours, n), do: String.to_atom("light_#{Enum.at(colours, n)}")

  def table_one_branch(n, other, flag) do
    value = if flag, do: Enum.at(@colours, n), else: other
    String.to_atom("light_#{value}")
  end

  # Each alternative is one token. Joining character domains first would
  # invent 11^3 combinations and exceed the atom vocabulary limit.
  def token(a, b, c)
      when (a == ?a and b == ?a and c == ?a) or
             (a == ?b and b == ?b and c == ?b) or
             (a == ?c and b == ?c and c == ?c) or
             (a == ?d and b == ?d and c == ?d) or
             (a == ?e and b == ?e and c == ?e) or
             (a == ?f and b == ?f and c == ?f) or
             (a == ?g and b == ?g and c == ?g) or
             (a == ?h and b == ?h and c == ?h) or
             (a == ?i and b == ?i and c == ?i) or
             (a == ?j and b == ?j and c == ?j) or
             (a == ?k and b == ?k and c == ?k),
      do: List.to_atom([a, b, c])

  def independent_token(a, b, c) when a in ?a..?k and b in ?a..?k and c in ?a..?k,
    do: List.to_atom([a, b, c])

  def partial_token(a, b, c, flag) when (a == ?a and b == ?a and c == ?a) or flag,
    do: List.to_atom([a, b, c])

  def numeric_equivalence(n, input) when n == 1 do
    value = if n === 1.0, do: input, else: "fixed"
    String.to_atom(value)
  end

  def loose_numeric_product(a, b, c, d, e, f, g, h, i, j, k)
      when a == 1 and b == 1 and c == 1 and d == 1 and e == 1 and f == 1 and g == 1 and h == 1 and
             i == 1 and j == 1 and k == 1,
      do: String.to_atom("#{a}_#{b}_#{c}_#{d}_#{e}_#{f}_#{g}_#{h}_#{i}_#{j}_#{k}")

  def loose_numeric_small(a, b, c, d, e)
      when a == 1 and b == 1 and c == 1 and d == 1 and e == 1,
      do: String.to_atom("#{a}_#{b}_#{c}_#{d}_#{e}")

  def exact_numeric_product(a, b, c, d, e, f, g, h, i, j, k)
      when a === 1 and b === 1 and c === 1 and d === 1 and e === 1 and f === 1 and g === 1 and
             h === 1 and i === 1 and j === 1 and k === 1,
      do: String.to_atom("#{a}_#{b}_#{c}_#{d}_#{e}_#{f}_#{g}_#{h}_#{i}_#{j}_#{k}")

  def loose_numeric_list(value) when value == [65], do: List.to_atom(value)
  def exact_numeric_list(value) when value === [65], do: List.to_atom(value)

  def punctuation(which) do
    case which do
      :open -> private_token(~c"[")
      :close -> private_token(~c"]")
    end
  end

  defp private_token(value), do: private_reversed(:lists.reverse(value))
  defp private_reversed(value), do: List.to_atom(value)

  def enum_punctuation(char) when char in [?!, ?$, ?(, ?), ?:, ?=, ?@, ?[, ?], ?{, ?|, ?}],
    do: enum_token([char])

  def enum_ellipsis, do: enum_token(~c"...")
  defp enum_token(value), do: List.to_atom(Enum.reverse(value))

  def mixed_enum_caller(char, input, flag) when char in [?[, ?]] do
    value = if flag, do: [char], else: input
    mixed_enum_token(value)
  end

  defp mixed_enum_token(value), do: List.to_atom(Enum.reverse(value))

  def unknown_enum_tail(char, tail) when char in [?[, ?]],
    do: List.to_atom(Enum.reverse([char | tail]))

  def improper_enum_tail(char) when char in [?[, ?]],
    do: List.to_atom(Enum.reverse([char | :tail]))

  @reverse_alphabet Enum.to_list(?A..?Z) ++ Enum.to_list(?a..?f)
  @oversized_alphabet @reverse_alphabet ++ [?g]

  def enum_budget_boundary(a, b) when a in @reverse_alphabet and b in @reverse_alphabet,
    do: List.to_atom(Enum.reverse([a, b]))

  def oversized_enum_product(a, b) when a in @oversized_alphabet and b in @oversized_alphabet,
    do: List.to_atom(Enum.reverse([a, b]))

  defmodule DynamicEnumerable do
    @moduledoc false
    defstruct []
  end

  defimpl Enumerable, for: DynamicEnumerable do
    def reduce(_value, acc, fun),
      do: Enumerable.List.reduce(Process.get(:characters, []), acc, fun)

    def count(_value), do: {:error, __MODULE__}
    def member?(_value, _element), do: {:error, __MODULE__}
    def slice(_value), do: {:error, __MODULE__}
  end

  def custom_enumerable(value) when value == %DynamicEnumerable{},
    do: List.to_atom(Enum.reverse(value))

  defimpl String.Chars, for: DynamicEnumerable do
    def to_string(_value), do: Process.get(:atom_name, "default")
  end

  def custom_string_chars(value) when value == %DynamicEnumerable{},
    do: String.to_atom(to_string(value))

  def converted_binary(value) when value in ["RED", "BLUE"],
    do: String.to_atom("prefix_#{String.downcase(value)}")

  def binary_atom_name(value) when is_atom(value) do
    <<char::utf8, rest::binary>> = Atom.to_string(value)
    String.to_atom("#{String.downcase(<<char::utf8>>)}#{rest}")
  end

  def binary_or_custom(value, flag) when value == %DynamicEnumerable{} do
    selected = if flag, do: String.downcase("A"), else: value
    String.to_atom("#{selected}")
  end

  def mapped_delimiter(value) when value in [?(, ?[, ?"],
    do: List.to_atom([closing_delimiter(value)])

  defp closing_delimiter(?(), do: ?)
  defp closing_delimiter(?[), do: ?]
  defp closing_delimiter(value), do: value

  def unknown_delimiter(value), do: List.to_atom([unrestricted_delimiter(value)])
  defp unrestricted_delimiter(?(), do: ?)
  defp unrestricted_delimiter(value), do: value

  def rescued_result(value, flag) do
    selected =
      try do
        normal_result(value, flag)
      catch
        :throw, caught -> caught
      end

    String.to_atom(selected)
  end

  defp normal_result(value, true), do: throw(value)
  defp normal_result(_value, false), do: "fixed"

  def mixed_caller(which, input) do
    case which do
      :fixed -> mixed_token(~c"[")
      :unknown -> mixed_token(input)
    end
  end

  defp mixed_token(value), do: List.to_atom(value)

  def capture_token do
    captured_token(~c"[")
    &captured_token/1
  end

  defp captured_token(value), do: List.to_atom(value)

  def public_caller, do: public_token(~c"[")
  def public_token(value), do: List.to_atom(value)

  def repeated_token(count), do: accumulating_token(~c"x", count)
  defp accumulating_token(_value, 0), do: :done

  defp accumulating_token(value, count) do
    _ = List.to_atom(value)
    accumulating_token([?x | value], count - 1)
  end

  defmodule ConfigPlug do
    @moduledoc false
    @behaviour Plug
    def init(opts), do: opts
    def call(conn, opts), do: {conn, suffix(opts.subject)}
    defp suffix(subject) when is_atom(subject), do: String.to_atom("current_#{subject}")
  end

  defmodule RequestPlug do
    @moduledoc false
    @behaviour Plug
    def init(opts), do: opts
    def call(conn, opts), do: {opts, suffix(conn.params.subject)}
    defp suffix(subject) when is_atom(subject), do: String.to_atom("current_#{subject}")
  end
end
