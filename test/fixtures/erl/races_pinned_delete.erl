%% OTP global's delete_node_resources/2: the pinned match
%% `[{Node, Owner}]` leaves the compiler free to hand the delete the
%% row's element it compared with Node, and it does. The delete names the
%% row the lookup found; the decision also tells its owner.
-module(races_pinned_delete).
-export([start/0, add/2, delete_node/1]).

start() -> ets:new(races_pinned_nodes, [named_table, public]).

add(Node, Owner) -> ets:insert(races_pinned_nodes, {Node, Owner}).

delete_node(Node) ->
    case ets:lookup(races_pinned_nodes, Node) of
        [] ->
            ok;
        [{Node, Owner}] ->
            true = ets:delete(races_pinned_nodes, Node),
            Owner ! node_gone,
            ok
    end.
