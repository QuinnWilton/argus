%% The pool's template child: its init asks the manager for its config,
%% which is up by then, since the manager is what starts sites.
-module(boot_order_site).
-behaviour(gen_server).

-export([start_link/1, init/1, handle_call/3, handle_cast/2]).

start_link(Name) ->
    gen_server:start_link(?MODULE, Name, []).

init(Name) ->
    Config = gen_server:call(boot_order_manager, {config, Name}),
    {ok, Config}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
