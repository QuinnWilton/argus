-module(s2c_catch_many).
-export([safe_call/2]).
safe_call(Pid, Msg) ->
    try gen_statem:call(Pid, Msg, 1000)
    catch
        exit:{noproc, _} -> {error, closed};
        exit:{normal, _} -> {error, closed};
        exit:{shutdown, _} -> {error, closed}
    end.
