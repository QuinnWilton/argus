-module(gleam_app).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "src/gleam_app.gleam").
-export([main/0]).

-file("src/gleam_app.gleam", 3).
-spec main() -> gleam_app@worker:pid_().
main() ->
    gleam_app@worker:start().
