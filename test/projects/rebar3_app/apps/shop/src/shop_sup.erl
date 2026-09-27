-module(shop_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => shop_notifier, start => {shop_notifier, start_link, []}},
        #{id => shop_sonar, start => {shop_sonar, start_link, []}}
    ],
    {ok, {#{strategy => one_for_one}, Children}}.
