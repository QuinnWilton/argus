%% A start in another module names bless_worker the callback module of a
%% gen_server; bless_worker declares nothing.
-module(bless_starter).

-export([start_worker/0]).

start_worker() ->
    gen_server:start_link(bless_worker, [], []).
