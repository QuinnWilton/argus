# Eight modules whose sinks no request reaches, as the unsafe_input
# extractors see them (logflare 54e9a38's deps and its own Ecto.Term,
# supavisor a8463de, OTP 28.2's kernel): raw rows of the relations
# Argus.Priors.Questions.ValueSource reads, decoded by the test.
%{
  function_def: [
    [":erl_boot_server:add_slave/1", ":erl_boot_server", "add_slave", "1", "1"],
    [":erl_boot_server:add_subnet/2", ":erl_boot_server", "add_subnet", "2", "1"],
    [":erl_boot_server:boot_accept/3", ":erl_boot_server", "boot_accept", "3", "1"],
    [":erl_boot_server:boot_init/1", ":erl_boot_server", "boot_init", "1", "1"],
    [":erl_boot_server:boot_loop/2", ":erl_boot_server", "boot_loop", "2", "0"],
    [":erl_boot_server:boot_main/1", ":erl_boot_server", "boot_main", "1", "0"],
    [":erl_boot_server:boot_main/3", ":erl_boot_server", "boot_main", "3", "0"],
    [":erl_boot_server:check_arg/1", ":erl_boot_server", "check_arg", "1", "0"],
    [":erl_boot_server:check_arg/2", ":erl_boot_server", "check_arg", "2", "0"],
    [":erl_boot_server:code_change/3", ":erl_boot_server", "code_change", "3", "1"],
    [":erl_boot_server:delete_slave/1", ":erl_boot_server", "delete_slave", "1", "1"],
    [":erl_boot_server:delete_subnet/2", ":erl_boot_server", "delete_subnet", "2", "1"],
    [":erl_boot_server:handle_call/3", ":erl_boot_server", "handle_call", "3", "1"],
    [":erl_boot_server:handle_cast/2", ":erl_boot_server", "handle_cast", "2", "1"],
    [":erl_boot_server:handle_command/3", ":erl_boot_server", "handle_command", "3", "0"],
    [":erl_boot_server:handle_info/2", ":erl_boot_server", "handle_info", "2", "1"],
    [":erl_boot_server:init/1", ":erl_boot_server", "init", "1", "1"],
    [":erl_boot_server:int16/1", ":erl_boot_server", "int16", "1", "0"],
    [":erl_boot_server:member_address/2", ":erl_boot_server", "member_address", "2", "0"],
    [":erl_boot_server:module_info/0", ":erl_boot_server", "module_info", "0", "1"],
    [":erl_boot_server:module_info/1", ":erl_boot_server", "module_info", "1", "1"],
    [":erl_boot_server:send_file_result/3", ":erl_boot_server", "send_file_result", "3", "0"],
    [":erl_boot_server:send_result/2", ":erl_boot_server", "send_result", "2", "0"],
    [":erl_boot_server:start/1", ":erl_boot_server", "start", "1", "1"],
    [":erl_boot_server:start_link/1", ":erl_boot_server", "start_link", "1", "1"],
    [":erl_boot_server:terminate/2", ":erl_boot_server", "terminate", "2", "1"],
    [":erl_boot_server:which_slaves/0", ":erl_boot_server", "which_slaves", "0", "1"],
    [":erl_boot_server:would_be_booted/1", ":erl_boot_server", "would_be_booted", "1", "1"],
    [
      "Cachex.Services.Janitor:-handle_info/2-fun-0-/1",
      "Cachex.Services.Janitor",
      "-handle_info/2-fun-0-",
      "1",
      "0"
    ],
    [
      "Cachex.Services.Janitor:-inlined-__info__/1-/1",
      "Cachex.Services.Janitor",
      "-inlined-__info__/1-",
      "1",
      "0"
    ],
    ["Cachex.Services.Janitor:__info__/1", "Cachex.Services.Janitor", "__info__", "1", "1"],
    ["Cachex.Services.Janitor:child_spec/1", "Cachex.Services.Janitor", "child_spec", "1", "1"],
    ["Cachex.Services.Janitor:code_change/3", "Cachex.Services.Janitor", "code_change", "3", "1"],
    ["Cachex.Services.Janitor:expiration/2", "Cachex.Services.Janitor", "expiration", "2", "1"],
    ["Cachex.Services.Janitor:expired?/1", "Cachex.Services.Janitor", "expired?", "1", "1"],
    ["Cachex.Services.Janitor:expired?/2", "Cachex.Services.Janitor", "expired?", "2", "1"],
    ["Cachex.Services.Janitor:handle_call/3", "Cachex.Services.Janitor", "handle_call", "3", "1"],
    ["Cachex.Services.Janitor:handle_cast/2", "Cachex.Services.Janitor", "handle_cast", "2", "1"],
    ["Cachex.Services.Janitor:handle_info/2", "Cachex.Services.Janitor", "handle_info", "2", "1"],
    [
      "Cachex.Services.Janitor:handle_provision/2",
      "Cachex.Services.Janitor",
      "handle_provision",
      "2",
      "1"
    ],
    [
      "Cachex.Services.Janitor:handle_skip_check/2",
      "Cachex.Services.Janitor",
      "handle_skip_check",
      "2",
      "0"
    ],
    ["Cachex.Services.Janitor:init/1", "Cachex.Services.Janitor", "init", "1", "1"],
    ["Cachex.Services.Janitor:last_run/1", "Cachex.Services.Janitor", "last_run", "1", "1"],
    ["Cachex.Services.Janitor:module_info/0", "Cachex.Services.Janitor", "module_info", "0", "1"],
    ["Cachex.Services.Janitor:module_info/1", "Cachex.Services.Janitor", "module_info", "1", "1"],
    ["Cachex.Services.Janitor:provisions/0", "Cachex.Services.Janitor", "provisions", "0", "1"],
    ["Cachex.Services.Janitor:schedule/1", "Cachex.Services.Janitor", "schedule", "1", "0"],
    ["Cachex.Services.Janitor:start_link/1", "Cachex.Services.Janitor", "start_link", "1", "1"],
    ["Cachex.Services.Janitor:terminate/2", "Cachex.Services.Janitor", "terminate", "2", "1"],
    [
      "Cluster.Strategy.Postgres:-handle_continue/2-fun-0-/2",
      "Cluster.Strategy.Postgres",
      "-handle_continue/2-fun-0-",
      "2",
      "0"
    ],
    [
      "Cluster.Strategy.Postgres:-handle_continue/2-fun-1-/2",
      "Cluster.Strategy.Postgres",
      "-handle_continue/2-fun-1-",
      "2",
      "0"
    ],
    [
      "Cluster.Strategy.Postgres:-handle_info/2-fun-0-/2",
      "Cluster.Strategy.Postgres",
      "-handle_info/2-fun-0-",
      "2",
      "0"
    ],
    [
      "Cluster.Strategy.Postgres:-handle_info/2-fun-1-/2",
      "Cluster.Strategy.Postgres",
      "-handle_info/2-fun-1-",
      "2",
      "0"
    ],
    [
      "Cluster.Strategy.Postgres:-init/1-fun-0-/1",
      "Cluster.Strategy.Postgres",
      "-init/1-fun-0-",
      "1",
      "0"
    ],
    [
      "Cluster.Strategy.Postgres:-inlined-__info__/1-/1",
      "Cluster.Strategy.Postgres",
      "-inlined-__info__/1-",
      "1",
      "0"
    ],
    ["Cluster.Strategy.Postgres:__info__/1", "Cluster.Strategy.Postgres", "__info__", "1", "1"],
    [
      "Cluster.Strategy.Postgres:child_spec/1",
      "Cluster.Strategy.Postgres",
      "child_spec",
      "1",
      "1"
    ],
    [
      "Cluster.Strategy.Postgres:code_change/3",
      "Cluster.Strategy.Postgres",
      "code_change",
      "3",
      "1"
    ],
    [
      "Cluster.Strategy.Postgres:handle_call/3",
      "Cluster.Strategy.Postgres",
      "handle_call",
      "3",
      "1"
    ],
    [
      "Cluster.Strategy.Postgres:handle_cast/2",
      "Cluster.Strategy.Postgres",
      "handle_cast",
      "2",
      "1"
    ],
    [
      "Cluster.Strategy.Postgres:handle_channels/3",
      "Cluster.Strategy.Postgres",
      "handle_channels",
      "3",
      "1"
    ],
    [
      "Cluster.Strategy.Postgres:handle_continue/2",
      "Cluster.Strategy.Postgres",
      "handle_continue",
      "2",
      "1"
    ],
    [
      "Cluster.Strategy.Postgres:handle_info/2",
      "Cluster.Strategy.Postgres",
      "handle_info",
      "2",
      "1"
    ],
    ["Cluster.Strategy.Postgres:heartbeat/1", "Cluster.Strategy.Postgres", "heartbeat", "1", "0"],
    ["Cluster.Strategy.Postgres:init/1", "Cluster.Strategy.Postgres", "init", "1", "1"],
    [
      "Cluster.Strategy.Postgres:module_info/0",
      "Cluster.Strategy.Postgres",
      "module_info",
      "0",
      "1"
    ],
    [
      "Cluster.Strategy.Postgres:module_info/1",
      "Cluster.Strategy.Postgres",
      "module_info",
      "1",
      "1"
    ],
    [
      "Cluster.Strategy.Postgres:start_link/1",
      "Cluster.Strategy.Postgres",
      "start_link",
      "1",
      "1"
    ],
    ["Cluster.Strategy.Postgres:terminate/2", "Cluster.Strategy.Postgres", "terminate", "2", "1"],
    ["Ecto.Term:-inlined-__info__/1-/1", "Ecto.Term", "-inlined-__info__/1-", "1", "0"],
    ["Ecto.Term:__info__/1", "Ecto.Term", "__info__", "1", "1"],
    ["Ecto.Term:cast/1", "Ecto.Term", "cast", "1", "1"],
    ["Ecto.Term:dump/1", "Ecto.Term", "dump", "1", "1"],
    ["Ecto.Term:embed_as/1", "Ecto.Term", "embed_as", "1", "1"],
    ["Ecto.Term:equal?/2", "Ecto.Term", "equal?", "2", "1"],
    ["Ecto.Term:load/1", "Ecto.Term", "load", "1", "1"],
    ["Ecto.Term:module_info/0", "Ecto.Term", "module_info", "0", "1"],
    ["Ecto.Term:module_info/1", "Ecto.Term", "module_info", "1", "1"],
    ["Ecto.Term:type/0", "Ecto.Term", "type", "0", "1"],
    ["Finch:-inlined-__info__/1-/1", "Finch", "-inlined-__info__/1-", "1", "0"],
    ["Finch:-pool_options!/1-fun-0-/1", "Finch", "-pool_options!/1-fun-0-", "1", "0"],
    ["Finch:-pool_options!/1-fun-1-/2", "Finch", "-pool_options!/1-fun-1-", "2", "0"],
    ["Finch:-request/3-fun-0-/2", "Finch", "-request/3-fun-0-", "2", "0"],
    ["Finch:-request/3-fun-1-/4", "Finch", "-request/3-fun-1-", "4", "0"],
    ["Finch:-stop_pool/2-fun-0-/2", "Finch", "-stop_pool/2-fun-0-", "2", "0"],
    ["Finch:-stop_pool/2-inlined-0-/1", "Finch", "-stop_pool/2-inlined-0-", "1", "0"],
    ["Finch:-stream/5-fun-0-/3", "Finch", "-stream/5-fun-0-", "3", "0"],
    ["Finch:-stream_while/5-fun-0-/6", "Finch", "-stream_while/5-fun-0-", "6", "0"],
    ["Finch:__info__/1", "Finch", "__info__", "1", "1"],
    ["Finch:__stream__/5", "Finch", "__stream__", "5", "0"],
    ["Finch:async_request/2", "Finch", "async_request", "2", "1"],
    ["Finch:async_request/3", "Finch", "async_request", "3", "1"],
    ["Finch:build/2", "Finch", "build", "2", "1"],
    ["Finch:build/3", "Finch", "build", "3", "1"],
    ["Finch:build/4", "Finch", "build", "4", "1"],
    ["Finch:build/5", "Finch", "build", "5", "1"],
    ["Finch:cancel_async_request/1", "Finch", "cancel_async_request", "1", "1"],
    ["Finch:cast_binary_destination/1", "Finch", "cast_binary_destination", "1", "0"],
    ["Finch:cast_destination/1", "Finch", "cast_destination", "1", "0"],
    ["Finch:cast_pool_opts/1", "Finch", "cast_pool_opts", "1", "0"],
    ["Finch:child_spec/1", "Finch", "child_spec", "1", "1"],
    ["Finch:finch_name!/1", "Finch", "finch_name!", "1", "0"],
    ["Finch:get_pool/2", "Finch", "get_pool", "2", "0"],
    ["Finch:get_pool_status/2", "Finch", "get_pool_status", "2", "1"],
    ["Finch:init/1", "Finch", "init", "1", "1"],
    ["Finch:manager_name/1", "Finch", "manager_name", "1", "0"],
    ["Finch:module_info/0", "Finch", "module_info", "0", "1"],
    ["Finch:module_info/1", "Finch", "module_info", "1", "1"],
    ["Finch:pool_options!/1", "Finch", "pool_options!", "1", "0"],
    ["Finch:pool_supervisor_name/1", "Finch", "pool_supervisor_name", "1", "0"],
    ["Finch:request!/2", "Finch", "request!", "2", "1"],
    ["Finch:request!/3", "Finch", "request!", "3", "1"],
    ["Finch:request/2", "Finch", "request", "2", "1"],
    ["Finch:request/3", "Finch", "request", "3", "1"],
    ["Finch:request/4", "Finch", "request", "4", "1"],
    ["Finch:request/5", "Finch", "request", "5", "1"],
    ["Finch:request/6", "Finch", "request", "6", "1"],
    ["Finch:start_link/1", "Finch", "start_link", "1", "1"],
    ["Finch:stop_pool/2", "Finch", "stop_pool", "2", "1"],
    ["Finch:stream/4", "Finch", "stream", "4", "1"],
    ["Finch:stream/5", "Finch", "stream", "5", "1"],
    ["Finch:stream_while/4", "Finch", "stream_while", "4", "1"],
    ["Finch:stream_while/5", "Finch", "stream_while", "5", "1"],
    ["Finch:supervisor_name/1", "Finch", "supervisor_name", "1", "0"],
    ["Finch:to_native/1", "Finch", "to_native", "1", "0"],
    ["Finch:valid_opts_to_map/1", "Finch", "valid_opts_to_map", "1", "0"],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:-inlined-__info__/1-/1",
      "Logflare.SystemMetrics.Wobserver.Helper",
      "-inlined-__info__/1-",
      "1",
      "0"
    ],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:-parallel_map/2-fun-0-/2",
      "Logflare.SystemMetrics.Wobserver.Helper",
      "-parallel_map/2-fun-0-",
      "2",
      "0"
    ],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:-parallel_map/2-fun-1-/2",
      "Logflare.SystemMetrics.Wobserver.Helper",
      "-parallel_map/2-fun-1-",
      "2",
      "0"
    ],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:__info__/1",
      "Logflare.SystemMetrics.Wobserver.Helper",
      "__info__",
      "1",
      "1"
    ],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:format_function/1",
      "Logflare.SystemMetrics.Wobserver.Helper",
      "format_function",
      "1",
      "1"
    ],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:module_info/0",
      "Logflare.SystemMetrics.Wobserver.Helper",
      "module_info",
      "0",
      "1"
    ],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:module_info/1",
      "Logflare.SystemMetrics.Wobserver.Helper",
      "module_info",
      "1",
      "1"
    ],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:parallel_map/2",
      "Logflare.SystemMetrics.Wobserver.Helper",
      "parallel_map",
      "2",
      "1"
    ],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1",
      "Logflare.SystemMetrics.Wobserver.Helper",
      "string_to_module",
      "1",
      "1"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:-indent/2-fun-0-/2",
      "Mix.Tasks.Phx.Gen.Context",
      "-indent/2-fun-0-",
      "2",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:-inlined-__info__/1-/1",
      "Mix.Tasks.Phx.Gen.Context",
      "-inlined-__info__/1-",
      "1",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:-maybe_print_unimplemented_fixture_functions/1-fun-0-/1",
      "Mix.Tasks.Phx.Gen.Context",
      "-maybe_print_unimplemented_fixture_functions/1-fun-0-",
      "1",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:-maybe_print_unimplemented_fixture_functions/1-fun-1-/1",
      "Mix.Tasks.Phx.Gen.Context",
      "-maybe_print_unimplemented_fixture_functions/1-fun-1-",
      "1",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:-merge_with_existing_context?/1-fun-0-/1",
      "Mix.Tasks.Phx.Gen.Context",
      "-merge_with_existing_context?/1-fun-0-",
      "1",
      "0"
    ],
    ["Mix.Tasks.Phx.Gen.Context:__info__/1", "Mix.Tasks.Phx.Gen.Context", "__info__", "1", "1"],
    ["Mix.Tasks.Phx.Gen.Context:build/1", "Mix.Tasks.Phx.Gen.Context", "build", "1", "1"],
    ["Mix.Tasks.Phx.Gen.Context:build/2", "Mix.Tasks.Phx.Gen.Context", "build", "2", "1"],
    [
      "Mix.Tasks.Phx.Gen.Context:copy_new_files/3",
      "Mix.Tasks.Phx.Gen.Context",
      "copy_new_files",
      "3",
      "1"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:ensure_context_file_exists/3",
      "Mix.Tasks.Phx.Gen.Context",
      "ensure_context_file_exists",
      "3",
      "1"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:ensure_test_file_exists/3",
      "Mix.Tasks.Phx.Gen.Context",
      "ensure_test_file_exists",
      "3",
      "1"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:ensure_test_fixtures_file_exists/3",
      "Mix.Tasks.Phx.Gen.Context",
      "ensure_test_fixtures_file_exists",
      "3",
      "1"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:files_to_be_generated/1",
      "Mix.Tasks.Phx.Gen.Context",
      "files_to_be_generated",
      "1",
      "1"
    ],
    ["Mix.Tasks.Phx.Gen.Context:indent/2", "Mix.Tasks.Phx.Gen.Context", "indent", "2", "0"],
    [
      "Mix.Tasks.Phx.Gen.Context:inject_eex_before_final_end/3",
      "Mix.Tasks.Phx.Gen.Context",
      "inject_eex_before_final_end",
      "3",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:inject_schema_access/3",
      "Mix.Tasks.Phx.Gen.Context",
      "inject_schema_access",
      "3",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:inject_test_fixture/3",
      "Mix.Tasks.Phx.Gen.Context",
      "inject_test_fixture",
      "3",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:inject_tests/3",
      "Mix.Tasks.Phx.Gen.Context",
      "inject_tests",
      "3",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:maybe_print_unimplemented_fixture_functions/1",
      "Mix.Tasks.Phx.Gen.Context",
      "maybe_print_unimplemented_fixture_functions",
      "1",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:merge_with_existing_context?/1",
      "Mix.Tasks.Phx.Gen.Context",
      "merge_with_existing_context?",
      "1",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:module_info/0",
      "Mix.Tasks.Phx.Gen.Context",
      "module_info",
      "0",
      "1"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:module_info/1",
      "Mix.Tasks.Phx.Gen.Context",
      "module_info",
      "1",
      "1"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:parse_opts/1",
      "Mix.Tasks.Phx.Gen.Context",
      "parse_opts",
      "1",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:print_shell_instructions/1",
      "Mix.Tasks.Phx.Gen.Context",
      "print_shell_instructions",
      "1",
      "1"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:prompt_for_code_injection/1",
      "Mix.Tasks.Phx.Gen.Context",
      "prompt_for_code_injection",
      "1",
      "1"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:prompt_for_conflicts/1",
      "Mix.Tasks.Phx.Gen.Context",
      "prompt_for_conflicts",
      "1",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:put_context_app/2",
      "Mix.Tasks.Phx.Gen.Context",
      "put_context_app",
      "2",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:raise_with_help/1",
      "Mix.Tasks.Phx.Gen.Context",
      "raise_with_help",
      "1",
      "1"
    ],
    ["Mix.Tasks.Phx.Gen.Context:run/1", "Mix.Tasks.Phx.Gen.Context", "run", "1", "1"],
    [
      "Mix.Tasks.Phx.Gen.Context:schema_access_template/1",
      "Mix.Tasks.Phx.Gen.Context",
      "schema_access_template",
      "1",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:singularize/2",
      "Mix.Tasks.Phx.Gen.Context",
      "singularize",
      "2",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:validate_args!/3",
      "Mix.Tasks.Phx.Gen.Context",
      "validate_args!",
      "3",
      "0"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:write_file/2",
      "Mix.Tasks.Phx.Gen.Context",
      "write_file",
      "2",
      "0"
    ],
    [
      "Tesla.Adapter.Mint:-format_response/3-fun-0-/2",
      "Tesla.Adapter.Mint",
      "-format_response/3-fun-0-",
      "2",
      "0"
    ],
    [
      "Tesla.Adapter.Mint:-format_response/3-fun-1-/3",
      "Tesla.Adapter.Mint",
      "-format_response/3-fun-1-",
      "3",
      "0"
    ],
    [
      "Tesla.Adapter.Mint:-format_response/3-fun-2-/2",
      "Tesla.Adapter.Mint",
      "-format_response/3-fun-2-",
      "2",
      "0"
    ],
    [
      "Tesla.Adapter.Mint:-format_response/3-inlined-0-/1",
      "Tesla.Adapter.Mint",
      "-format_response/3-inlined-0-",
      "1",
      "0"
    ],
    [
      "Tesla.Adapter.Mint:-format_response/3-inlined-1-/1",
      "Tesla.Adapter.Mint",
      "-format_response/3-inlined-1-",
      "1",
      "0"
    ],
    [
      "Tesla.Adapter.Mint:-inlined-__info__/1-/1",
      "Tesla.Adapter.Mint",
      "-inlined-__info__/1-",
      "1",
      "0"
    ],
    [
      "Tesla.Adapter.Mint:-open_conn/2-fun-0-/2",
      "Tesla.Adapter.Mint",
      "-open_conn/2-fun-0-",
      "2",
      "0"
    ],
    [
      "Tesla.Adapter.Mint:-open_conn/2-fun-1-/2",
      "Tesla.Adapter.Mint",
      "-open_conn/2-fun-1-",
      "2",
      "0"
    ],
    [
      "Tesla.Adapter.Mint:-receive_packet/4-fun-0-/3",
      "Tesla.Adapter.Mint",
      "-receive_packet/4-fun-0-",
      "3",
      "0"
    ],
    [
      "Tesla.Adapter.Mint:-reduce_responses/3-fun-0-/2",
      "Tesla.Adapter.Mint",
      "-reduce_responses/3-fun-0-",
      "2",
      "0"
    ],
    [
      "Tesla.Adapter.Mint:-reduce_responses/3-fun-1-/2",
      "Tesla.Adapter.Mint",
      "-reduce_responses/3-fun-1-",
      "2",
      "0"
    ],
    [
      "Tesla.Adapter.Mint:-reduce_responses/3-fun-2-/3",
      "Tesla.Adapter.Mint",
      "-reduce_responses/3-fun-2-",
      "3",
      "0"
    ],
    [
      "Tesla.Adapter.Mint:-reduce_responses/3-inlined-0-/2",
      "Tesla.Adapter.Mint",
      "-reduce_responses/3-inlined-0-",
      "2",
      "0"
    ],
    ["Tesla.Adapter.Mint:__info__/1", "Tesla.Adapter.Mint", "__info__", "1", "1"],
    ["Tesla.Adapter.Mint:call/2", "Tesla.Adapter.Mint", "call", "2", "1"],
    ["Tesla.Adapter.Mint:check_data_size/3", "Tesla.Adapter.Mint", "check_data_size", "3", "0"],
    ["Tesla.Adapter.Mint:check_original/2", "Tesla.Adapter.Mint", "check_original", "2", "0"],
    ["Tesla.Adapter.Mint:close/1", "Tesla.Adapter.Mint", "close", "1", "1"],
    ["Tesla.Adapter.Mint:do_request/5", "Tesla.Adapter.Mint", "do_request", "5", "0"],
    ["Tesla.Adapter.Mint:format_response/3", "Tesla.Adapter.Mint", "format_response", "3", "0"],
    ["Tesla.Adapter.Mint:make_request/5", "Tesla.Adapter.Mint", "make_request", "5", "0"],
    ["Tesla.Adapter.Mint:module_info/0", "Tesla.Adapter.Mint", "module_info", "0", "1"],
    ["Tesla.Adapter.Mint:module_info/1", "Tesla.Adapter.Mint", "module_info", "1", "1"],
    ["Tesla.Adapter.Mint:open_conn/2", "Tesla.Adapter.Mint", "open_conn", "2", "0"],
    ["Tesla.Adapter.Mint:read_chunk/3", "Tesla.Adapter.Mint", "read_chunk", "3", "1"],
    [
      "Tesla.Adapter.Mint:receive_headers_and_status/3",
      "Tesla.Adapter.Mint",
      "receive_headers_and_status",
      "3",
      "0"
    ],
    [
      "Tesla.Adapter.Mint:receive_headers_and_status/4",
      "Tesla.Adapter.Mint",
      "receive_headers_and_status",
      "4",
      "0"
    ],
    ["Tesla.Adapter.Mint:receive_message/2", "Tesla.Adapter.Mint", "receive_message", "2", "0"],
    ["Tesla.Adapter.Mint:receive_packet/3", "Tesla.Adapter.Mint", "receive_packet", "3", "0"],
    ["Tesla.Adapter.Mint:receive_packet/4", "Tesla.Adapter.Mint", "receive_packet", "4", "0"],
    [
      "Tesla.Adapter.Mint:receive_responses/3",
      "Tesla.Adapter.Mint",
      "receive_responses",
      "3",
      "0"
    ],
    [
      "Tesla.Adapter.Mint:receive_responses/4",
      "Tesla.Adapter.Mint",
      "receive_responses",
      "4",
      "0"
    ],
    ["Tesla.Adapter.Mint:reduce_responses/3", "Tesla.Adapter.Mint", "reduce_responses", "3", "0"],
    ["Tesla.Adapter.Mint:request/2", "Tesla.Adapter.Mint", "request", "2", "0"],
    ["Tesla.Adapter.Mint:request/5", "Tesla.Adapter.Mint", "request", "5", "0"],
    ["Tesla.Adapter.Mint:response_state/1", "Tesla.Adapter.Mint", "response_state", "1", "0"],
    ["Tesla.Adapter.Mint:stream_request/3", "Tesla.Adapter.Mint", "stream_request", "3", "0"]
  ],
  remote_call: [
    [
      ":erl_boot_server:handle_command/3#10",
      ":erl_boot_server:handle_command/3",
      ":erlang",
      "binary_to_term",
      "1"
    ],
    [
      ":erl_boot_server:handle_command/3#128",
      ":erl_boot_server:handle_command/3",
      ":erl_prim_loader",
      "prim_get_cwd",
      "2"
    ],
    [
      ":erl_boot_server:handle_command/3#24",
      ":erl_boot_server:handle_command/3",
      ":erl_prim_loader",
      "prim_read_file_info",
      "3"
    ],
    [
      ":erl_boot_server:handle_command/3#43",
      ":erl_boot_server:handle_command/3",
      ":erl_prim_loader",
      "prim_read_file_info",
      "3"
    ],
    [
      ":erl_boot_server:handle_command/3#61",
      ":erl_boot_server:handle_command/3",
      ":erl_prim_loader",
      "prim_list_dir",
      "2"
    ],
    [
      ":erl_boot_server:handle_command/3#80",
      ":erl_boot_server:handle_command/3",
      ":erl_prim_loader",
      "prim_get_cwd",
      "2"
    ],
    [
      ":erl_boot_server:handle_command/3#98",
      ":erl_boot_server:handle_command/3",
      ":erl_prim_loader",
      "prim_read_file",
      "2"
    ],
    [
      "Cachex.Services.Janitor:last_run/1#21",
      "Cachex.Services.Janitor:last_run/1",
      "String.Chars",
      "to_string",
      "1"
    ],
    [
      "Cachex.Services.Janitor:last_run/1#25",
      "Cachex.Services.Janitor:last_run/1",
      "String.Chars",
      "to_string",
      "1"
    ],
    [
      "Cachex.Services.Janitor:last_run/1#29",
      "Cachex.Services.Janitor:last_run/1",
      ":erlang",
      "binary_to_atom",
      "2"
    ],
    [
      "Cachex.Services.Janitor:last_run/1#32",
      "Cachex.Services.Janitor:last_run/1",
      "GenServer",
      "call",
      "3"
    ],
    [
      "Cachex.Services.Janitor:start_link/1#15",
      "Cachex.Services.Janitor:start_link/1",
      "String.Chars",
      "to_string",
      "1"
    ],
    [
      "Cachex.Services.Janitor:start_link/1#19",
      "Cachex.Services.Janitor:start_link/1",
      "String.Chars",
      "to_string",
      "1"
    ],
    [
      "Cachex.Services.Janitor:start_link/1#23",
      "Cachex.Services.Janitor:start_link/1",
      ":erlang",
      "binary_to_atom",
      "2"
    ],
    [
      "Cachex.Services.Janitor:start_link/1#29",
      "Cachex.Services.Janitor:start_link/1",
      "GenServer",
      "start_link",
      "3"
    ],
    [
      "Cluster.Strategy.Postgres:handle_channels/3#10",
      "Cluster.Strategy.Postgres:handle_channels/3",
      ":erlang",
      "binary_to_atom",
      "1"
    ],
    [
      "Cluster.Strategy.Postgres:handle_channels/3#109",
      "Cluster.Strategy.Postgres:handle_channels/3",
      "String.Chars",
      "to_string",
      "1"
    ],
    [
      "Cluster.Strategy.Postgres:handle_channels/3#113",
      "Cluster.Strategy.Postgres:handle_channels/3",
      "Cluster.Logger",
      "debug",
      "2"
    ],
    [
      "Cluster.Strategy.Postgres:handle_channels/3#117",
      "Cluster.Strategy.Postgres:handle_channels/3",
      ":erlang",
      "error",
      "1"
    ],
    [
      "Cluster.Strategy.Postgres:handle_channels/3#121",
      "Cluster.Strategy.Postgres:handle_channels/3",
      ":erlang",
      "error",
      "1"
    ],
    [
      "Cluster.Strategy.Postgres:handle_channels/3#26",
      "Cluster.Strategy.Postgres:handle_channels/3",
      ":elixir_erl_pass",
      "no_parens_remote",
      "2"
    ],
    [
      "Cluster.Strategy.Postgres:handle_channels/3#41",
      "Cluster.Strategy.Postgres:handle_channels/3",
      "String.Chars",
      "to_string",
      "1"
    ],
    [
      "Cluster.Strategy.Postgres:handle_channels/3#45",
      "Cluster.Strategy.Postgres:handle_channels/3",
      "Cluster.Logger",
      "debug",
      "2"
    ],
    [
      "Cluster.Strategy.Postgres:handle_channels/3#54",
      "Cluster.Strategy.Postgres:handle_channels/3",
      ":elixir_erl_pass",
      "no_parens_remote",
      "2"
    ],
    [
      "Cluster.Strategy.Postgres:handle_channels/3#70",
      "Cluster.Strategy.Postgres:handle_channels/3",
      ":elixir_erl_pass",
      "no_parens_remote",
      "2"
    ],
    [
      "Cluster.Strategy.Postgres:handle_channels/3#85",
      "Cluster.Strategy.Postgres:handle_channels/3",
      "Cluster.Strategy",
      "connect_nodes",
      "4"
    ],
    [
      "Cluster.Strategy.Postgres:handle_channels/3#95",
      "Cluster.Strategy.Postgres:handle_channels/3",
      "String.Chars",
      "to_string",
      "1"
    ],
    [
      "Cluster.Strategy.Postgres:handle_channels/3#99",
      "Cluster.Strategy.Postgres:handle_channels/3",
      "Cluster.Logger",
      "error",
      "2"
    ],
    ["Ecto.Term:load/1#15", "Ecto.Term:load/1", ":erlang", "binary_to_term", "1"],
    ["Ecto.Term:load/1#43", "Ecto.Term:load/1", "Exception", "normalize", "3"],
    ["Ecto.Term:load/1#52", "Ecto.Term:load/1", ":elixir_erl_pass", "no_parens_remote", "2"],
    ["Ecto.Term:load/1#65", "Ecto.Term:load/1", ":erlang", "error", "1"],
    ["Finch:manager_name/1#11", "Finch:manager_name/1", "String.Chars", "to_string", "1"],
    ["Finch:manager_name/1#15", "Finch:manager_name/1", ":erlang", "binary_to_atom", "2"],
    [
      "Finch:pool_supervisor_name/1#11",
      "Finch:pool_supervisor_name/1",
      "String.Chars",
      "to_string",
      "1"
    ],
    [
      "Finch:pool_supervisor_name/1#15",
      "Finch:pool_supervisor_name/1",
      ":erlang",
      "binary_to_atom",
      "2"
    ],
    ["Finch:supervisor_name/1#11", "Finch:supervisor_name/1", "String.Chars", "to_string", "1"],
    ["Finch:supervisor_name/1#15", "Finch:supervisor_name/1", ":erlang", "binary_to_atom", "2"],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1#11",
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1",
      "String",
      "capitalize",
      "1"
    ],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1#17",
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1",
      "String",
      "split",
      "2"
    ],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1#20",
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1",
      "Enum",
      "map",
      "2"
    ],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1#22",
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1",
      "Module",
      "concat",
      "1"
    ],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1#26",
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1",
      ":erlang",
      "binary_to_atom",
      "1"
    ],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1#8",
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1",
      "String",
      "first",
      "1"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:put_context_app/2#11",
      "Mix.Tasks.Phx.Gen.Context:put_context_app/2",
      ":erlang",
      "binary_to_atom",
      "1"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:put_context_app/2#15",
      "Mix.Tasks.Phx.Gen.Context:put_context_app/2",
      "Keyword",
      "put",
      "3"
    ],
    [
      "Tesla.Adapter.Mint:-open_conn/2-fun-1-/2#7",
      "Tesla.Adapter.Mint:-open_conn/2-fun-1-/2",
      "Keyword",
      "put_new",
      "3"
    ],
    [
      "Tesla.Adapter.Mint:open_conn/2#108",
      "Tesla.Adapter.Mint:open_conn/2",
      ":elixir_erl_pass",
      "no_parens_remote",
      "2"
    ],
    [
      "Tesla.Adapter.Mint:open_conn/2#125",
      "Tesla.Adapter.Mint:open_conn/2",
      ":elixir_erl_pass",
      "no_parens_remote",
      "2"
    ],
    ["Tesla.Adapter.Mint:open_conn/2#136", "Tesla.Adapter.Mint:open_conn/2", "Enum", "into", "2"],
    [
      "Tesla.Adapter.Mint:open_conn/2#142",
      "Tesla.Adapter.Mint:open_conn/2",
      "Mint.HTTP",
      "connect",
      "4"
    ],
    [
      "Tesla.Adapter.Mint:open_conn/2#155",
      "Tesla.Adapter.Mint:open_conn/2",
      ":erlang",
      "error",
      "1"
    ],
    [
      "Tesla.Adapter.Mint:open_conn/2#162",
      "Tesla.Adapter.Mint:open_conn/2",
      ":erlang",
      "error",
      "1"
    ],
    [
      "Tesla.Adapter.Mint:open_conn/2#166",
      "Tesla.Adapter.Mint:open_conn/2",
      ":erlang",
      "error",
      "1"
    ],
    [
      "Tesla.Adapter.Mint:open_conn/2#17",
      "Tesla.Adapter.Mint:open_conn/2",
      "Map",
      "put_new",
      "3"
    ],
    [
      "Tesla.Adapter.Mint:open_conn/2#21",
      "Tesla.Adapter.Mint:open_conn/2",
      ":maps",
      "remove",
      "2"
    ],
    [
      "Tesla.Adapter.Mint:open_conn/2#37",
      "Tesla.Adapter.Mint:open_conn/2",
      ":elixir_erl_pass",
      "no_parens_remote",
      "2"
    ],
    [
      "Tesla.Adapter.Mint:open_conn/2#50",
      "Tesla.Adapter.Mint:open_conn/2",
      "Application",
      "get_env",
      "2"
    ],
    ["Tesla.Adapter.Mint:open_conn/2#52", "Tesla.Adapter.Mint:open_conn/2", "Access", "get", "2"],
    ["Tesla.Adapter.Mint:open_conn/2#70", "Tesla.Adapter.Mint:open_conn/2", "Map", "update", "4"],
    [
      "Tesla.Adapter.Mint:open_conn/2#81",
      "Tesla.Adapter.Mint:open_conn/2",
      "Map",
      "put_new",
      "3"
    ],
    [
      "Tesla.Adapter.Mint:open_conn/2#90",
      "Tesla.Adapter.Mint:open_conn/2",
      ":elixir_erl_pass",
      "no_parens_remote",
      "2"
    ],
    [
      "Tesla.Adapter.Mint:open_conn/2#99",
      "Tesla.Adapter.Mint:open_conn/2",
      ":erlang",
      "binary_to_atom",
      "1"
    ]
  ],
  bif_call: [
    [
      "Cluster.Strategy.Postgres:handle_channels/3#11",
      "Cluster.Strategy.Postgres:handle_channels/3",
      ":erlang",
      "node",
      "0",
      "0"
    ],
    ["Ecto.Term:load/1#25", "Ecto.Term:load/1", ":erlang", "map_get", "2", "25"],
    ["Ecto.Term:load/1#27", "Ecto.Term:load/1", ":erlang", "map_get", "2", "25"],
    ["Ecto.Term:load/1#67", "Ecto.Term:load/1", ":erlang", "raise", "2", "0"]
  ],
  local_call: [
    [
      ":erl_boot_server:boot_loop/2#22",
      ":erl_boot_server:boot_loop/2",
      ":erl_boot_server:handle_command/3",
      "3"
    ],
    [
      ":erl_boot_server:handle_command/3#107",
      ":erl_boot_server:handle_command/3",
      ":erl_boot_server:send_file_result/3",
      "3"
    ],
    [
      ":erl_boot_server:handle_command/3#118",
      ":erl_boot_server:handle_command/3",
      ":erl_boot_server:send_result/2",
      "2"
    ],
    [
      ":erl_boot_server:handle_command/3#137",
      ":erl_boot_server:handle_command/3",
      ":erl_boot_server:send_file_result/3",
      "3"
    ],
    [
      ":erl_boot_server:handle_command/3#147",
      ":erl_boot_server:handle_command/3",
      ":erl_boot_server:send_result/2",
      "2"
    ],
    [
      ":erl_boot_server:handle_command/3#33",
      ":erl_boot_server:handle_command/3",
      ":erl_boot_server:send_file_result/3",
      "3"
    ],
    [
      ":erl_boot_server:handle_command/3#52",
      ":erl_boot_server:handle_command/3",
      ":erl_boot_server:send_file_result/3",
      "3"
    ],
    [
      ":erl_boot_server:handle_command/3#70",
      ":erl_boot_server:handle_command/3",
      ":erl_boot_server:send_file_result/3",
      "3"
    ],
    [
      ":erl_boot_server:handle_command/3#89",
      ":erl_boot_server:handle_command/3",
      ":erl_boot_server:send_file_result/3",
      "3"
    ],
    [
      "Cluster.Strategy.Postgres:handle_info/2#35",
      "Cluster.Strategy.Postgres:handle_info/2",
      "Cluster.Strategy.Postgres:handle_channels/3",
      "3"
    ],
    [
      "Finch:-stop_pool/2-fun-0-/2#10",
      "Finch:-stop_pool/2-fun-0-/2",
      "Finch:pool_supervisor_name/1",
      "1"
    ],
    ["Finch:start_link/1#23", "Finch:start_link/1", "Finch:manager_name/1", "1"],
    ["Finch:start_link/1#27", "Finch:start_link/1", "Finch:pool_supervisor_name/1", "1"],
    ["Finch:start_link/1#35", "Finch:start_link/1", "Finch:supervisor_name/1", "1"],
    [
      "Mix.Tasks.Phx.Gen.Context:parse_opts/1#24",
      "Mix.Tasks.Phx.Gen.Context:parse_opts/1",
      "Mix.Tasks.Phx.Gen.Context:put_context_app/2",
      "2"
    ],
    [
      "Tesla.Adapter.Mint:do_request/5#59",
      "Tesla.Adapter.Mint:do_request/5",
      "Tesla.Adapter.Mint:open_conn/2",
      "2"
    ],
    [
      "Tesla.Adapter.Mint:open_conn/2#24",
      "Tesla.Adapter.Mint:open_conn/2",
      "Tesla.Adapter.Mint:open_conn/2",
      "2"
    ],
    [
      "Tesla.Adapter.Mint:open_conn/2#58",
      "Tesla.Adapter.Mint:open_conn/2",
      "Tesla.Adapter.Mint:-open_conn/2-fun-0-/2",
      "2"
    ],
    [
      "Tesla.Adapter.Mint:open_conn/2#76",
      "Tesla.Adapter.Mint:open_conn/2",
      "Tesla.Adapter.Mint:-open_conn/2-fun-0-/2",
      "2"
    ]
  ],
  closure_def: [
    ["Tesla.Adapter.Mint:open_conn/2", "Tesla.Adapter.Mint:-open_conn/2-fun-1-/2"]
  ],
  literal_value: [
    [":erl_boot_server:handle_command/3#103", "x1", ":get"],
    [":erl_boot_server:handle_command/3#124", "x1", "nil"],
    [":erl_boot_server:handle_command/3#133", "x1", ":get_cwd"],
    [":erl_boot_server:handle_command/3#142", "x1", "{:error, :unknown_command}"],
    [":erl_boot_server:handle_command/3#20", "x2", "false"],
    [":erl_boot_server:handle_command/3#29", "x1", ":read_link_info"],
    [":erl_boot_server:handle_command/3#39", "x2", "true"],
    [":erl_boot_server:handle_command/3#48", "x1", ":read_file_info"],
    [":erl_boot_server:handle_command/3#66", "x1", ":list_dir"],
    [":erl_boot_server:handle_command/3#85", "x1", ":get_cwd"],
    ["Cachex.Services.Janitor:last_run/1#24", "x0", ":janitor"],
    ["Cachex.Services.Janitor:last_run/1#27", "x1", ":utf8"],
    ["Cachex.Services.Janitor:last_run/1#30", "x2", ":infinity"],
    ["Cachex.Services.Janitor:last_run/1#31", "x1", ":last"],
    ["Cachex.Services.Janitor:last_run/1#9", "x0", "{:error, :janitor_disabled}"],
    ["Cachex.Services.Janitor:start_link/1#18", "x0", ":janitor"],
    ["Cachex.Services.Janitor:start_link/1#21", "x1", ":utf8"],
    ["Cachex.Services.Janitor:start_link/1#28", "x0", "Cachex.Services.Janitor"],
    ["Cluster.Strategy.Postgres:handle_channels/3#14", "x0", "nil"],
    ["Cluster.Strategy.Postgres:handle_channels/3#23", "x1", ":topology"],
    ["Cluster.Strategy.Postgres:handle_channels/3#51", "x1", ":connect"],
    ["Cluster.Strategy.Postgres:handle_channels/3#67", "x1", ":list_nodes"],
    ["Ecto.Term:load/1#41", "x0", ":error"],
    ["Ecto.Term:load/1#5", "x0", "{:ok, \"\"}"],
    ["Ecto.Term:load/1#51", "x1", ":message"],
    ["Ecto.Term:load/1#9", "x0", "{:ok, nil}"],
    ["Finch:manager_name/1#14", "x1", ":utf8"],
    ["Finch:pool_supervisor_name/1#14", "x1", ":utf8"],
    ["Finch:supervisor_name/1#14", "x1", ":utf8"],
    ["Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1#13", "x1", "\".\""],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1#18",
      "x1",
      "&:erlang.binary_to_atom/1"
    ],
    ["Mix.Tasks.Phx.Gen.Context:put_context_app/2#12", "x1", ":context_app"],
    ["Tesla.Adapter.Mint:-open_conn/2-fun-1-/2#5", "x1", ":cacertfile"],
    ["Tesla.Adapter.Mint:open_conn/2#106", "x1", ":host"],
    ["Tesla.Adapter.Mint:open_conn/2#122", "x1", ":port"],
    ["Tesla.Adapter.Mint:open_conn/2#134", "x1", "nil"],
    ["Tesla.Adapter.Mint:open_conn/2#15", "x1", ":old_conn"],
    ["Tesla.Adapter.Mint:open_conn/2#19", "x0", ":conn"],
    ["Tesla.Adapter.Mint:open_conn/2#34", "x1", ":scheme"],
    ["Tesla.Adapter.Mint:open_conn/2#47", "x1", "Tesla.Adapter.Mint"],
    ["Tesla.Adapter.Mint:open_conn/2#48", "x0", ":tesla"],
    ["Tesla.Adapter.Mint:open_conn/2#51", "x1", ":cacert"],
    ["Tesla.Adapter.Mint:open_conn/2#56", "x0", "nil"],
    ["Tesla.Adapter.Mint:open_conn/2#66", "x1", ":transport_opts"],
    ["Tesla.Adapter.Mint:open_conn/2#78", "x2", ":passive"],
    ["Tesla.Adapter.Mint:open_conn/2#79", "x1", ":mode"],
    ["Tesla.Adapter.Mint:open_conn/2#87", "x1", ":scheme"]
  ],
  tuple_literal: [
    [":erl_boot_server:handle_command/3#113", "x1", ":error", "2"],
    [":erl_boot_server:handle_command/3#142", "x1", ":error", "2"],
    ["Cachex.Services.Janitor:last_run/1#9", "x0", ":error", "2"],
    ["Cachex.Services.Janitor:start_link/1#25", "x0", ":name", "2"],
    ["Ecto.Term:load/1#18", "x0", ":ok", "2"],
    ["Ecto.Term:load/1#47", "x0", ":error", "2"],
    ["Ecto.Term:load/1#5", "x0", ":ok", "2"],
    ["Ecto.Term:load/1#60", "x0", ":error", "2"],
    ["Ecto.Term:load/1#9", "x0", ":ok", "2"],
    ["Tesla.Adapter.Mint:open_conn/2#148", "x0", ":ok", "3"],
    ["Tesla.Adapter.Mint:open_conn/2#153", "x0", ":badmap", "2"],
    ["Tesla.Adapter.Mint:open_conn/2#63", "x0", ":cacertfile", "2"],
    ["Tesla.Adapter.Mint:open_conn/2#9", "x0", ":ok", "3"]
  ],
  implements_behaviour: [
    [":erl_boot_server", ":gen_server"],
    ["Cachex.Services.Janitor", "Cachex.Provision"],
    ["Cachex.Services.Janitor", "GenServer"],
    ["Cluster.Strategy.Postgres", "GenServer"],
    ["Ecto.Term", "Ecto.Type"],
    ["Finch", "Supervisor"],
    ["Mix.Tasks.Phx.Gen.Context", "Mix.Task"],
    ["Tesla.Adapter.Mint", "Tesla.Adapter"]
  ],
  unsafe_atom_creation: [
    [
      "Cachex.Services.Janitor:last_run/1#29",
      "Cachex.Services.Janitor:last_run/1",
      ":erlang.binary_to_atom/2"
    ],
    [
      "Cachex.Services.Janitor:start_link/1#23",
      "Cachex.Services.Janitor:start_link/1",
      ":erlang.binary_to_atom/2"
    ],
    [
      "Cluster.Strategy.Postgres:handle_channels/3#10",
      "Cluster.Strategy.Postgres:handle_channels/3",
      ":erlang.binary_to_atom/1"
    ],
    ["Finch:manager_name/1#15", "Finch:manager_name/1", ":erlang.binary_to_atom/2"],
    [
      "Finch:pool_supervisor_name/1#15",
      "Finch:pool_supervisor_name/1",
      ":erlang.binary_to_atom/2"
    ],
    ["Finch:supervisor_name/1#15", "Finch:supervisor_name/1", ":erlang.binary_to_atom/2"],
    [
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1#26",
      "Logflare.SystemMetrics.Wobserver.Helper:string_to_module/1",
      ":erlang.binary_to_atom/1"
    ],
    [
      "Mix.Tasks.Phx.Gen.Context:put_context_app/2#11",
      "Mix.Tasks.Phx.Gen.Context:put_context_app/2",
      ":erlang.binary_to_atom/1"
    ],
    [
      "Tesla.Adapter.Mint:open_conn/2#99",
      "Tesla.Adapter.Mint:open_conn/2",
      ":erlang.binary_to_atom/1"
    ]
  ],
  unsafe_deserialization: [
    [
      ":erl_boot_server:handle_command/3#10",
      ":erl_boot_server:handle_command/3",
      ":erlang.binary_to_term/1",
      "unsafe"
    ],
    ["Ecto.Term:load/1#15", "Ecto.Term:load/1", ":erlang.binary_to_term/1", "unsafe"]
  ],
  code_execution: [],
  sink_arg_bounded: [
    ["Cachex.Services.Janitor:last_run/1#29", "Cachex.Services.Janitor:last_run/1", "1", ""],
    ["Cachex.Services.Janitor:start_link/1#23", "Cachex.Services.Janitor:start_link/1", "1", ""],
    ["Finch:manager_name/1#15", "Finch:manager_name/1", "1", ""],
    ["Finch:pool_supervisor_name/1#15", "Finch:pool_supervisor_name/1", "1", ""],
    ["Finch:supervisor_name/1#15", "Finch:supervisor_name/1", "1", ""]
  ]
}
