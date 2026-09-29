%% mon_asks_pool's neighbour: the same registration, and a cast that
%% removes the connection from `monitors`, the store the registration
%% asks, without a demonitor. The next registration of the same pid
%% monitors it again beside the live monitor.
-module(mon_asks_pool_drops).
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2]).

-record(state, {conns = #{}, monitors = #{}}).

init([]) -> {ok, #state{}}.

handle_cast({register, Key, Pid}, #state{conns = Conns, monitors = Mons} = State) ->
    Mons2 = case maps:is_key(Pid, Mons) of
                true -> Mons;
                false -> maps:put(Pid, erlang:monitor(process, Pid), Mons)
            end,
    {noreply, State#state{conns = maps:put(Key, Pid, Conns), monitors = Mons2}};
handle_cast({forget, Pid}, #state{monitors = Mons} = State) ->
    {noreply, State#state{monitors = maps:remove(Pid, Mons)}}.

handle_call(count, _From, #state{monitors = Mons} = State) ->
    {reply, maps:size(Mons), State}.
