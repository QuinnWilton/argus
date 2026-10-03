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

  test "finding selectors distinguish a corrected function from another affected entry" do
    pair = Map.merge(@pair, %{module: "Example", function: {:decode, 2}})
    finding = %{analysis: :exposure, title: "x", module: Example, mfa: {Example, :decode, 2}}

    assert Corpus.present?(%{findings: [finding]}, pair)
    refute Corpus.present?(%{findings: [%{finding | mfa: {Example, :delegate, 2}}]}, pair)
    refute Corpus.present?(%{findings: [%{finding | mfa: {Example, :decode, 1}}]}, pair)
    refute Corpus.present?(%{findings: [%{finding | module: Other}]}, pair)
    refute Corpus.present?(%{findings: [Map.delete(finding, :mfa)]}, pair)
    assert Corpus.present?(%{findings: [%{finding | mfa: nil}]}, Map.delete(pair, :function))
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

  test "each tree is analyzed once, under the first pair naming it, in pair order" do
    fixed = Map.put(@pair, :fix, "fedcba9876543210fedcba9876543210fedcba98")
    again = %{fixed | issue: "firezone#2", finding: {:exposure, "y"}}
    other = %{@pair | repo: "example/oban", issue: "oban#3"}

    assert [
             {%{name: "firezone-0123456"}, ^fixed, :pre},
             {%{name: "firezone-fedcba9"}, ^fixed, :fix},
             {%{name: "oban-0123456"}, ^other, :pre}
           ] = Corpus.checkouts([fixed, again, other])
  end

  test "a pair's toolchain leads the compile's PATH, with its own MIX_HOME" do
    assert {"MIX_ENV", "dev"} in Corpus.compile_env(@pair)
    refute List.keymember?(Corpus.compile_env(@pair), "PATH", 0)

    env = Corpus.compile_env(Map.merge(@pair, %{otp: "27.3.3", elixir: "1.18.3-otp-27"}))
    {"PATH", path} = List.keyfind(env, "PATH", 0)

    assert [elixir, erlang | _] = String.split(path, ":")
    assert elixir == Path.expand("~/.asdf/installs/elixir/1.18.3-otp-27/bin")
    assert erlang == Path.expand("~/.asdf/installs/erlang/27.3.3/bin")
    assert {"MIX_HOME", Path.expand("~/.asdf/installs/elixir/1.18.3-otp-27/.mix")} in env
    assert {"ASDF_ERLANG_VERSION", "27.3.3"} in env
  end

  test "a tree that names no toolchain is buildable anywhere" do
    assert Corpus.unbuildable(@pair) == nil
  end

  test "a tree not compiled here, whose toolchain is not installed, names what installs it" do
    pair = Map.merge(@pair, %{otp: "0.0.0-absent", elixir: "0.0.0-absent-otp-0"})

    assert Corpus.unbuildable(pair) ==
             "firezone#1 needs Erlang/OTP 0.0.0-absent (`asdf install erlang 0.0.0-absent`)" <>
               " and Elixir 0.0.0-absent-otp-0 (`asdf install elixir 0.0.0-absent-otp-0`)"

    assert {:skip, "firezone-0123456 needs Erlang/OTP 0.0.0-absent" <> _} =
             Corpus.ensure(pair, :pre)
  end

  describe "a repository" do
    @describetag :tmp_dir

    test "that cannot be fetched names why, when a tree is not checked out here", %{
      tmp_dir: tmp
    } do
      url = "file://" <> Path.join(tmp, "gone.git")
      pair = %{@pair | repo: url, issue: "gone#1"}

      assert "gone#1: " <> reason = Corpus.unfetchable(pair)

      assert reason =~
               ~r/^#{Regex.escape(url)} cannot be fetched, and is not checked out here \(fatal: /

      # Fetching it is a skip, and leaves nothing behind.
      assert {:skip, "gone.git-0123456: " <> ^reason} = Corpus.ensure(pair, :pre)
      refute File.exists?(Corpus.checkout(pair, :pre).dir)
    end

    test "that answers can be fetched", %{tmp_dir: tmp} do
      repo = Path.join(tmp, "here.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", repo])

      assert Corpus.unfetchable(%{@pair | repo: "file://" <> repo}) == nil
    end
  end

  test "a pair's env overrides the clean environment, MIX_ENV included" do
    env = Corpus.compile_env(Map.put(@pair, :env, %{"MIX_ENV" => "prod", "PROFILE" => "p"}))

    assert {"MIX_ENV", "prod"} in env
    refute {"MIX_ENV", "dev"} in env
    assert {"PROFILE", "p"} in env
  end

  test "a checkout carries the app a pair names" do
    assert %{app: "emqx_modules"} = Corpus.checkout(Map.put(@pair, :app, "emqx_modules"), :pre)
    assert %{app: nil} = Corpus.checkout(@pair, :pre)
  end
end
