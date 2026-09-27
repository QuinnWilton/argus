-module(mk_dep).

-export([work/0]).

%% A dependency erlang.mk fetched into deps/.
work() ->
    receive
        stop -> ok
    end.
