%% A one_for_one supervisor whose static children start with it.
-module(boot_nested_mid).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 5, 10},
          [{leaf, {boot_nested_leaf, start_link, []}, permanent, 5000, worker, [boot_nested_leaf]},
           {cont, {boot_nested_cont, start_link, []}, permanent, 5000, worker, [boot_nested_cont]}]}}.
