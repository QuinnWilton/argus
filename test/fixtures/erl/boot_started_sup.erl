%% boot_starter's init/1 asks the pool for a site while the tree boots:
%% the site's init/1 then runs in the starter's turn, before the manager
%% it waits on has started.
-module(boot_started_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 5, 10},
          [{pool, {boot_order_pool_sup, start_link, []}, permanent, infinity, supervisor,
            [boot_order_pool_sup]},
           {starter, {boot_starter, start_link, []}, permanent, 5000, worker, [boot_starter]},
           {manager, {boot_order_manager, start_link, []}, permanent, 5000, worker,
            [boot_order_manager]}]}}.
