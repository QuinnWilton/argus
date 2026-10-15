defmodule Argus.Extractor.ShellScriptTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.Extractor.ShellScript

  # argus's own cargo guard: it runs "$@" as a command.
  @guard """
  exec 3<&0
  "$@" </dev/null &
  child=$!
  ( while read -r _ <&3; do :; done
    pkill -TERM -P "$child" 2>/dev/null
    kill -TERM "$child" 2>/dev/null ) &
  watcher=$!
  wait "$child"
  status=$?
  kill "$watcher" 2>/dev/null
  exit "$status"
  """

  describe "positional parameters as data" do
    test "quoted arguments of programs that run none of them" do
      for script <- [
            ~S(kill -0 "$1" 2>/dev/null),
            ~S(stat -c %s "$1" && wc -l "$1"),
            ~S(for f in "$@"; do rm -- "$f"; done),
            ~S(x="$1"; echo "$x"),
            ~S(a=b; echo "${1}"),
            ~S(echo '$1' \$1 "$1"),
            ~S(exec 3<&0; cat "$1" >&2),
            "make"
          ] do
        assert ShellScript.inert_positionals?(script), script
      end
    end
  end

  describe "positional parameters as code" do
    test "a command word, an evaluating builtin, a wrapper or an interpreter" do
      for script <- [
            @guard,
            ~S(eval "$1"),
            ~S(exec "$1"),
            ~S(nohup "$1" &),
            ~S(env "$1"),
            ~S(xargs "$1"),
            ~S(python3 -c "$1"),
            ~S(sh -c "$1"),
            ~S(trap "$1" EXIT),
            ~S(x="$1"; $x),
            ~S|f() { eval "$1"; }; f "$1"|
          ] do
        refute ShellScript.inert_positionals?(script), script
      end
    end

    test "unquoted, substituted, or past what the check models" do
      for script <- [
            "kill -0 $1",
            ~S|echo "$(cat "$1")"|,
            "echo `cat $1`",
            ~S(echo "${1:-x}"),
            ~S(PATH="$1" ls),
            ~S(cd "$1" && make),
            ~S(printf -v x "$1"),
            ~S(alias k=eval; k "$1"),
            ~S|case "$1" in a) ls;; esac|,
            "cat <<EOF",
            ~S(echo "unclosed)
          ] do
        refute ShellScript.inert_positionals?(script), script
      end
    end
  end

  property "a script without an expansion is inert, and an eval of a parameter is not" do
    check all(
            words <- list_of(word(), min_length: 1, max_length: 6),
            separator <- member_of([" ", "; ", " && ", "\n"])
          ) do
      script = Enum.join(words, separator)
      assert ShellScript.inert_positionals?(script)
      refute ShellScript.inert_positionals?(script <> ~S(; eval "$1"))
      refute ShellScript.inert_positionals?(~S("$1"; ) <> script)
    end
  end

  # A literal shell word: no quote, expansion, operator or reserved word.
  defp word do
    [?a..?z, ?0..?9, [?-, ?_, ?., ?/]]
    |> Enum.flat_map(&Enum.to_list/1)
    |> member_of()
    |> list_of(min_length: 1, max_length: 8)
    |> map(&List.to_string/1)
    |> filter(
      &(&1 not in ~w(if then else elif fi do done while until in case esac select function alias))
    )
  end
end
