defmodule Argus.Extractor.ShellScript do
  @moduledoc """
  Whether a literal `sh -c` script hands the positional parameters after
  it (`sh -c SCRIPT NAME ARG...`) to its commands as data, never as code.

  `System.cmd("/bin/sh", ["-c", ~s(kill -0 "$1"), "sh", pid])` runs a
  script the program wrote; `pid` reaches it as `$1`, and the shell
  expands a quoted `"$1"` into one word without parsing it again, so the
  only program that sees it is `kill`, as an argument. The same `"$1"`
  as a command word (`"$@" </dev/null &`) runs whatever the caller
  names, and handed to `eval`, `sh -c`, `python -c` or another program
  that runs its arguments it is code again.

  The check reads the script as a shell does, word by word, and is
  conservative: a construct it does not model makes the script not
  inert. The script is inert when:

  - it has no command substitution (`$(...)`, backquotes), arithmetic
    expansion, process substitution, here-document or `alias`, and no
    unbalanced quote;
  - every parameter expansion is inside double quotes, but for the
    special parameters `$?`, `$!`, `$$`, `$#` and `$-`, which hold no
    caller data;
  - every simple command that expands anything has a literal command
    word, and that word names a program that does not run its
    arguments as code (`ApiCalls.runs_arguments?/1`: no shell,
    interpreter or wrapper) and no builtin that evaluates a string,
    changes what a later command word names, or moves to another
    directory (`eval`, `exec`, `.`, `trap`, `export`, `cd`, ...);
  - an assignment that expands something assigns a lowercase name, a
    script's own variable rather than `PATH`, `IFS` or `LD_PRELOAD`.

  A simple command that expands nothing is literal, whatever it runs.
  Variables the script sets are expanded under the same rules, so a
  positional parameter copied into one stays data.
  """

  alias Argus.Extractors.ApiCalls

  # Builtins that run a string or a command named by their arguments,
  # define names later commands resolve through, or change the directory
  # a relative command word resolves in.
  @builtins ~w(eval exec . source command builtin trap alias unalias export declare typeset
               local readonly set unset hash enable cd pushd popd shopt mapfile readarray
               coproc fc getopts let [[)

  # Words that open or close a compound command: the next word is a
  # command word again.
  @reserved ~w(if then else elif fi do done while until ! { } in)

  # Constructs the check does not model.
  @unmodelled ~w(case esac select function)

  @special_params ~w(? ! $ # -)

  @typep word :: %{text: String.t(), expands: boolean(), unquoted: boolean()}
  @typep token :: {:word, word()} | :sep | :redirect

  @doc """
  Whether `script`, run as `sh -c script name arg...`, hands `arg...` to
  its commands as data on every path through it.
  """
  @spec inert_positionals?(String.t()) :: boolean()
  def inert_positionals?(script) when is_binary(script) do
    with {:ok, tokens} <- tokenize(String.to_charlist(script)) do
      tokens
      |> commands()
      |> Enum.all?(&inert_command?/1)
    else
      :error -> false
    end
  end

  # ── Commands ───────────────────────────────────────────────────────

  # The simple commands, each as {assignments, command word or nil, the
  # other words}; a redirection's target is one of the other words.
  defp commands(tokens) do
    tokens
    |> Enum.chunk_by(&(&1 == :sep))
    |> Enum.reject(&(&1 == [:sep] or Enum.all?(&1, fn t -> t == :sep end)))
    |> Enum.map(&simple/1)
  end

  defp simple(tokens), do: simple(tokens, [], nil, [])

  defp simple([], assigns, command, words), do: {assigns, command, Enum.reverse(words)}

  # A redirection's target is a word, not a command word.
  defp simple([:redirect, {:word, target} | rest], assigns, command, words),
    do: simple(rest, assigns, command, [target | words])

  defp simple([:redirect | rest], assigns, command, words),
    do: simple(rest, assigns, command, words)

  defp simple([{:word, word} | rest], assigns, nil, words) do
    cond do
      not word.expands and word.text in @reserved -> simple(rest, assigns, nil, words)
      assignment?(word) -> simple(rest, [word | assigns], nil, words)
      true -> simple(rest, assigns, word, words)
    end
  end

  defp simple([{:word, word} | rest], assigns, command, words),
    do: simple(rest, assigns, command, [word | words])

  defp assignment?(%{text: text}), do: text =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*=/

  defp inert_command?({assigns, command, words}) do
    all = assigns ++ List.wrap(command) ++ words

    cond do
      Enum.any?(all, & &1.unquoted) -> false
      Enum.any?(all, &(not &1.expands and &1.text in @unmodelled)) -> false
      Enum.any?(all, &(not &1.expands and &1.text == "alias")) -> false
      not Enum.any?(all, & &1.expands) -> true
      not Enum.all?(assigns, &own_variable?/1) -> false
      command == nil -> true
      true -> data_command?(command) and not assigns_through_printf?(command, words)
    end
  end

  # `printf -v name` assigns its output to a variable a later command
  # word may expand.
  defp assigns_through_printf?(%{text: "printf"}, words),
    do: Enum.any?(words, &String.starts_with?(&1.text, "-v"))

  defp assigns_through_printf?(_command, _words), do: false

  # An assignment that expands nothing sets a literal, wherever it goes.
  defp own_variable?(%{expands: false}), do: true
  defp own_variable?(%{text: text}), do: text =~ ~r/\A[a-z_][a-z0-9_]*=/

  defp data_command?(%{expands: true}), do: false

  defp data_command?(%{text: text}) do
    program = Path.basename(text)
    text != "" and program not in @builtins and not ApiCalls.runs_arguments?(program)
  end

  # ── Words ──────────────────────────────────────────────────────────

  @spec tokenize(charlist()) :: {:ok, [token()]} | :error
  defp tokenize(chars), do: tokens(chars, nil, [])

  defp tokens([], word, acc), do: {:ok, Enum.reverse(push(word, acc))}

  # A comment runs to the end of its line, where a word could start.
  defp tokens([?# | rest], nil, acc), do: tokens(Enum.drop_while(rest, &(&1 != ?\n)), nil, acc)

  defp tokens([c | rest], word, acc) when c in [?\s, ?\t], do: tokens(rest, nil, push(word, acc))

  defp tokens([c | rest], word, acc) when c in [?\n, ?;, ?&, ?|, ?(, ?)],
    do: tokens(rest, nil, [:sep | push(word, acc)])

  defp tokens([?<, ?< | _rest], _word, _acc), do: :error
  defp tokens([c, ?( | _rest], _word, _acc) when c in [?<, ?>], do: :error

  defp tokens([c | rest], word, acc) when c in [?<, ?>] do
    # A word of digits right before the operator is the descriptor it
    # redirects, not a word of the command.
    acc = if fd?(word), do: acc, else: push(word, acc)

    rest
    |> Enum.drop_while(&(&1 in [?<, ?>, ?&, ?|]))
    |> tokens(nil, [:redirect | acc])
  end

  defp tokens([?` | _rest], _word, _acc), do: :error

  defp tokens([?' | rest], word, acc) do
    case Enum.split_while(rest, &(&1 != ?')) do
      {text, [?' | rest]} -> tokens(rest, append(word, text, false, false), acc)
      _unclosed -> :error
    end
  end

  defp tokens([?" | rest], word, acc) do
    with {:ok, word, rest} <- quoted(rest, word || new_word()), do: tokens(rest, word, acc)
  end

  defp tokens([?\\, c | rest], word, acc), do: tokens(rest, append(word, [c], false, false), acc)
  defp tokens([?\\], _word, _acc), do: :error

  defp tokens([?$ | rest], word, acc) do
    case parameter(rest) do
      {:ok, nil, rest} ->
        tokens(rest, append(word, [?$], false, false), acc)

      {:ok, name, rest} ->
        tokens(rest, append(word, [?$], true, name not in @special_params), acc)

      :error ->
        :error
    end
  end

  defp tokens([c | rest], word, acc), do: tokens(rest, append(word, [c], false, false), acc)

  # Inside double quotes: an expansion is quoted, a backslash escapes,
  # and a command substitution is code.
  defp quoted([?" | rest], word), do: {:ok, word, rest}
  defp quoted([?` | _rest], _word), do: :error
  defp quoted([?\\, c | rest], word), do: quoted(rest, append(word, [c], false, false))

  defp quoted([?$ | rest], word) do
    case parameter(rest) do
      {:ok, name, rest} -> quoted(rest, append(word, [?$], name != nil, false))
      :error -> :error
    end
  end

  defp quoted([c | rest], word), do: quoted(rest, append(word, [c], false, false))
  defp quoted([], _word), do: :error

  # The parameter a `$` expands: `${name}`, a name, a digit, or a special
  # parameter. `$(` and `$((` are substitutions, which are code.
  defp parameter([?( | _rest]), do: :error
  defp parameter([?[ | _rest]), do: :error

  defp parameter([?{ | rest]) do
    case Enum.split_while(rest, &(&1 != ?})) do
      {name, [?} | rest]} ->
        if Enum.all?(name, &name_char?/1) and name != [],
          do: {:ok, List.to_string(name), rest},
          else: :error

      _unclosed ->
        :error
    end
  end

  defp parameter([c | rest]) when c in ?0..?9, do: {:ok, <<c>>, rest}
  defp parameter([c | rest]) when c in [?@, ?*, ?#, ??, ?!, ?$, ?-], do: {:ok, <<c>>, rest}

  defp parameter([c | _] = chars) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {name, rest} = Enum.split_while(chars, &name_char?/1)
    {:ok, List.to_string(name), rest}
  end

  # A `$` before anything else is a literal dollar sign.
  defp parameter(rest), do: {:ok, nil, rest}

  defp name_char?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_

  defp new_word, do: %{text: "", expands: false, unquoted: false}

  defp append(nil, chars, expands, unquoted), do: append(new_word(), chars, expands, unquoted)

  defp append(word, chars, expands, unquoted) do
    %{
      text: word.text <> List.to_string(chars),
      expands: word.expands or expands,
      unquoted: word.unquoted or unquoted
    }
  end

  defp push(nil, acc), do: acc
  defp push(word, acc), do: [{:word, word} | acc]

  defp fd?(%{text: text, expands: false}), do: text =~ ~r/\A[0-9]+\z/
  defp fd?(_word), do: false
end
