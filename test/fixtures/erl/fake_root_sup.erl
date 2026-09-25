%% A supervisor keeping a table, started by fake_app, which is no Application.
-module(fake_root_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ets:new(fake_root_snapshot, [named_table, public, set]),
    {ok, {{one_for_one, 5, 10}, []}}.
