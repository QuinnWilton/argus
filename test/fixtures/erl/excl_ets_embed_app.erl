%% An Erlang application whose top supervisor keeps a public ETS table it
%% creates in init/1 (excl_ets_embed_sup). This module starts that
%% supervisor inline; a host that embeds the library instead adds it under
%% its own supervisor with supervisor:start_child/2 (excl_ets_embed_host),
%% which restarts it and loses the table: the supervisor is no
%% application root, and the worker's readers are reported.
%% Pins an exclusion no evaluation program exercises (census 2026-09-26);
%% see test/exclusions/ets_test.exs.
-module(excl_ets_embed_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) -> excl_ets_embed_sup:start_link().
stop(_State) -> ok.
