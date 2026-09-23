%% Christakis and Sagonas, "Static Detection of Race Conditions in
%% Erlang", PADL 2010, Fig. 1: a function manipulating the process
%% registry which contains a race condition. The figure's `...` are
%% filled with the least code that compiles; `spawn(...)` is a process
%% that waits to be told to stop.
-module(padl2010_proc_reg).

-export([proc_reg/1]).

proc_reg(Name) ->
    case whereis(Name) of
        undefined ->
            Pid = spawn(fun wait/0),
            register(Name, Pid);
        _Pid -> % already
            true % registered
    end.

wait() ->
    receive
        stop -> ok
    end.
