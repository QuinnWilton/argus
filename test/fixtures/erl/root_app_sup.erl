%% The application's root supervisor keeps a table in init/1 so it
%% outlives the children it restarts (partisan_sup's membership
%% snapshot): it dies only with the application.
-module(root_app_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ets:new(root_app_snapshot, [named_table, public, set]),
    {ok, {{one_for_one, 5, 10}, []}}.
