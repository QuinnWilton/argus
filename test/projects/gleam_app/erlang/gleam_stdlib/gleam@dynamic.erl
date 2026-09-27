-module(gleam@dynamic).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch]).
-define(FILEPATH, "src/gleam/dynamic.gleam").
-export([nil/0, classify/1]).

%% A stand-in for gleam_stdlib's gleam@dynamic, as a Gleam build writes
%% it: a function named nil (its ID once came out ":gleam@dynamic:/0#N").

-file("src/gleam/dynamic.gleam", 12).
-spec nil() -> nil.
nil() ->
    nil.

-file("src/gleam/dynamic.gleam", 20).
-spec classify(any()) -> binary().
classify(Data) ->
    case Data of
        nil -> <<"Nil"/utf8>>;
        _ -> <<"Unknown"/utf8>>
    end.
