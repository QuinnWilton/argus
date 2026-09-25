%% A named table's owner a tuple spec starts as a temporary child: not restarted, so its table stays gone.
-module(tuple_temp_owner).
-behaviour(gen_server).

-export([start_link/0, init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ets:new(tuple_temp_owner_tab, [named_table, public, set]),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
