%% MongooseIM's service_domain_db: the periodic check cancels the ref it
%% keeps before re-arming, reading it with maps:get/3 in a helper, and
%% flushes a tick already delivered. The initial load, cast from init/1,
%% goes through the same function. One loop, however it is kicked.
-module(timer_loop_domain_db).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

init([]) ->
    gen_server:cast(self(), initial_loading),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(initial_loading, State) ->
    {noreply, check(State#{interval => 30000}, true)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check_for_updates, State) ->
    {noreply, check(State, false)};
handle_info(_Info, State) ->
    {noreply, State}.

check(State = #{interval := Interval}, IsInitial) ->
    maybe_cancel_timer(IsInitial, State),
    receive_all(),
    TRef = erlang:send_after(Interval, self(), check_for_updates),
    State#{check_tref => TRef}.

maybe_cancel_timer(IsInitial, State) ->
    TRef = maps:get(check_tref, State, undefined),
    case {IsInitial, TRef} of
        {true, undefined} -> ok;
        {false, _} -> erlang:cancel_timer(TRef)
    end.

receive_all() ->
    receive check_for_updates -> receive_all() after 0 -> ok end.
