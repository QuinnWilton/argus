%% A table read from outside its owner, inside an Erlang catch and not.
%%
%% `catch Expr` takes every class, the badarg a gone table raises among
%% them: lookup/1 turns the restart window into a result, peek/1 crashes
%% its caller in it.
-module(ets_catch_reader).
-behaviour(gen_server).
-export([start_link/0, lookup/1, peek/1]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

lookup(Key) ->
    case catch ets:lookup(?MODULE, Key) of
        [{_, Value}] -> Value;
        _ -> undefined
    end.

peek(Key) ->
    ets:lookup(?MODULE, Key).

init([]) ->
    ets:new(?MODULE, [named_table, protected, set]),
    {ok, nil}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.
