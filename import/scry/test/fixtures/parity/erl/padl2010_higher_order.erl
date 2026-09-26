%% PADL 2010, Sect. 4.2: "the case of unknown higher-order calls, as in
%% the code on the right where the Fun(N) call is a call to some unknown
%% closure". Ignoring the call "gives an analysis which is sound for
%% defect detection" — the setting the paper evaluated, and argus's.
%%
%% foo/3 is the paper's code (its `...` dropped). known/1 is the same
%% decision with the write behind a call argus can see, so it meets there.
%% unrelated/2 has the paper's other filter: whereis(N), register(M, ...)
%% — "If AN ∩ AM = ∅ then all these race conditions are clearly false
%% alarms"; with nothing known of N and M, argus stays quiet.
-module(padl2010_higher_order).

-export([foo/3, call_foo/0, known/1, unrelated/2]).

foo(Fun, N, M) ->
    case whereis(N) of
        undefined ->
            Fun(M);
        _Pid ->
            ok
    end.

call_foo() ->
    foo(fun register_self/1, gazonk, gazonk).

known(N) ->
    case whereis(N) of
        undefined -> register_self(N);
        _Pid -> ok
    end.

unrelated(N, M) ->
    case whereis(N) of
        undefined -> register_self(M);
        _Pid -> ok
    end.

register_self(Name) ->
    register(Name, self()).
