%% A declared supervisor over a server that declares no behaviour
%% (bless_server) and a later sibling it calls from init/1.
-module(bless_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 1, 5}, [worker(bless_server), worker(bless_later)]}}.

worker(Mod) ->
    {Mod, {Mod, start_link, []}, permanent, 5000, worker, [Mod]}.
