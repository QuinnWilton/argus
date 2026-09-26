%% A library module that exports an init/1 no start names and declares no
%% behaviour: it runs in whoever calls it, and is no process.
-module(bless_plain).

-export([init/1]).

init(Opts) ->
    ok = gen_server:call(bless_later, hello),
    {ok, Opts}.
