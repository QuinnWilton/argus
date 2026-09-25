%% A static child two levels down in an earlier branch still starts during
%% the boot, in its branch's turn: boot_nested_leaf's init/1 and
%% boot_nested_cont's handle_continue wait on the later manager.
-module(boot_nested_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 5, 10},
          [{mid, {boot_nested_mid, start_link, []}, permanent, infinity, supervisor,
            [boot_nested_mid]},
           {manager, {boot_order_manager, start_link, []}, permanent, 5000, worker,
            [boot_order_manager]}]}}.
