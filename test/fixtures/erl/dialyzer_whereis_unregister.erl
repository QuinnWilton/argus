%% Dialyzer's -Wrace_conditions (removed in OTP 25) had a warning the
%% PADL 2010 paper does not describe: whereis, then unregister
%% (dialyzer_races:warn_whereis_unregister). The name can go between the
%% two — its process exits, or another caller unregisters it — and
%% unregister/1 then fails with badarg. stop/1 is the race; stop_caught/1
%% takes the badarg.
-module(dialyzer_whereis_unregister).

-export([stop/1, stop_caught/1]).

stop(Name) ->
    case whereis(Name) of
        undefined -> ok;
        _Pid -> unregister(Name)
    end.

stop_caught(Name) ->
    case whereis(Name) of
        undefined ->
            ok;
        _Pid ->
            try
                unregister(Name)
            catch
                error:badarg -> ok
            end
    end.
