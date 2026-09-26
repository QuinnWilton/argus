defmodule Argus.Locate.Source.ElixirTest do
  use ExUnit.Case, async: true

  alias Argus.Locate.Source

  @moduletag :tmp_dir

  @schema """
  defmodule Shop.Account do
    use Ecto.Schema

    # The api_key is per customer.
    schema "accounts" do
      field :api_key_count, :integer
      field(:api_key, :string)
      field :api_key?, :boolean
      field :password, :string, redact: true
    end
  end
  """

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "account.ex")
    File.write!(path, @schema)
    %{path: path}
  end

  test "lands on the declaration, past comments, prefixes and lookalike atoms", %{path: path} do
    assert Source.Elixir.refine(path, 5, ":api_key") == 7
    assert Source.Elixir.refine(path, 5, ":api_key?") == 8
    assert Source.Elixir.refine(path, 5, ":api_key_count") == 6
  end

  test "searches from the anchor line, not the top of the file", %{path: path} do
    assert Source.Elixir.refine(path, 8, ":api_key") == 8
    assert Source.Elixir.refine(path, 9, ":api_key") == 9
  end

  test "keeps the bytecode anchor without a fragment, a match or a file", %{path: path} do
    assert Source.Elixir.refine(path, 5, nil) == 5
    assert Source.Elixir.refine(path, 5, ":missing") == 5
    assert Source.Elixir.refine(Path.join(path, "nope"), 5, ":api_key") == 5
  end

  test "a whole token has no identifier character on either side" do
    assert Source.Elixir.contains_token?("field :api_key, :string", ":api_key")
    assert Source.Elixir.contains_token?("[:api_key]", ":api_key")
    refute Source.Elixir.contains_token?("field :api_key_count", ":api_key")
    refute Source.Elixir.contains_token?("x::api_key", ":api_key")
    refute Source.Elixir.contains_token?("api_key", ":api_key")
  end
end
