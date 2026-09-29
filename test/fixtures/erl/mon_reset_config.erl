%% global_group's sync: each sync monitors every peer through a fold and
%% keeps the refs in `config_check`, its one record of them. A
%% reconfiguration sets `config_check` back to undefined without a
%% demonitor: the refs are gone, the monitors stay, and the next sync
%% monitors each peer again.
-module(mon_reset_config).
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {nodes = #{}, config_check = undefined}).

init([]) -> {ok, #state{}}.

handle_call({sync, Peers}, _From, State) ->
    Session = make_ref(),
    {Nodes, Mons} =
        lists:foldl(fun(N, {Nacc, Macc}) ->
                            M = erlang:monitor(process, {mon_reset_peer, N}),
                            {Nacc#{N => syncing}, Macc#{N => M}}
                    end, {#{}, #{}}, Peers),
    {reply, ok, State#state{nodes = Nodes, config_check = {Session, Mons}}};
handle_call(reconfigure, _From, State) ->
    {reply, ok, State#state{nodes = #{}, config_check = undefined}}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({'DOWN', Mon, process, {mon_reset_peer, N}, _},
            #state{config_check = {Session, Mons}} = State) ->
    case maps:take(N, Mons) of
        {Mon, Rest} when map_size(Rest) == 0 ->
            {noreply, State#state{config_check = undefined}};
        {Mon, Rest} ->
            {noreply, State#state{config_check = {Session, Rest}}};
        _ ->
            {noreply, State}
    end.
