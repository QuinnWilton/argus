%% Started by dual_app's start/2 and by outer_sup as a transient child.
-module(dual_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ets:new(dual_snapshot, [named_table, public, set]),
    {ok, {{one_for_one, 5, 10}, []}}.
