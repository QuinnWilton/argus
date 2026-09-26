%% A host that embeds the library's supervisor under its own
%% (excl_ets_embed_app has the whole shape).
-module(excl_ets_embed_host).
-export([start/1]).

start(HostSup) ->
    supervisor:start_child(HostSup, #{id => excl_ets_embed_sup,
                                      start => {excl_ets_embed_sup, start_link, []},
                                      type => supervisor}).
