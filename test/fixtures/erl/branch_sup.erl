%% A supervisor nothing in view starts keeps a table in init/1: when it
%% dies the table goes, and nothing shown recreates it.
-module(branch_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ets:new(branch_snapshot, [named_table, public, set]),
    {ok, {{one_for_one, 5, 10}, []}}.
