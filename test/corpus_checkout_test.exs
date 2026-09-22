defmodule Argus.CorpusCheckoutTest do
  @moduledoc """
  The pure half of `Argus.Corpus`: where a pair's sides land on disk,
  with and without a `subdir:`. No cloning, no network — the corpus gate
  itself is `Argus.CorpusTest`.
  """

  use ExUnit.Case, async: true

  alias Argus.Corpus

  @pair %{
    repo: "example/firezone",
    issue: "firezone#1",
    pre: "0123456789abcdef0123456789abcdef01234567",
    finding: {:exposure, "x"}
  }

  test "a side without a sha is nil" do
    assert Corpus.checkout(@pair, :fix) == nil
  end

  test "the project is the clone unless the pair names a subdir" do
    plain = Corpus.checkout(@pair, :pre)
    assert plain.name == "firezone-0123456"
    assert plain.dir == Path.join(Corpus.root(), "firezone-0123456")
    assert Path.expand(plain.project) == Path.expand(plain.dir)

    nested = Corpus.checkout(Map.put(@pair, :subdir, "elixir"), :pre)
    assert nested.dir == plain.dir
    assert nested.project == Path.join(plain.dir, "elixir")
  end
end
