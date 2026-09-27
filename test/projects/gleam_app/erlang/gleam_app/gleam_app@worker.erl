-module(gleam_app@worker).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "src/gleam_app/worker.gleam").
-export([start/0]).
-export_type([pid_/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

-type pid_() :: any().

-file("src/gleam_app/worker.gleam", 16).
-spec loop() -> nil.
loop() ->
    loop().

-file("src/gleam_app/worker.gleam", 10).
?DOC(" Starts a process nothing links to or monitors.\n").
-spec start() -> pid_().
start() ->
    Pid = erlang:spawn(fun() -> loop() end),
    erlang:send(Pid, nil),
    Pid.
