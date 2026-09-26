%% The application's root supervisor: a helper's named table it makes in
%% init/1 lives as long as the application (hackney_sup's host limits,
%% emqx_exhook_sup's metrics). A keeper its init/1 spawns and the child
%% it supervises are processes of their own, each gone and back without
%% the application.
-module(rows_root_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    rows_root_tabs:create(),
    spawn(fun() ->
        ets:new(rows_root_keeper, [named_table, public]),
        receive stop -> ok end
    end),
    {ok, {{one_for_one, 5, 10},
          [{child, {rows_root_child, start_link, []}, permanent, 5000, worker,
            [rows_root_child]}]}}.
