%% Calls the manager from init/1, two levels below an earlier branch.
-module(boot_nested_leaf).
-behaviour(gen_server).

-export([start_link/0, init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    Config = gen_server:call(boot_order_manager, {config, leaf}),
    {ok, Config}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
