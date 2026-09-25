%% Calls the manager from handle_continue/2, two levels below an earlier
%% branch: the continue runs while the tree still boots.
-module(boot_nested_cont).
-behaviour(gen_server).

-export([start_link/0, init/1, handle_call/3, handle_cast/2, handle_continue/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #{}, {continue, load}}.

handle_continue(load, State) ->
    Config = gen_server:call(boot_order_manager, {config, cont}),
    {noreply, maps:merge(State, Config)}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
