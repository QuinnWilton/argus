%% A server owning a named table with no heir: reported alone
%% ("ETS table dies with its owner"), excused as a permanent child of
%% tuple_spec_sup, whose tuple spec restarts it and the table with it.
-module(tuple_spec_first).
-behaviour(gen_server).

-export([start_link/0, init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ets:new(tuple_spec_first_tab, [named_table, public, set]),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
