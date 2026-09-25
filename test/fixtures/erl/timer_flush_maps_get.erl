%% A periodic check whose helper cancels the ref it reads with
%% maps:get/3 and re-arms, with no flush anywhere: a tick delivered
%% before the cancel is handled as the next one. The cancel is the
%% field's (timer_loop_domain_db flushes beside the same call).
-module(timer_flush_maps_get).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

init([]) ->
    {ok, #{interval => 30000}}.

handle_call(reset, _From, State) ->
    {reply, ok, rearm(State)}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check, State) ->
    {noreply, rearm(State)};
handle_info(_Info, State) ->
    {noreply, State}.

rearm(State = #{interval := Interval}) ->
    cancel(State),
    TRef = erlang:send_after(Interval, self(), check),
    State#{tref => TRef}.

cancel(State) ->
    case maps:get(tref, State, undefined) of
        undefined -> ok;
        TRef -> erlang:cancel_timer(TRef)
    end.
