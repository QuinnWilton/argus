%% `rebar3 argus`: runs the argus escript over the project rebar3 just
%% compiled, on exactly the ebins rebar3 built, and relays its report.
%%
%%     {plugins, [rebar3_argus]}.
%%     {argus, [{analyses, [coupling, mailbox]}]}.       % argus's own configuration
%%     {argus_plugin, [{version, "0.20.0"}, {fail_above, 0}]}.
%%     {provider_hooks, [{post, [{compile, argus}]}]}.  % optional: after every compile
%%
%% `rebar3 argus [--analyses A,B] [--all] [--format text|json]
%% [--fail-above N] [--include-deps] [--force]`. More findings than
%% fail_above (the flag, else {argus_plugin, [{fail_above, N}]}) fail
%% the command; any other failure of the escript is an error naming its
%% exit status. The project's apps are one program; its dependencies'
%% ebins are passed for their specs, and analyzed with --include-deps.
%%
%% The escript is found through {argus_plugin, [{escript, Path}]}, then
%% $ARGUS_ESCRIPT, then {argus_plugin, [{version, V}]} (downloaded once
%% from argus's GitHub release, checked against its published sha256, or
%% {sha256, Hex} when given), then `argus` on PATH, then
%% ~/.mix/escripts/argus. argus's own configuration is {argus, [...]} in
%% rebar.config, which the escript reads.
-module(rebar3_argus_prv).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, argus).
-define(RELEASES, "https://github.com/QuinnWilton/argus/releases/download/v").

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
        {name, ?PROVIDER},
        {module, ?MODULE},
        {bare, true},
        {deps, [compile]},
        {example, "rebar3 argus --fail-above 0"},
        {opts, opts()},
        {short_desc, "Run argus's BEAM analyses over the project"},
        {desc, "Runs the argus escript over the ebins rebar3 built (the project's apps as "
               "one program, its dependencies for their specs) and relays its report."}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

opts() ->
    [{analyses, $a, "analyses", string, "Analyses (or sets) to run, comma-separated"},
     {all, undefined, "all", boolean, "Run every analysis"},
     {format, $f, "format", string, "text (the default) or json"},
     {fail_above, undefined, "fail-above", integer, "Fail when there are more findings"},
     {include_deps, undefined, "include-deps", boolean, "Analyze the dependencies too"},
     {force, undefined, "force", boolean, "Ignore the manifest; recompute everything"}].

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, term()}.
do(State) ->
    Config = rebar_state:get(State, argus_plugin, []),
    case find_escript(Config) of
        {ok, Escript} ->
            {Opts, _} = rebar_state:command_parsed_args(State),
            relay(Escript, args(State, Config, Opts), rebar_state:dir(State), Opts, Config, State);
        {error, Reason} ->
            {error, {?MODULE, Reason}}
    end.

args(State, Config, Opts) ->
    BaseDir = rebar_dir:base_dir(State),
    Apps = [["--app", pair(App)] || App <- rebar_state:project_apps(State)],
    Deps = [["--dep", pair(Dep)] || Dep <- rebar_state:all_deps(State)],
    ["--project", "rebar3", "--root", rebar_state:dir(State),
     "--profile", filename:basename(BaseDir),
     "--state-dir", filename:join(BaseDir, "argus")]
        ++ lists:append(Apps ++ Deps)
        ++ flags(Opts, Config)
        ++ color().

pair(App) ->
    binary_to_list(rebar_app_info:name(App)) ++ "=" ++ rebar_app_info:ebin_dir(App).

flags(Opts, Config) ->
    FailAbove = proplists:get_value(fail_above, Opts, proplists:get_value(fail_above, Config)),
    lists:append(
      [["--analyses", A] || A <- [proplists:get_value(analyses, Opts)], A =/= undefined] ++
      [["--all"] || proplists:get_value(all, Opts, false)] ++
      [["--format", F] || F <- [proplists:get_value(format, Opts)], F =/= undefined] ++
      [["--fail-above", integer_to_list(FailAbove)] || is_integer(FailAbove)] ++
      [["--include-deps"] || proplists:get_value(include_deps, Opts, false)] ++
      [["--force"] || proplists:get_value(force, Opts, false)]).

%% The escript's stderr is rebar3's own; asked for color when it is a
%% terminal, since the escript sees only a pipe.
color() ->
    case io:rows() of
        {ok, _} -> ["--color", "always"];
        _ -> []
    end.

relay(Escript, Args, Root, Opts, Config, State) ->
    rebar_api:debug("argus: ~ts ~ts", [Escript, lists:join(" ", Args)]),
    Port = open_port({spawn_executable, Escript},
                     [{args, Args}, {cd, Root}, exit_status, binary, stream]),
    case collect(Port) of
        0 -> {ok, State};
        1 -> {error, {?MODULE, {findings, fail_above(Opts, Config)}}};
        Status -> {error, {?MODULE, {exit, Status}}}
    end.

collect(Port) ->
    receive
        {Port, {data, Data}} -> io:put_chars(Data), collect(Port);
        {Port, {exit_status, Status}} -> Status
    end.

fail_above(Opts, Config) ->
    proplists:get_value(fail_above, Opts, proplists:get_value(fail_above, Config)).

find_escript(Config) ->
    Home = os:getenv("HOME", ""),
    Candidates = [proplists:get_value(escript, Config), env("ARGUS_ESCRIPT")],
    case [C || C <- Candidates, C =/= undefined] of
        [Path | _] -> executable(Path);
        [] ->
            case proplists:get_value(version, Config) of
                undefined ->
                    first([os:find_executable("argus"),
                           filename:join([Home, ".mix", "escripts", "argus"])]);
                Version ->
                    download(Version, proplists:get_value(sha256, Config))
            end
    end.

env(Name) ->
    case os:getenv(Name) of
        false -> undefined;
        "" -> undefined;
        Value -> Value
    end.

executable(Path) ->
    case filelib:is_regular(Path) of
        true -> {ok, Path};
        false -> {error, {no_escript, Path}}
    end.

first(Paths) ->
    case [P || P <- Paths, P =/= false, filelib:is_regular(P)] of
        [Path | _] -> {ok, Path};
        [] -> {error, not_found}
    end.

%% argus's release escript for Version, downloaded once into the user's
%% cache and checked against the release's sha256 (or the one pinned).
download(Version, Pinned) ->
    Dir = filename:join([cache_home(), "argus", "escripts", Version]),
    Escript = filename:join(Dir, "argus"),
    case filelib:is_regular(Escript) of
        true -> {ok, Escript};
        false -> fetch(Version, Pinned, Dir, Escript)
    end.

fetch(Version, Pinned, Dir, Escript) ->
    _ = application:ensure_all_started(ssl),
    _ = application:ensure_all_started(inets),
    Url = ?RELEASES ++ Version ++ "/argus",
    case fetch_checked(Url, Pinned) of
        {ok, Bin} ->
            Tmp = Escript ++ "." ++ os:getpid(),
            case install(Dir, Tmp, Escript, Bin) of
                ok -> {ok, Escript};
                {error, Reason} -> {error, {download, Url, Reason}}
            end;
        {error, Reason} ->
            {error, {download, Url, Reason}}
    end.

fetch_checked(Url, Pinned) ->
    case {http_get(Url), expected(Pinned, Url ++ ".sha256")} of
        {{ok, Bin}, {ok, Expected}} ->
            Actual = string:lowercase(binary:encode_hex(crypto:hash(sha256, Bin))),
            case Actual of
                Expected -> {ok, Bin};
                _ -> {error, {sha256, Expected, Actual}}
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

%% Written beside its name and renamed into place: a run that dies
%% midway leaves no escript half written.
install(Dir, Tmp, Escript, Bin) ->
    case filelib:ensure_path(Dir) of
        ok ->
            case file:write_file(Tmp, Bin) of
                ok ->
                    ok = file:change_mode(Tmp, 8#755),
                    file:rename(Tmp, Escript);
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

expected(undefined, Url) ->
    case http_get(Url) of
        {ok, Body} -> {ok, string:lowercase(hd(string:lexemes(Body, " \n")))};
        Error -> Error
    end;
expected(Pinned, _Url) ->
    {ok, string:lowercase(iolist_to_binary(Pinned))}.

http_get(Url) ->
    Ssl = [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
           {customize_hostname_check,
            [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
    case httpc:request(get, {Url, []}, [{ssl, Ssl}, {autoredirect, true}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} -> {ok, Body};
        {ok, {{_, Code, _}, _, _}} -> {error, {http, Code}};
        {error, Reason} -> {error, Reason}
    end.

cache_home() ->
    case env("XDG_CACHE_HOME") of
        undefined -> filename:join(os:getenv("HOME", ""), ".cache");
        Dir -> Dir
    end.

-spec format_error(term()) -> iolist().
format_error({findings, FailAbove}) ->
    io_lib:format("argus found more than ~p findings (fail_above)", [FailAbove]);
format_error({exit, Status}) ->
    io_lib:format("argus exited with status ~p: see its report above", [Status]);
format_error(not_found) ->
    "the argus escript was not found: set {argus_plugin, [{escript, Path}]} or "
    "{argus_plugin, [{version, V}]} in rebar.config, set ARGUS_ESCRIPT, or install it "
    "(mix escript.install hex panoptes)";
format_error({no_escript, Path}) ->
    io_lib:format("the argus escript ~ts is not a file", [Path]);
format_error({download, Url, Reason}) ->
    io_lib:format("the argus escript could not be downloaded from ~ts: ~p", [Url, Reason]);
format_error(Reason) ->
    io_lib:format("~p", [Reason]).
