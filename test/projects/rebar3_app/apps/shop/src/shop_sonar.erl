-module(shop_sonar).
-behaviour(gen_server).

-export([start_link/0, ping/0]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

ping() ->
    gen_server:call(?MODULE, ping).

init([]) ->
    {ok, #{seen => 0}, {continue, register}}.

%% Registers with its sibling, which keeps it in its state.
handle_continue(register, State) ->
    shop_notifier:listen(self()),
    {noreply, State}.

handle_call(ping, _From, State) ->
    try ledger:record(ping) of
        ok -> {reply, pong, State}
    catch
        error:Reason ->
            {reply, {error, Reason}, State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({shop_event, _Event}, #{seen := Seen} = State) ->
    {noreply, State#{seen := Seen + 1}}.
