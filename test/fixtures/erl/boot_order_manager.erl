%% Answers config requests, and starts sites once it is up.
-module(boot_order_manager).
-behaviour(gen_server).

-export([start_link/0, init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #{}}.

handle_call({config, _Name}, _From, State) ->
    {reply, #{}, State}.

handle_cast({start_site, Name}, State) ->
    {ok, _} = boot_order_pool_sup:start_site(Name),
    {noreply, State}.
