-module(ledger).

-export([record/1, record_async/1, wait/0, version/0]).

record(Event) ->
    telemetry:execute([ledger, record], #{count => 1}, #{event => Event}),
    shop_notifier:notify({recorded, Event}).

%% A process nobody monitors or links, that nothing waits for.
record_async(Event) ->
    Parent = self(),
    spawn(fun() -> Parent ! {recorded, record(Event)} end),
    ok.

wait() ->
    receive
        {done, Value} ->
            Value
    end.

%% A function only the project's telemetry has.
version() ->
    telemetry:fixture_version().
