-module(probe_r2_g5_logmacro).
-export([apply_and_log/2, apply_entry/2]).

%% A "do it and log it, never crash" macro: the preprocessor gives the
%% whole expansion the line of its use, so the work and the log call
%% share a line. A crash in apply_entry/2 is swallowed.
-define(LOGGED(Expr), try R__ = Expr, logger:info("~p", [R__]) catch _:_ -> ok end).

apply_and_log(Tab, Entry) ->
    ?LOGGED(apply_entry(Tab, Entry)).

apply_entry(Tab, #{key := K, value := V, index := I}) ->
    true = ets:insert(Tab, {K, V}),
    I + 1.
