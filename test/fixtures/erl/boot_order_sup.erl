%% Boot order: what an init meets while the tree starts. boot_order_early
%% starts before boot_order_manager and calls it from init/1, a deadlock
%% by construction; boot_order_site is the template child of
%% boot_order_pool_sup, a simple_one_for_one supervisor in an earlier
%% branch, and its init runs only when the manager asks for a site, with
%% the manager up (zotonic's z_site_sup under z_sites_sup, started by
%% z_sites_manager).
-module(boot_order_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 5, 10},
          [{early, {boot_order_early, start_link, []}, permanent, 5000, worker, [boot_order_early]},
           {pool, {boot_order_pool_sup, start_link, []}, permanent, infinity, supervisor,
            [boot_order_pool_sup]},
           {manager, {boot_order_manager, start_link, []}, permanent, 5000, worker,
            [boot_order_manager]}]}}.
