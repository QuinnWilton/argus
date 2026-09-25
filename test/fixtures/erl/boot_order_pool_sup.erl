%% A simple_one_for_one supervisor: its child spec is a template, and no
%% child starts with it.
-module(boot_order_pool_sup).
-behaviour(supervisor).

-export([start_link/0, start_site/1, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_site(Name) ->
    supervisor:start_child(?MODULE, [Name]).

init([]) ->
    {ok, {{simple_one_for_one, 5, 10},
          [{site, {boot_order_site, start_link, []}, temporary, 5000, worker, [boot_order_site]}]}}.
