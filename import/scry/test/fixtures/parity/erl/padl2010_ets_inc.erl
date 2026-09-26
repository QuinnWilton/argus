%% PADL 2010, Fig. 2, left: "a made up example of Erlang code which
%% contains an ETS-related race condition". The table is unnamed and
%% public, created in run/0 and reached by ets_inc/2 only through the
%% closure handed to the processes run/0 spawns. compute_inc/0 and
%% spawn_some_processes/1 are the figure's undefined helpers.
-module(padl2010_ets_inc).

-export([run/0]).

run() ->
    Tab = ets:new(some_tab_name, [public]),
    Inc = compute_inc(),
    Fun = fun () -> ets_inc(Tab, Inc) end,
    spawn_some_processes(Fun).

ets_inc(Tab, Inc) ->
    case ets:lookup(Tab, some_key) of
        [] ->
            ets:insert(Tab, {some_key, Inc});
        [{some_key, OldValue}] ->
            NewValue = OldValue + Inc,
            ets:insert(Tab, {some_key, NewValue})
    end.

compute_inc() -> 1.

spawn_some_processes(Fun) ->
    [spawn(Fun) || _ <- lists:seq(1, 10)],
    ok.
