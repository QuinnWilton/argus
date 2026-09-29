%% hackney_pool's register_h2 (quiet): a registration monitors the
%% connection only where `monitors` lacks it, and keeps the ref there;
%% the pid is kept in `conns` too. A checkout that finds the connection
%% dead removes it from `conns` and keeps the monitor: the next
%% registration of the same pid asks `monitors`, which still holds it, and
%% takes no second monitor. The connection's :DOWN forgets both.
-module(mon_asks_pool).
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {conns = #{}, monitors = #{}}).

init([]) -> {ok, #state{}}.

handle_cast({register, Key, Pid}, #state{conns = Conns, monitors = Mons} = State) ->
    Mons2 = case maps:is_key(Pid, Mons) of
                true -> Mons;
                false -> maps:put(Pid, erlang:monitor(process, Pid), Mons)
            end,
    {noreply, State#state{conns = maps:put(Key, Pid, Conns), monitors = Mons2}}.

handle_call({checkout, Key}, _From, #state{conns = Conns} = State) ->
    case maps:get(Key, Conns, undefined) of
        undefined ->
            {reply, none, State};
        Pid ->
            case erlang:is_process_alive(Pid) of
                true -> {reply, {ok, Pid}, State};
                false -> {reply, none, State#state{conns = maps:remove(Key, Conns)}}
            end
    end.

handle_info({'DOWN', _Ref, process, Pid, _}, #state{conns = Conns, monitors = Mons} = State) ->
    Conns2 = maps:filter(fun(_K, P) -> P =/= Pid end, Conns),
    {noreply, State#state{conns = Conns2, monitors = maps:remove(Pid, Mons)}}.
