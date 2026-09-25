# Seven modules whose servers and receives blocking and startup ask about,
# as the extractors see them (OTP 28.2's kernel and stdlib, ejabberd
# 26.x, rabbitmq 4.x, db_connection from logflare 54e9a38): raw rows of
# the relations Argus.Priors.Questions.PeerAnswers reads, trimmed to what
# the questions show, decoded by the test.
%{
  function_def: [
    [
      ":code_server:-abort_if_pending_on_load/2-lc$^0/1-0-/2",
      ":code_server",
      "-abort_if_pending_on_load/2-lc$^0/1-0-",
      "2",
      "0"
    ],
    [
      ":code_server:-abort_if_sticky/2-lc$^0/1-0-/2",
      ":code_server",
      "-abort_if_sticky/2-lc$^0/1-0-",
      "2",
      "0"
    ],
    [
      ":code_server:-cache_path/1-lc$^0/1-0-/2",
      ":code_server",
      "-cache_path/1-lc$^0/1-0-",
      "2",
      "0"
    ],
    [
      ":code_server:-choose_bundles/1-lc$^0/1-0-/2",
      ":code_server",
      "-choose_bundles/1-lc$^0/1-0-",
      "2",
      "0"
    ],
    [
      ":code_server:-choose_bundles/1-lc$^1/1-1-/1",
      ":code_server",
      "-choose_bundles/1-lc$^1/1-1-",
      "1",
      "0"
    ],
    [
      ":code_server:-do_finish_loading/2-lc$^0/1-0-/1",
      ":code_server",
      "-do_finish_loading/2-lc$^0/1-0-",
      "1",
      "0"
    ],
    [
      ":code_server:-do_finish_loading/2-lc$^1/1-2-/1",
      ":code_server",
      "-do_finish_loading/2-lc$^1/1-2-",
      "1",
      "0"
    ],
    [
      ":code_server:-do_finish_loading/2-lc$^2/1-1-/2",
      ":code_server",
      "-do_finish_loading/2-lc$^2/1-1-",
      "2",
      "0"
    ],
    [":code_server:-exclude/2-lc$^0/1-0-/3", ":code_server", "-exclude/2-lc$^0/1-0-", "3", "0"],
    [
      ":code_server:-finish_loading/3-fun-0-/2",
      ":code_server",
      "-finish_loading/3-fun-0-",
      "2",
      "0"
    ],
    [
      ":code_server:-finish_loading/3-fun-1-/2",
      ":code_server",
      "-finish_loading/3-fun-1-",
      "2",
      "0"
    ],
    [
      ":code_server:-finish_loading/3-fun-2-/2",
      ":code_server",
      "-finish_loading/3-fun-2-",
      "2",
      "0"
    ],
    [
      ":code_server:-finish_loading/3-fun-3-/2",
      ":code_server",
      "-finish_loading/3-fun-3-",
      "2",
      "0"
    ],
    [
      ":code_server:-finish_loading_ensure/2-lc$^0/1-0-/1",
      ":code_server",
      "-finish_loading_ensure/2-lc$^0/1-0-",
      "1",
      "0"
    ],
    [
      ":code_server:-finish_on_load_report/2-fun-0-/2",
      ":code_server",
      "-finish_on_load_report/2-fun-0-",
      "2",
      "0"
    ],
    [
      ":code_server:-get_user_lib_dirs_1/1-lc$^0/1-0-/2",
      ":code_server",
      "-get_user_lib_dirs_1/1-lc$^0/1-0-",
      "2",
      "0"
    ],
    [
      ":code_server:-handle_call/3-lc$^0/1-0-/1",
      ":code_server",
      "-handle_call/3-lc$^0/1-0-",
      "1",
      "0"
    ],
    [":code_server:-init/3-fun-0-/2", ":code_server", "-init/3-fun-0-", "2", "0"],
    [":code_server:-init/3-lc$^1/1-0-/1", ":code_server", "-init/3-lc$^1/1-0-", "1", "0"],
    [":code_server:-is_numstr/1-fun-0-/1", ":code_server", "-is_numstr/1-fun-0-", "1", "0"],
    [
      ":code_server:-schedule_on_load/4-fun-0-/1",
      ":code_server",
      "-schedule_on_load/4-fun-0-",
      "1",
      "0"
    ],
    [":code_server:-set_path/5-lc$^0/1-0-/2", ":code_server", "-set_path/5-lc$^0/1-0-", "2", "0"],
    [":code_server:-start_link/1-fun-0-/3", ":code_server", "-start_link/1-fun-0-", "3", "0"],
    [":code_server:-stick_dir/3-fun-0-/2", ":code_server", "-stick_dir/3-fun-0-", "2", "0"],
    [":code_server:-stick_dir/3-fun-1-/2", ":code_server", "-stick_dir/3-fun-1-", "2", "0"],
    [
      ":code_server:-store_module_and_reply/3-fun-0-/2",
      ":code_server",
      "-store_module_and_reply/3-fun-0-",
      "2",
      "0"
    ],
    [
      ":code_server:-store_module_and_reply/3-inlined-0-/1",
      ":code_server",
      "-store_module_and_reply/3-inlined-0-",
      "1",
      "0"
    ],
    [
      ":code_server:-try_archive_subdirs/3-fun-0-/2",
      ":code_server",
      "-try_archive_subdirs/3-fun-0-",
      "2",
      "0"
    ],
    [
      ":code_server:-vsn_to_num/1-lc$^0/1-0-/1",
      ":code_server",
      "-vsn_to_num/1-lc$^0/1-0-",
      "1",
      "0"
    ],
    [
      ":code_server:abort_if_pending_on_load/2",
      ":code_server",
      "abort_if_pending_on_load",
      "2",
      "0"
    ],
    [":code_server:abort_if_sticky/2", ":code_server", "abort_if_sticky", "2", "0"],
    [":code_server:absname/1", ":code_server", "absname", "1", "1"],
    [":code_server:absname/2", ":code_server", "absname", "2", "0"],
    [":code_server:absname_vr/3", ":code_server", "absname_vr", "3", "0"],
    [":code_server:absname_when_relative/1", ":code_server", "absname_when_relative", "1", "0"],
    [":code_server:add_loader_path/2", ":code_server", "add_loader_path", "2", "0"],
    [":code_server:add_pa_pz/3", ":code_server", "add_pa_pz", "3", "0"],
    [":code_server:add_path/6", ":code_server", "add_path", "6", "0"],
    [":code_server:add_paths/6", ":code_server", "add_paths", "6", "0"],
    [":code_server:all_loaded/1", ":code_server", "all_loaded", "1", "0"],
    [":code_server:archive_extension/0", ":code_server", "archive_extension", "0", "0"],
    [":code_server:archive_subdirs/1", ":code_server", "archive_subdirs", "1", "0"],
    [":code_server:cache_boot_paths/0", ":code_server", "cache_boot_paths", "0", "0"],
    [":code_server:cache_key/1", ":code_server", "cache_key", "1", "0"],
    [":code_server:cache_path/1", ":code_server", "cache_path", "1", "0"],
    [":code_server:call/1", ":code_server", "call", "1", "1"],
    [":code_server:check_pars/2", ":code_server", "check_pars", "2", "0"],
    [":code_server:check_path/1", ":code_server", "check_path", "1", "0"],
    [":code_server:choose/3", ":code_server", "choose", "3", "0"],
    [":code_server:choose_bundles/1", ":code_server", "choose_bundles", "1", "0"],
    [":code_server:create_bundle/2", ":code_server", "create_bundle", "2", "0"],
    [":code_server:create_namedb/2", ":code_server", "create_namedb", "2", "0"],
    [":code_server:del_ebin/1", ":code_server", "del_ebin", "1", "0"],
    [":code_server:del_ebin_1/1", ":code_server", "del_ebin_1", "1", "0"],
    [":code_server:del_path/4", ":code_server", "del_path", "4", "0"],
    [":code_server:del_path1/5", ":code_server", "del_path1", "5", "0"],
    [":code_server:del_paths/4", ":code_server", "del_paths", "4", "0"],
    [":code_server:delete_name/2", ":code_server", "delete_name", "2", "0"],
    [":code_server:delete_name_dir/2", ":code_server", "delete_name_dir", "2", "0"],
    [":code_server:discard_after_hyphen/1", ":code_server", "discard_after_hyphen", "1", "0"],
    [":code_server:do_add/6", ":code_server", "do_add", "6", "0"],
    [":code_server:do_cache_path/2", ":code_server", "do_cache_path", "2", "0"],
    [":code_server:do_check_path/4", ":code_server", "do_check_path", "4", "0"],
    [":code_server:do_dir/3", ":code_server", "do_dir", "3", "0"],
    [":code_server:do_finish_loading/2", ":code_server", "do_finish_loading", "2", "0"],
    [":code_server:do_insert_name/3", ":code_server", "do_insert_name", "3", "0"],
    [":code_server:do_purge/1", ":code_server", "do_purge", "1", "0"],
    [":code_server:do_soft_purge/1", ":code_server", "do_soft_purge", "1", "0"],
    [":code_server:do_sys_cmd/4", ":code_server", "do_sys_cmd", "4", "0"],
    [":code_server:error_msg/2", ":code_server", "error_msg", "2", "1"],
    [":code_server:exclude/2", ":code_server", "exclude", "2", "0"],
    [":code_server:exclude_pa_pz/3", ":code_server", "exclude_pa_pz", "3", "0"],
    [":code_server:finish_loading/3", ":code_server", "finish_loading", "3", "0"],
    [":code_server:finish_loading_ensure/2", ":code_server", "finish_loading_ensure", "2", "0"],
    [":code_server:finish_on_load_report/2", ":code_server", "finish_on_load_report", "2", "0"],
    [":code_server:gen_reply/2", ":code_server", "gen_reply", "2", "0"],
    [":code_server:get_arg/1", ":code_server", "get_arg", "1", "0"],
    [":code_server:get_mode/0", ":code_server", "get_mode", "0", "1"],
    [":code_server:get_mods/2", ":code_server", "get_mods", "2", "0"],
    [":code_server:get_name/1", ":code_server", "get_name", "1", "0"],
    [":code_server:get_name_from_splitted/1", ":code_server", "get_name_from_splitted", "1", "0"],
    [":code_server:get_object_code/2", ":code_server", "get_object_code", "2", "0"],
    [":code_server:get_user_lib_dirs/0", ":code_server", "get_user_lib_dirs", "0", "0"],
    [":code_server:get_user_lib_dirs_1/1", ":code_server", "get_user_lib_dirs_1", "1", "0"],
    [":code_server:handle_call/3", ":code_server", "handle_call", "3", "0"],
    [":code_server:handle_loader/4", ":code_server", "handle_loader", "4", "0"],
    [":code_server:handle_system_msg/5", ":code_server", "handle_system_msg", "5", "0"],
    [":code_server:info_msg/2", ":code_server", "info_msg", "2", "1"],
    [":code_server:init/3", ":code_server", "init", "3", "0"],
    [":code_server:init_namedb/2", ":code_server", "init_namedb", "2", "0"],
    [":code_server:insert_dir/2", ":code_server", "insert_dir", "2", "0"],
    [":code_server:insert_name/3", ":code_server", "insert_name", "3", "0"],
    [":code_server:insert_old_shadowed/3", ":code_server", "insert_old_shadowed", "3", "0"],
    [":code_server:is_dir/1", ":code_server", "is_dir", "1", "0"],
    [":code_server:is_loaded/1", ":code_server", "is_loaded", "1", "1"],
    [":code_server:is_numstr/1", ":code_server", "is_numstr", "1", "0"],
    [":code_server:is_sticky/1", ":code_server", "is_sticky", "1", "1"],
    [":code_server:is_sticky/2", ":code_server", "is_sticky", "2", "0"],
    [":code_server:is_vsn/1", ":code_server", "is_vsn", "1", "0"],
    [":code_server:join/2", ":code_server", "join", "2", "0"],
    [":code_server:lookup_name/2", ":code_server", "lookup_name", "2", "0"],
    [":code_server:loop/1", ":code_server", "loop", "1", "0"],
    [":code_server:make_path/2", ":code_server", "make_path", "2", "0"],
    [":code_server:make_path/3", ":code_server", "make_path", "3", "0"],
    [":code_server:maybe_update/2", ":code_server", "maybe_update", "2", "0"],
    [":code_server:merge_path/3", ":code_server", "merge_path", "3", "0"],
    [":code_server:merge_path1/3", ":code_server", "merge_path1", "3", "0"],
    [":code_server:mod_to_bin/3", ":code_server", "mod_to_bin", "3", "0"],
    [":code_server:module_info/0", ":code_server", "module_info", "0", "1"],
    [":code_server:module_info/1", ":code_server", "module_info", "1", "1"],
    [":code_server:objfile_extension/0", ":code_server", "objfile_extension", "0", "0"],
    [":code_server:on_load_down/3", ":code_server", "on_load_down", "3", "0"],
    [":code_server:patch_path/1", ":code_server", "patch_path", "1", "0"],
    [":code_server:replace_name/2", ":code_server", "replace_name", "2", "0"],
    [":code_server:replace_path/6", ":code_server", "replace_path", "6", "0"],
    [":code_server:replace_path1/7", ":code_server", "replace_path1", "7", "0"],
    [":code_server:reply/2", ":code_server", "reply", "2", "0"],
    [":code_server:run/2", ":code_server", "run", "2", "0"],
    [":code_server:run_loader/4", ":code_server", "run_loader", "4", "0"],
    [":code_server:run_loader_next/2", ":code_server", "run_loader_next", "2", "0"],
    [":code_server:schedule_on_load/4", ":code_server", "schedule_on_load", "4", "0"],
    [":code_server:schedule_or_run_loader/4", ":code_server", "schedule_or_run_loader", "4", "0"],
    [":code_server:set_path/5", ":code_server", "set_path", "5", "0"],
    [":code_server:split/2", ":code_server", "split", "2", "0"],
    [":code_server:split1/3", ":code_server", "split1", "3", "0"],
    [":code_server:split2/4", ":code_server", "split2", "4", "0"],
    [":code_server:split_base/1", ":code_server", "split_base", "1", "0"],
    [":code_server:split_paths/4", ":code_server", "split_paths", "4", "0"],
    [":code_server:start_link/1", ":code_server", "start_link", "1", "1"],
    [":code_server:stick_dir/3", ":code_server", "stick_dir", "3", "0"],
    [":code_server:stick_mod/3", ":code_server", "stick_mod", "3", "0"],
    [":code_server:store_module_and_reply/3", ":code_server", "store_module_and_reply", "3", "0"],
    [":code_server:strip_path/2", ":code_server", "strip_path", "2", "0"],
    [":code_server:suspend_loop/3", ":code_server", "suspend_loop", "3", "0"],
    [":code_server:system_code_change/4", ":code_server", "system_code_change", "4", "1"],
    [":code_server:system_continue/3", ":code_server", "system_continue", "3", "0"],
    [":code_server:system_terminate/4", ":code_server", "system_terminate", "4", "0"],
    [":code_server:to_list/1", ":code_server", "to_list", "1", "0"],
    [":code_server:try_archive_subdirs/3", ":code_server", "try_archive_subdirs", "3", "0"],
    [":code_server:try_ebin_dirs/1", ":code_server", "try_ebin_dirs", "1", "0"],
    [":code_server:update/2", ":code_server", "update", "2", "0"],
    [":code_server:vsn_to_num/1", ":code_server", "vsn_to_num", "1", "0"],
    [":code_server:where_is_file/3", ":code_server", "where_is_file", "3", "0"],
    [":code_server:with_cache/4", ":code_server", "with_cache", "4", "0"],
    [":dets_server:-handle_call/3-fun-0-/2", ":dets_server", "-handle_call/3-fun-0-", "2", "0"],
    [":dets_server:-handle_info/2-fun-0-/2", ":dets_server", "-handle_info/2-fun-0-", "2", "0"],
    [":dets_server:-handle_info/2-fun-1-/2", ":dets_server", "-handle_info/2-fun-1-", "2", "0"],
    [":dets_server:-pending_call/7-fun-0-/7", ":dets_server", "-pending_call/7-fun-0-", "7", "0"],
    [":dets_server:all/0", ":dets_server", "all", "0", "1"],
    [":dets_server:call/1", ":dets_server", "call", "1", "0"],
    [":dets_server:check_pending/4", ":dets_server", "check_pending", "4", "0"],
    [":dets_server:close/1", ":dets_server", "close", "1", "1"],
    [":dets_server:code_change/3", ":dets_server", "code_change", "3", "1"],
    [":dets_server:do_internal_open/3", ":dets_server", "do_internal_open", "3", "0"],
    [":dets_server:do_link/2", ":dets_server", "do_link", "2", "0"],
    [":dets_server:do_open/5", ":dets_server", "do_open", "5", "0"],
    [":dets_server:do_unlink/2", ":dets_server", "do_unlink", "2", "0"],
    [":dets_server:ensure_started/0", ":dets_server", "ensure_started", "0", "0"],
    [":dets_server:get_pid/1", ":dets_server", "get_pid", "1", "1"],
    [":dets_server:handle_call/3", ":dets_server", "handle_call", "3", "1"],
    [":dets_server:handle_cast/2", ":dets_server", "handle_cast", "2", "1"],
    [":dets_server:handle_close/4", ":dets_server", "handle_close", "4", "0"],
    [":dets_server:handle_info/2", ":dets_server", "handle_info", "2", "1"],
    [":dets_server:init/0", ":dets_server", "init", "0", "0"],
    [":dets_server:init/1", ":dets_server", "init", "1", "1"],
    [":dets_server:module_info/0", ":dets_server", "module_info", "0", "1"],
    [":dets_server:module_info/1", ":dets_server", "module_info", "1", "1"],
    [":dets_server:open_file/1", ":dets_server", "open_file", "1", "1"],
    [":dets_server:open_file/2", ":dets_server", "open_file", "2", "1"],
    [":dets_server:pending_call/7", ":dets_server", "pending_call", "7", "0"],
    [":dets_server:pid2name/1", ":dets_server", "pid2name", "1", "1"],
    [":dets_server:request/2", ":dets_server", "request", "2", "0"],
    [":dets_server:set_verbose/1", ":dets_server", "set_verbose", "1", "0"],
    [":dets_server:start/0", ":dets_server", "start", "0", "1"],
    [":dets_server:start_link/0", ":dets_server", "start_link", "0", "1"],
    [":dets_server:stop/0", ":dets_server", "stop", "0", "1"],
    [":dets_server:terminate/2", ":dets_server", "terminate", "2", "1"],
    [":dets_server:users/1", ":dets_server", "users", "1", "1"],
    [":dets_server:verbose/1", ":dets_server", "verbose", "1", "1"],
    [":dets_server:verbose_flag/0", ":dets_server", "verbose_flag", "0", "0"],
    [":dist_ac:-del_t_reqs/3-fun-0-/3", ":dist_ac", "-del_t_reqs/3-fun-0-", "3", "0"],
    [":dist_ac:-dist_del_node/2-fun-0-/2", ":dist_ac", "-dist_del_node/2-fun-0-", "2", "0"],
    [":dist_ac:-dist_del_node/2-fun-1-/2", ":dist_ac", "-dist_del_node/2-fun-1-", "2", "0"],
    [
      ":dist_ac:-dist_get_runnable/1-fun-0-/1",
      ":dist_ac",
      "-dist_get_runnable/1-fun-0-",
      "1",
      "0"
    ],
    [
      ":dist_ac:-dist_get_runnable_nodes/2-fun-0-/1",
      ":dist_ac",
      "-dist_get_runnable_nodes/2-fun-0-",
      "1",
      "0"
    ],
    [":dist_ac:-dist_merge/3-fun-0-/3", ":dist_ac", "-dist_merge/3-fun-0-", "3", "0"],
    [":dist_ac:-dist_replace/3-lc$^0/1-0-/1", ":dist_ac", "-dist_replace/3-lc$^0/1-0-", "1", "0"],
    [":dist_ac:-dist_replace/3-lc$^1/1-1-/1", ":dist_ac", "-dist_replace/3-lc$^1/1-1-", "1", "0"],
    [
      ":dist_ac:-dist_take_control/1-fun-0-/1",
      ":dist_ac",
      "-dist_take_control/1-fun-0-",
      "1",
      "0"
    ],
    [":dist_ac:-dist_update_run/4-fun-0-/4", ":dist_ac", "-dist_update_run/4-fun-0-", "4", "0"],
    [
      ":dist_ac:-do_dist_change_update/4-fun-0-/4",
      ":dist_ac",
      "-do_dist_change_update/4-fun-0-",
      "4",
      "0"
    ],
    [":dist_ac:-do_start_appls/2-fun-0-/2", ":dist_ac", "-do_start_appls/2-fun-0-", "2", "0"],
    [":dist_ac:-flat_nodes/1-fun-0-/2", ":dist_ac", "-flat_nodes/1-fun-0-", "2", "0"],
    [":dist_ac:-handle_info/2-fun-0-/2", ":dist_ac", "-handle_info/2-fun-0-", "2", "0"],
    [":dist_ac:-handle_info/2-fun-1-/2", ":dist_ac", "-handle_info/2-fun-1-", "2", "0"],
    [":dist_ac:-handle_info/2-fun-2-/1", ":dist_ac", "-handle_info/2-fun-2-", "1", "0"],
    [":dist_ac:-handle_info/2-fun-3-/3", ":dist_ac", "-handle_info/2-fun-3-", "3", "0"],
    [":dist_ac:-handle_info/2-fun-4-/3", ":dist_ac", "-handle_info/2-fun-4-", "3", "0"],
    [":dist_ac:-handle_info/2-fun-5-/2", ":dist_ac", "-handle_info/2-fun-5-", "2", "0"],
    [":dist_ac:-introduce_me/2-fun-0-/2", ":dist_ac", "-introduce_me/2-fun-0-", "2", "0"],
    [":dist_ac:-load/2-fun-0-/4", ":dist_ac", "-load/2-fun-0-", "4", "0"],
    [":dist_ac:-load/2-fun-1-/5", ":dist_ac", "-load/2-fun-1-", "5", "0"],
    [":dist_ac:-load/2-inlined-0-/2", ":dist_ac", "-load/2-inlined-0-", "2", "0"],
    [
      ":dist_ac:-permit_application/2-fun-0-/3",
      ":dist_ac",
      "-permit_application/2-fun-0-",
      "3",
      "0"
    ],
    [
      ":dist_ac:-permit_only_loaded_application/2-fun-0-/3",
      ":dist_ac",
      "-permit_only_loaded_application/2-fun-0-",
      "3",
      "0"
    ],
    [
      ":dist_ac:-req_del_permit_false/2-fun-0-/2",
      ":dist_ac",
      "-req_del_permit_false/2-fun-0-",
      "2",
      "0"
    ],
    [
      ":dist_ac:-req_del_permit_true/2-fun-0-/2",
      ":dist_ac",
      "-req_del_permit_true/2-fun-0-",
      "2",
      "0"
    ],
    [":dist_ac:-req_start_app/2-fun-0-/3", ":dist_ac", "-req_start_app/2-fun-0-", "3", "0"],
    [":dist_ac:-restart_appls/1-fun-0-/1", ":dist_ac", "-restart_appls/1-fun-0-", "1", "0"],
    [":dist_ac:-send_msg/2-fun-0-/2", ":dist_ac", "-send_msg/2-fun-0-", "2", "0"],
    [":dist_ac:-send_nodes/2-fun-0-/2", ":dist_ac", "-send_nodes/2-fun-0-", "2", "0"],
    [":dist_ac:-sync_dacs/1-fun-0-/1", ":dist_ac", "-sync_dacs/1-fun-0-", "1", "0"],
    [
      ":dist_ac:-takeover_application/2-fun-0-/2",
      ":dist_ac",
      "-takeover_application/2-fun-0-",
      "2",
      "0"
    ],
    [":dist_ac:-wait_dist_start/7-fun-0-/3", ":dist_ac", "-wait_dist_start/7-fun-0-", "3", "0"],
    [":dist_ac:-wait_dist_start2/6-fun-0-/3", ":dist_ac", "-wait_dist_start2/6-fun-0-", "3", "0"],
    [":dist_ac:ac_error/3", ":dist_ac", "ac_error", "3", "0"],
    [":dist_ac:ac_failover/3", ":dist_ac", "ac_failover", "3", "0"],
    [":dist_ac:ac_not_running/1", ":dist_ac", "ac_not_running", "1", "0"],
    [":dist_ac:ac_not_started/2", ":dist_ac", "ac_not_started", "2", "0"],
    [":dist_ac:ac_start_it/2", ":dist_ac", "ac_start_it", "2", "0"],
    [":dist_ac:ac_started/3", ":dist_ac", "ac_started", "3", "0"],
    [":dist_ac:ac_stop_it/1", ":dist_ac", "ac_stop_it", "1", "0"],
    [":dist_ac:ac_takeover/4", ":dist_ac", "ac_takeover", "4", "0"],
    [":dist_ac:check_nodes/3", ":dist_ac", "check_nodes", "3", "0"],
    [":dist_ac:check_running/3", ":dist_ac", "check_running", "3", "0"],
    [":dist_ac:check_waiting/6", ":dist_ac", "check_waiting", "6", "0"],
    [":dist_ac:code_change/3", ":dist_ac", "code_change", "3", "1"],
    [":dist_ac:collect_answers/4", ":dist_ac", "collect_answers", "4", "0"],
    [":dist_ac:del_dist_loaded/2", ":dist_ac", "del_dist_loaded", "2", "0"],
    [":dist_ac:del_t_reqs/3", ":dist_ac", "del_t_reqs", "3", "0"],
    [":dist_ac:dist_change_update/2", ":dist_ac", "dist_change_update", "2", "0"],
    [":dist_ac:dist_check/1", ":dist_ac", "dist_check", "1", "0"],
    [":dist_ac:dist_del_node/2", ":dist_ac", "dist_del_node", "2", "0"],
    [":dist_ac:dist_find_nodes/2", ":dist_ac", "dist_find_nodes", "2", "0"],
    [":dist_ac:dist_flat_nodes/2", ":dist_ac", "dist_flat_nodes", "2", "0"],
    [":dist_ac:dist_get_all_nodes/1", ":dist_ac", "dist_get_all_nodes", "1", "0"],
    [":dist_ac:dist_get_runnable/1", ":dist_ac", "dist_get_runnable", "1", "0"],
    [":dist_ac:dist_get_runnable_nodes/2", ":dist_ac", "dist_get_runnable_nodes", "2", "0"],
    [":dist_ac:dist_is_runnable/2", ":dist_ac", "dist_is_runnable", "2", "0"],
    [":dist_ac:dist_merge/3", ":dist_ac", "dist_merge", "3", "0"],
    [":dist_ac:dist_mismatch/2", ":dist_ac", "dist_mismatch", "2", "0"],
    [":dist_ac:dist_replace/3", ":dist_ac", "dist_replace", "3", "0"],
    [":dist_ac:dist_take_control/1", ":dist_ac", "dist_take_control", "1", "0"],
    [":dist_ac:dist_update_run/4", ":dist_ac", "dist_update_run", "4", "0"],
    [":dist_ac:do_dist_change_update/4", ":dist_ac", "do_dist_change_update", "4", "0"],
    [":dist_ac:do_start_appls/2", ":dist_ac", "do_start_appls", "2", "0"],
    [":dist_ac:ensure_take_control/2", ":dist_ac", "ensure_take_control", "2", "0"],
    [":dist_ac:equal/2", ":dist_ac", "equal", "2", "0"],
    [":dist_ac:equal_nodes/2", ":dist_ac", "equal_nodes", "2", "0"],
    [":dist_ac:error_msg/2", ":dist_ac", "error_msg", "2", "0"],
    [":dist_ac:find_alive_node/2", ":dist_ac", "find_alive_node", "2", "0"],
    [":dist_ac:find_any_node/5", ":dist_ac", "find_any_node", "5", "0"],
    [":dist_ac:find_start_node/4", ":dist_ac", "find_start_node", "4", "0"],
    [":dist_ac:find_start_node/5", ":dist_ac", "find_start_node", "5", "0"],
    [":dist_ac:flat_nodes/1", ":dist_ac", "flat_nodes", "1", "0"],
    [":dist_ac:get_cached_weight/2", ":dist_ac", "get_cached_weight", "2", "0"],
    [":dist_ac:get_default_permission/1", ":dist_ac", "get_default_permission", "1", "0"],
    [":dist_ac:get_dist_loaded/2", ":dist_ac", "get_dist_loaded", "2", "0"],
    [":dist_ac:get_known_nodes/0", ":dist_ac", "get_known_nodes", "0", "1"],
    [":dist_ac:get_nodes/1", ":dist_ac", "get_nodes", "1", "0"],
    [":dist_ac:get_weight/0", ":dist_ac", "get_weight", "0", "0"],
    [":dist_ac:handle_call/3", ":dist_ac", "handle_call", "3", "1"],
    [":dist_ac:handle_cast/2", ":dist_ac", "handle_cast", "2", "1"],
    [":dist_ac:handle_info/2", ":dist_ac", "handle_info", "2", "1"],
    [":dist_ac:info/0", ":dist_ac", "info", "0", "1"],
    [":dist_ac:init/1", ":dist_ac", "init", "1", "1"],
    [":dist_ac:intersection/2", ":dist_ac", "intersection", "2", "0"],
    [":dist_ac:introduce_me/2", ":dist_ac", "introduce_me", "2", "0"],
    [":dist_ac:is_loaded/2", ":dist_ac", "is_loaded", "2", "0"],
    [":dist_ac:keydelete_all/3", ":dist_ac", "keydelete_all", "3", "0"],
    [":dist_ac:keyreplaceadd/4", ":dist_ac", "keyreplaceadd", "4", "0"],
    [":dist_ac:load/2", ":dist_ac", "load", "2", "0"],
    [":dist_ac:load_application/2", ":dist_ac", "load_application", "2", "1"],
    [":dist_ac:module_info/0", ":dist_ac", "module_info", "0", "1"],
    [":dist_ac:module_info/1", ":dist_ac", "module_info", "1", "1"],
    [":dist_ac:permit/6", ":dist_ac", "permit", "6", "0"],
    [":dist_ac:permit_application/2", ":dist_ac", "permit_application", "2", "1"],
    [
      ":dist_ac:permit_only_loaded_application/2",
      ":dist_ac",
      "permit_only_loaded_application",
      "2",
      "1"
    ],
    [":dist_ac:replaceadd/2", ":dist_ac", "replaceadd", "2", "0"],
    [":dist_ac:req_del_node/3", ":dist_ac", "req_del_node", "3", "0"],
    [":dist_ac:req_del_permit_false/2", ":dist_ac", "req_del_permit_false", "2", "0"],
    [":dist_ac:req_del_permit_true/2", ":dist_ac", "req_del_permit_true", "2", "0"],
    [":dist_ac:req_start_app/2", ":dist_ac", "req_start_app", "2", "0"],
    [":dist_ac:restart_appl/2", ":dist_ac", "restart_appl", "2", "0"],
    [":dist_ac:restart_appls/1", ":dist_ac", "restart_appls", "1", "0"],
    [":dist_ac:send_after/2", ":dist_ac", "send_after", "2", "0"],
    [":dist_ac:send_msg/2", ":dist_ac", "send_msg", "2", "0"],
    [":dist_ac:send_nodes/2", ":dist_ac", "send_nodes", "2", "0"],
    [":dist_ac:send_timeout/3", ":dist_ac", "send_timeout", "3", "1"],
    [":dist_ac:start_appl/3", ":dist_ac", "start_appl", "3", "0"],
    [":dist_ac:start_distributed/6", ":dist_ac", "start_distributed", "6", "0"],
    [":dist_ac:start_link/0", ":dist_ac", "start_link", "0", "1"],
    [":dist_ac:sync_dacs/1", ":dist_ac", "sync_dacs", "1", "0"],
    [":dist_ac:takeover_application/2", ":dist_ac", "takeover_application", "2", "1"],
    [":dist_ac:terminate/2", ":dist_ac", "terminate", "2", "1"],
    [":dist_ac:unload/2", ":dist_ac", "unload", "2", "0"],
    [":dist_ac:valid_restart_type/1", ":dist_ac", "valid_restart_type", "1", "0"],
    [":dist_ac:wait_dacs/4", ":dist_ac", "wait_dacs", "4", "0"],
    [":dist_ac:wait_dist_start/7", ":dist_ac", "wait_dist_start", "7", "0"],
    [":dist_ac:wait_dist_start2/6", ":dist_ac", "wait_dist_start2", "6", "0"],
    [":dist_ac:wait_for_sync_dacs/0", ":dist_ac", "wait_for_sync_dacs", "0", "0"],
    [
      ":ejabberd_hooks:-call_subscriber_list/6-lc$^0/1-0-/1",
      ":ejabberd_hooks",
      "-call_subscriber_list/6-lc$^0/1-0-",
      "1",
      "0"
    ],
    [
      ":ejabberd_hooks:-do_trace_on/4-fun-0-/4",
      ":ejabberd_hooks",
      "-do_trace_on/4-fun-0-",
      "4",
      "0"
    ],
    [
      ":ejabberd_hooks:-run_event_handlers/6-fun-0-/8",
      ":ejabberd_hooks",
      "-run_event_handlers/6-fun-0-",
      "8",
      "0"
    ],
    [
      ":ejabberd_hooks:-safe_apply/4-lc$^0/1-0-/1",
      ":ejabberd_hooks",
      "-safe_apply/4-lc$^0/1-0-",
      "1",
      "0"
    ],
    [
      ":ejabberd_hooks:-safe_apply/4-lc$^1/1-1-/1",
      ":ejabberd_hooks",
      "-safe_apply/4-lc$^1/1-1-",
      "1",
      "0"
    ],
    [":ejabberd_hooks:-trace_off/3-fun-0-/3", ":ejabberd_hooks", "-trace_off/3-fun-0-", "3", "0"],
    [":ejabberd_hooks:-trace_on/5-fun-0-/5", ":ejabberd_hooks", "-trace_on/5-fun-0-", "5", "0"],
    [
      ":ejabberd_hooks:-tracing_timing_event_handler/7-fun-0-/2",
      ":ejabberd_hooks",
      "-tracing_timing_event_handler/7-fun-0-",
      "2",
      "0"
    ],
    [
      ":ejabberd_hooks:-tracing_timing_event_handler/7-fun-2-/2",
      ":ejabberd_hooks",
      "-tracing_timing_event_handler/7-fun-2-",
      "2",
      "0"
    ],
    [
      ":ejabberd_hooks:-tracing_timing_event_handler/7-lc$^1/1-2-/1",
      ":ejabberd_hooks",
      "-tracing_timing_event_handler/7-lc$^1/1-2-",
      "1",
      "0"
    ],
    [":ejabberd_hooks:add/3", ":ejabberd_hooks", "add", "3", "1"],
    [":ejabberd_hooks:add/4", ":ejabberd_hooks", "add", "4", "1"],
    [":ejabberd_hooks:add/5", ":ejabberd_hooks", "add", "5", "1"],
    [
      ":ejabberd_hooks:call_subscriber_list/6",
      ":ejabberd_hooks",
      "call_subscriber_list",
      "6",
      "0"
    ],
    [":ejabberd_hooks:code_change/3", ":ejabberd_hooks", "code_change", "3", "1"],
    [
      ":ejabberd_hooks:default_tracing_event_handler_list/0",
      ":ejabberd_hooks",
      "default_tracing_event_handler_list",
      "0",
      "0"
    ],
    [":ejabberd_hooks:delete/3", ":ejabberd_hooks", "delete", "3", "1"],
    [":ejabberd_hooks:delete/4", ":ejabberd_hooks", "delete", "4", "1"],
    [":ejabberd_hooks:delete/5", ":ejabberd_hooks", "delete", "5", "1"],
    [
      ":ejabberd_hooks:do_get_tracing_options/3",
      ":ejabberd_hooks",
      "do_get_tracing_options",
      "3",
      "0"
    ],
    [":ejabberd_hooks:do_trace_off/2", ":ejabberd_hooks", "do_trace_off", "2", "0"],
    [":ejabberd_hooks:do_trace_on/4", ":ejabberd_hooks", "do_trace_on", "4", "0"],
    [
      ":ejabberd_hooks:fold_start_callback_tracing/7",
      ":ejabberd_hooks",
      "fold_start_callback_tracing",
      "7",
      "0"
    ],
    [
      ":ejabberd_hooks:fold_start_hook_tracing/4",
      ":ejabberd_hooks",
      "fold_start_hook_tracing",
      "4",
      "0"
    ],
    [
      ":ejabberd_hooks:fold_stop_callback_tracing/8",
      ":ejabberd_hooks",
      "fold_stop_callback_tracing",
      "8",
      "0"
    ],
    [
      ":ejabberd_hooks:fold_stop_hook_tracing/5",
      ":ejabberd_hooks",
      "fold_stop_hook_tracing",
      "5",
      "0"
    ],
    [
      ":ejabberd_hooks:foreach_start_callback_tracing/7",
      ":ejabberd_hooks",
      "foreach_start_callback_tracing",
      "7",
      "0"
    ],
    [
      ":ejabberd_hooks:foreach_start_hook_tracing/4",
      ":ejabberd_hooks",
      "foreach_start_hook_tracing",
      "4",
      "0"
    ],
    [
      ":ejabberd_hooks:foreach_stop_callback_tracing/8",
      ":ejabberd_hooks",
      "foreach_stop_callback_tracing",
      "8",
      "0"
    ],
    [
      ":ejabberd_hooks:foreach_stop_hook_tracing/5",
      ":ejabberd_hooks",
      "foreach_stop_hook_tracing",
      "5",
      "0"
    ],
    [
      ":ejabberd_hooks:format_arg_for_exception/1",
      ":ejabberd_hooks",
      "format_arg_for_exception",
      "1",
      "0"
    ],
    [":ejabberd_hooks:get_tracing_options/3", ":ejabberd_hooks", "get_tracing_options", "3", "1"],
    [":ejabberd_hooks:handle_add/3", ":ejabberd_hooks", "handle_add", "3", "0"],
    [":ejabberd_hooks:handle_call/3", ":ejabberd_hooks", "handle_call", "3", "1"],
    [":ejabberd_hooks:handle_cast/2", ":ejabberd_hooks", "handle_cast", "2", "1"],
    [":ejabberd_hooks:handle_delete/3", ":ejabberd_hooks", "handle_delete", "3", "0"],
    [":ejabberd_hooks:handle_info/2", ":ejabberd_hooks", "handle_info", "2", "1"],
    [":ejabberd_hooks:handle_subscribe/3", ":ejabberd_hooks", "handle_subscribe", "3", "0"],
    [":ejabberd_hooks:handle_unsubscribe/3", ":ejabberd_hooks", "handle_unsubscribe", "3", "0"],
    [
      ":ejabberd_hooks:human_readable_time_string/1",
      ":ejabberd_hooks",
      "human_readable_time_string",
      "1",
      "1"
    ],
    [":ejabberd_hooks:init/1", ":ejabberd_hooks", "init", "1", "1"],
    [":ejabberd_hooks:mfa_string/1", ":ejabberd_hooks", "mfa_string", "1", "0"],
    [":ejabberd_hooks:module_info/0", ":ejabberd_hooks", "module_info", "0", "1"],
    [":ejabberd_hooks:module_info/1", ":ejabberd_hooks", "module_info", "1", "1"],
    [":ejabberd_hooks:run/2", ":ejabberd_hooks", "run", "2", "1"],
    [":ejabberd_hooks:run/3", ":ejabberd_hooks", "run", "3", "1"],
    [":ejabberd_hooks:run1/3", ":ejabberd_hooks", "run1", "3", "0"],
    [":ejabberd_hooks:run1/5", ":ejabberd_hooks", "run1", "5", "0"],
    [":ejabberd_hooks:run2/6", ":ejabberd_hooks", "run2", "6", "0"],
    [":ejabberd_hooks:run_event_handlers/6", ":ejabberd_hooks", "run_event_handlers", "6", "0"],
    [":ejabberd_hooks:run_fold/3", ":ejabberd_hooks", "run_fold", "3", "1"],
    [":ejabberd_hooks:run_fold/4", ":ejabberd_hooks", "run_fold", "4", "1"],
    [":ejabberd_hooks:run_fold1/4", ":ejabberd_hooks", "run_fold1", "4", "0"],
    [":ejabberd_hooks:run_fold1/6", ":ejabberd_hooks", "run_fold1", "6", "0"],
    [":ejabberd_hooks:run_fold2/7", ":ejabberd_hooks", "run_fold2", "7", "0"],
    [":ejabberd_hooks:safe_apply/4", ":ejabberd_hooks", "safe_apply", "4", "0"],
    [":ejabberd_hooks:start_link/0", ":ejabberd_hooks", "start_link", "0", "1"],
    [":ejabberd_hooks:subscribe/4", ":ejabberd_hooks", "subscribe", "4", "1"],
    [":ejabberd_hooks:subscribe/5", ":ejabberd_hooks", "subscribe", "5", "1"],
    [":ejabberd_hooks:terminate/2", ":ejabberd_hooks", "terminate", "2", "1"],
    [":ejabberd_hooks:trace_off/3", ":ejabberd_hooks", "trace_off", "3", "1"],
    [":ejabberd_hooks:trace_on/5", ":ejabberd_hooks", "trace_on", "5", "1"],
    [":ejabberd_hooks:tracing_output/3", ":ejabberd_hooks", "tracing_output", "3", "0"],
    [
      ":ejabberd_hooks:tracing_timing_event_handler/7",
      ":ejabberd_hooks",
      "tracing_timing_event_handler",
      "7",
      "0"
    ],
    [":ejabberd_hooks:unsubscribe/4", ":ejabberd_hooks", "unsubscribe", "4", "1"],
    [":ejabberd_hooks:unsubscribe/5", ":ejabberd_hooks", "unsubscribe", "5", "1"],
    [
      ":rabbit_disk_monitor:-get_disk_free/3-fun-0-/2",
      ":rabbit_disk_monitor",
      "-get_disk_free/3-fun-0-",
      "2",
      "0"
    ],
    [
      ":rabbit_disk_monitor:-run_os_cmd/1-fun-0-/3",
      ":rabbit_disk_monitor",
      "-run_os_cmd/1-fun-0-",
      "3",
      "0"
    ],
    [":rabbit_disk_monitor:code_change/3", ":rabbit_disk_monitor", "code_change", "3", "1"],
    [":rabbit_disk_monitor:dir/0", ":rabbit_disk_monitor", "dir", "0", "0"],
    [
      ":rabbit_disk_monitor:emit_update_info/3",
      ":rabbit_disk_monitor",
      "emit_update_info",
      "3",
      "0"
    ],
    [":rabbit_disk_monitor:enable/1", ":rabbit_disk_monitor", "enable", "1", "0"],
    [
      ":rabbit_disk_monitor:enable_handle_disk_free/2",
      ":rabbit_disk_monitor",
      "enable_handle_disk_free",
      "2",
      "0"
    ],
    [
      ":rabbit_disk_monitor:enable_handle_total_memory/3",
      ":rabbit_disk_monitor",
      "enable_handle_total_memory",
      "3",
      "0"
    ],
    [":rabbit_disk_monitor:find_cmd/1", ":rabbit_disk_monitor", "find_cmd", "1", "0"],
    [":rabbit_disk_monitor:get_disk_free/0", ":rabbit_disk_monitor", "get_disk_free", "0", "1"],
    [":rabbit_disk_monitor:get_disk_free/3", ":rabbit_disk_monitor", "get_disk_free", "3", "0"],
    [
      ":rabbit_disk_monitor:get_disk_free_limit/0",
      ":rabbit_disk_monitor",
      "get_disk_free_limit",
      "0",
      "1"
    ],
    [
      ":rabbit_disk_monitor:get_max_check_interval/0",
      ":rabbit_disk_monitor",
      "get_max_check_interval",
      "0",
      "1"
    ],
    [
      ":rabbit_disk_monitor:get_min_check_interval/0",
      ":rabbit_disk_monitor",
      "get_min_check_interval",
      "0",
      "1"
    ],
    [":rabbit_disk_monitor:get_reply/2", ":rabbit_disk_monitor", "get_reply", "2", "0"],
    [":rabbit_disk_monitor:handle_call/3", ":rabbit_disk_monitor", "handle_call", "3", "1"],
    [":rabbit_disk_monitor:handle_cast/2", ":rabbit_disk_monitor", "handle_cast", "2", "1"],
    [":rabbit_disk_monitor:handle_info/2", ":rabbit_disk_monitor", "handle_info", "2", "1"],
    [":rabbit_disk_monitor:init/1", ":rabbit_disk_monitor", "init", "1", "1"],
    [
      ":rabbit_disk_monitor:internal_update/1",
      ":rabbit_disk_monitor",
      "internal_update",
      "1",
      "0"
    ],
    [
      ":rabbit_disk_monitor:interpret_limit/1",
      ":rabbit_disk_monitor",
      "interpret_limit",
      "1",
      "0"
    ],
    [":rabbit_disk_monitor:interval/1", ":rabbit_disk_monitor", "interval", "1", "0"],
    [":rabbit_disk_monitor:module_info/0", ":rabbit_disk_monitor", "module_info", "0", "1"],
    [":rabbit_disk_monitor:module_info/1", ":rabbit_disk_monitor", "module_info", "1", "1"],
    [":rabbit_disk_monitor:newline/2", ":rabbit_disk_monitor", "newline", "2", "0"],
    [
      ":rabbit_disk_monitor:parse_free_unix/1",
      ":rabbit_disk_monitor",
      "parse_free_unix",
      "1",
      "0"
    ],
    [":rabbit_disk_monitor:run_os_cmd/1", ":rabbit_disk_monitor", "run_os_cmd", "1", "0"],
    [":rabbit_disk_monitor:run_port_cmd/2", ":rabbit_disk_monitor", "run_port_cmd", "2", "0"],
    [
      ":rabbit_disk_monitor:safe_ets_lookup/2",
      ":rabbit_disk_monitor",
      "safe_ets_lookup",
      "2",
      "0"
    ],
    [
      ":rabbit_disk_monitor:set_disk_free_limit/1",
      ":rabbit_disk_monitor",
      "set_disk_free_limit",
      "1",
      "1"
    ],
    [
      ":rabbit_disk_monitor:set_disk_limits/2",
      ":rabbit_disk_monitor",
      "set_disk_limits",
      "2",
      "0"
    ],
    [":rabbit_disk_monitor:set_enabled/1", ":rabbit_disk_monitor", "set_enabled", "1", "1"],
    [
      ":rabbit_disk_monitor:set_max_check_interval/1",
      ":rabbit_disk_monitor",
      "set_max_check_interval",
      "1",
      "1"
    ],
    [
      ":rabbit_disk_monitor:set_max_check_interval/2",
      ":rabbit_disk_monitor",
      "set_max_check_interval",
      "2",
      "0"
    ],
    [
      ":rabbit_disk_monitor:set_min_check_interval/1",
      ":rabbit_disk_monitor",
      "set_min_check_interval",
      "1",
      "1"
    ],
    [
      ":rabbit_disk_monitor:set_min_check_interval/2",
      ":rabbit_disk_monitor",
      "set_min_check_interval",
      "2",
      "0"
    ],
    [":rabbit_disk_monitor:start_link/1", ":rabbit_disk_monitor", "start_link", "1", "1"],
    [
      ":rabbit_disk_monitor:start_portprogram/0",
      ":rabbit_disk_monitor",
      "start_portprogram",
      "0",
      "0"
    ],
    [":rabbit_disk_monitor:start_timer/1", ":rabbit_disk_monitor", "start_timer", "1", "0"],
    [":rabbit_disk_monitor:terminate/2", ":rabbit_disk_monitor", "terminate", "2", "1"],
    [
      ":rabbit_disk_monitor:win32_get_disk_free_dir/1",
      ":rabbit_disk_monitor",
      "win32_get_disk_free_dir",
      "1",
      "0"
    ],
    [
      ":rabbit_disk_monitor:win32_get_drive_letter/1",
      ":rabbit_disk_monitor",
      "win32_get_drive_letter",
      "1",
      "0"
    ],
    [":rabbit_guid:advance_blocks/2", ":rabbit_guid", "advance_blocks", "2", "0"],
    [":rabbit_guid:binary/2", ":rabbit_guid", "binary", "2", "1"],
    [":rabbit_guid:code_change/3", ":rabbit_guid", "code_change", "3", "1"],
    [":rabbit_guid:filename/0", ":rabbit_guid", "filename", "0", "1"],
    [":rabbit_guid:fresh/0", ":rabbit_guid", "fresh", "0", "0"],
    [":rabbit_guid:gen/0", ":rabbit_guid", "gen", "0", "1"],
    [":rabbit_guid:gen_secure/0", ":rabbit_guid", "gen_secure", "0", "1"],
    [":rabbit_guid:handle_call/3", ":rabbit_guid", "handle_call", "3", "1"],
    [":rabbit_guid:handle_cast/2", ":rabbit_guid", "handle_cast", "2", "1"],
    [":rabbit_guid:handle_info/2", ":rabbit_guid", "handle_info", "2", "1"],
    [":rabbit_guid:init/1", ":rabbit_guid", "init", "1", "1"],
    [":rabbit_guid:module_info/0", ":rabbit_guid", "module_info", "0", "1"],
    [":rabbit_guid:module_info/1", ":rabbit_guid", "module_info", "1", "1"],
    [":rabbit_guid:start_link/0", ":rabbit_guid", "start_link", "0", "1"],
    [":rabbit_guid:string/2", ":rabbit_guid", "string", "2", "1"],
    [":rabbit_guid:terminate/2", ":rabbit_guid", "terminate", "2", "1"],
    [":rabbit_guid:to_string/1", ":rabbit_guid", "to_string", "1", "1"],
    [":rabbit_guid:update_disk_serial/0", ":rabbit_guid", "update_disk_serial", "0", "0"],
    [
      "DBConnection.ConnectionPool:-drop_idle/6-fun-0-/5",
      "DBConnection.ConnectionPool",
      "-drop_idle/6-fun-0-",
      "5",
      "0"
    ],
    [
      "DBConnection.ConnectionPool:-drop_slow/3-fun-0-/3",
      "DBConnection.ConnectionPool",
      "-drop_slow/3-fun-0-",
      "3",
      "0"
    ],
    [
      "DBConnection.ConnectionPool:-init/1-fun-0-/1",
      "DBConnection.ConnectionPool",
      "-init/1-fun-0-",
      "1",
      "0"
    ],
    [
      "DBConnection.ConnectionPool:-inlined-__info__/1-/1",
      "DBConnection.ConnectionPool",
      "-inlined-__info__/1-",
      "1",
      "0"
    ],
    [
      "DBConnection.ConnectionPool:__info__/1",
      "DBConnection.ConnectionPool",
      "__info__",
      "1",
      "1"
    ],
    [
      "DBConnection.ConnectionPool:ancestor/0",
      "DBConnection.ConnectionPool",
      "ancestor",
      "0",
      "0"
    ],
    [
      "DBConnection.ConnectionPool:checkout/3",
      "DBConnection.ConnectionPool",
      "checkout",
      "3",
      "1"
    ],
    [
      "DBConnection.ConnectionPool:child_spec/1",
      "DBConnection.ConnectionPool",
      "child_spec",
      "1",
      "1"
    ],
    [
      "DBConnection.ConnectionPool:code_change/3",
      "DBConnection.ConnectionPool",
      "code_change",
      "3",
      "1"
    ],
    ["DBConnection.ConnectionPool:dequeue/5", "DBConnection.ConnectionPool", "dequeue", "5", "0"],
    [
      "DBConnection.ConnectionPool:dequeue_fast/5",
      "DBConnection.ConnectionPool",
      "dequeue_fast",
      "5",
      "0"
    ],
    [
      "DBConnection.ConnectionPool:dequeue_first/6",
      "DBConnection.ConnectionPool",
      "dequeue_first",
      "6",
      "0"
    ],
    [
      "DBConnection.ConnectionPool:dequeue_slow/6",
      "DBConnection.ConnectionPool",
      "dequeue_slow",
      "6",
      "0"
    ],
    [
      "DBConnection.ConnectionPool:disconnect_all/3",
      "DBConnection.ConnectionPool",
      "disconnect_all",
      "3",
      "1"
    ],
    ["DBConnection.ConnectionPool:drop/2", "DBConnection.ConnectionPool", "drop", "2", "0"],
    [
      "DBConnection.ConnectionPool:drop_idle/6",
      "DBConnection.ConnectionPool",
      "drop_idle",
      "6",
      "0"
    ],
    [
      "DBConnection.ConnectionPool:drop_slow/3",
      "DBConnection.ConnectionPool",
      "drop_slow",
      "3",
      "0"
    ],
    [
      "DBConnection.ConnectionPool:get_connection_metrics/1",
      "DBConnection.ConnectionPool",
      "get_connection_metrics",
      "1",
      "1"
    ],
    ["DBConnection.ConnectionPool:go/7", "DBConnection.ConnectionPool", "go", "7", "0"],
    [
      "DBConnection.ConnectionPool:handle_call/3",
      "DBConnection.ConnectionPool",
      "handle_call",
      "3",
      "1"
    ],
    [
      "DBConnection.ConnectionPool:handle_cast/2",
      "DBConnection.ConnectionPool",
      "handle_cast",
      "2",
      "1"
    ],
    [
      "DBConnection.ConnectionPool:handle_checkin/3",
      "DBConnection.ConnectionPool",
      "handle_checkin",
      "3",
      "0"
    ],
    [
      "DBConnection.ConnectionPool:handle_info/2",
      "DBConnection.ConnectionPool",
      "handle_info",
      "2",
      "1"
    ],
    ["DBConnection.ConnectionPool:init/1", "DBConnection.ConnectionPool", "init", "1", "1"],
    [
      "DBConnection.ConnectionPool:module_info/0",
      "DBConnection.ConnectionPool",
      "module_info",
      "0",
      "1"
    ],
    [
      "DBConnection.ConnectionPool:module_info/1",
      "DBConnection.ConnectionPool",
      "module_info",
      "1",
      "1"
    ],
    [
      "DBConnection.ConnectionPool:start_idle/2",
      "DBConnection.ConnectionPool",
      "start_idle",
      "2",
      "0"
    ],
    [
      "DBConnection.ConnectionPool:start_link/1",
      "DBConnection.ConnectionPool",
      "start_link",
      "1",
      "1"
    ],
    [
      "DBConnection.ConnectionPool:start_opts/1",
      "DBConnection.ConnectionPool",
      "start_opts",
      "1",
      "0"
    ],
    [
      "DBConnection.ConnectionPool:start_poll/3",
      "DBConnection.ConnectionPool",
      "start_poll",
      "3",
      "0"
    ],
    [
      "DBConnection.ConnectionPool:terminate/2",
      "DBConnection.ConnectionPool",
      "terminate",
      "2",
      "1"
    ],
    ["DBConnection.ConnectionPool:timeout/5", "DBConnection.ConnectionPool", "timeout", "5", "0"]
  ],
  remote_call: [
    [":code_server:call/1#10", ":code_server:call/1", ":erlang", "monitor", "2"],
    [":code_server:call/1#35", ":code_server:call/1", ":erlang", "exit", "1"],
    [":code_server:call/1#44", ":code_server:call/1", ":erlang", "demonitor", "2"],
    [":code_server:handle_call/3#163", ":code_server:handle_call/3", ":erlang", "demonitor", "2"],
    [
      ":code_server:handle_call/3#21",
      ":code_server:handle_call/3",
      ":erlang",
      "module_loaded",
      "1"
    ],
    [
      ":code_server:handle_call/3#321",
      ":code_server:handle_call/3",
      ":erlang",
      "delete_module",
      "1"
    ],
    [":code_server:handle_call/3#330", ":code_server:handle_call/3", ":ets", "delete", "2"],
    [":code_server:handle_call/3#41", ":code_server:handle_call/3", ":erlang", "error", "1"],
    [":code_server:handle_call/3#52", ":code_server:handle_call/3", ":erlang", "demonitor", "2"],
    [":code_server:start_link/1#16", ":code_server:start_link/1", ":erlang", "spawn_link", "1"],
    [":code_server:start_link/1#7", ":code_server:start_link/1", ":erlang", "make_ref", "0"],
    [":dets_server:handle_call/3#23", ":dets_server:handle_call/3", ":ets", "select", "2"],
    [":dets_server:handle_call/3#57", ":dets_server:handle_call/3", ":ets", "foldl", "3"],
    [":dist_ac:collect_answers/4#21", ":dist_ac:collect_answers/4", ":lists", "keysearch", "3"],
    [
      ":dist_ac:collect_answers/4#42",
      ":dist_ac:collect_answers/4",
      ":erlang",
      "monitor_node",
      "2"
    ],
    [
      ":dist_ac:collect_answers/4#59",
      ":dist_ac:collect_answers/4",
      ":erlang",
      "monitor_node",
      "2"
    ],
    [
      ":dist_ac:collect_answers/4#78",
      ":dist_ac:collect_answers/4",
      ":erlang",
      "monitor_node",
      "2"
    ],
    [":dist_ac:handle_call/3#131", ":dist_ac:handle_call/3", ":lists", "keysearch", "3"],
    [":dist_ac:handle_call/3#155", ":dist_ac:handle_call/3", ":lists", "keyreplace", "4"],
    [":dist_ac:handle_call/3#20", ":dist_ac:handle_call/3", ":lists", "keymember", "3"],
    [":dist_ac:handle_call/3#37", ":dist_ac:handle_call/3", ":lists", "keysearch", "3"],
    [
      ":dist_ac:handle_call/3#80",
      ":dist_ac:handle_call/3",
      ":application_controller",
      "get_loaded",
      "1"
    ],
    [":dist_ac:handle_cast/2#15", ":dist_ac:handle_cast/2", ":application", "get_env", "2"],
    [":dist_ac:handle_cast/2#38", ":dist_ac:handle_cast/2", ":net_kernel", "monitor_nodes", "1"],
    [":dist_ac:wait_dacs/4#14", ":dist_ac:wait_dacs/4", ":erlang", "monitor_node", "2"],
    [":dist_ac:wait_dacs/4#29", ":dist_ac:wait_dacs/4", ":erlang", "monitor_node", "2"],
    [":dist_ac:wait_dacs/4#34", ":dist_ac:wait_dacs/4", ":erlang", "++", "2"],
    [":dist_ac:wait_dacs/4#59", ":dist_ac:wait_dacs/4", ":erlang", "monitor_node", "2"],
    [
      ":dist_ac:wait_dist_start/7#106",
      ":dist_ac:wait_dist_start/7",
      ":erlang",
      "monitor_node",
      "2"
    ],
    [":dist_ac:wait_dist_start/7#111", ":dist_ac:wait_dist_start/7", ":lists", "filter", "2"],
    [":dist_ac:wait_dist_start/7#120", ":dist_ac:wait_dist_start/7", ":lists", "delete", "2"],
    [
      ":dist_ac:wait_dist_start/7#14",
      ":dist_ac:wait_dist_start/7",
      ":erlang",
      "monitor_node",
      "2"
    ],
    [
      ":dist_ac:wait_dist_start/7#32",
      ":dist_ac:wait_dist_start/7",
      ":erlang",
      "monitor_node",
      "2"
    ],
    [
      ":dist_ac:wait_dist_start/7#71",
      ":dist_ac:wait_dist_start/7",
      ":erlang",
      "monitor_node",
      "2"
    ],
    [
      ":dist_ac:wait_dist_start/7#91",
      ":dist_ac:wait_dist_start/7",
      ":erlang",
      "monitor_node",
      "2"
    ],
    [":dist_ac:wait_dist_start2/6#64", ":dist_ac:wait_dist_start2/6", ":lists", "filter", "2"],
    [":dist_ac:wait_dist_start2/6#72", ":dist_ac:wait_dist_start2/6", ":lists", "delete", "2"],
    [
      ":ejabberd_hooks:handle_call/3#69",
      ":ejabberd_hooks:handle_call/3",
      ":logger",
      "allow",
      "2"
    ],
    [
      ":ejabberd_hooks:handle_call/3#80",
      ":ejabberd_hooks:handle_call/3",
      ":logger",
      "macro_log",
      "5"
    ],
    [
      ":rabbit_disk_monitor:get_reply/2#21",
      ":rabbit_disk_monitor:get_reply/2",
      ":erlang",
      "exit",
      "1"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#107",
      ":rabbit_disk_monitor:handle_call/3",
      ":erlang",
      "cancel_timer",
      "1"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#111",
      ":rabbit_disk_monitor:handle_call/3",
      ":logger",
      "allow",
      "2"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#117",
      ":rabbit_disk_monitor:handle_call/3",
      ":logger",
      "macro_log",
      "3"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#128",
      ":rabbit_disk_monitor:handle_call/3",
      ":logger",
      "allow",
      "2"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#135",
      ":rabbit_disk_monitor:handle_call/3",
      ":logger",
      "macro_log",
      "4"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#44",
      ":rabbit_disk_monitor:handle_call/3",
      ":logger",
      "allow",
      "2"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#50",
      ":rabbit_disk_monitor:handle_call/3",
      ":logger",
      "macro_log",
      "3"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#63",
      ":rabbit_disk_monitor:handle_call/3",
      ":logger",
      "allow",
      "2"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#69",
      ":rabbit_disk_monitor:handle_call/3",
      ":logger",
      "macro_log",
      "3"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#85",
      ":rabbit_disk_monitor:handle_call/3",
      ":erlang",
      "cancel_timer",
      "1"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#89",
      ":rabbit_disk_monitor:handle_call/3",
      ":logger",
      "allow",
      "2"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#95",
      ":rabbit_disk_monitor:handle_call/3",
      ":logger",
      "macro_log",
      "3"
    ],
    [
      "DBConnection.ConnectionPool:handle_call/3#12",
      "DBConnection.ConnectionPool:handle_call/3",
      ":erlang",
      "monotonic_time",
      "0"
    ],
    [
      "DBConnection.ConnectionPool:handle_call/3#36",
      "DBConnection.ConnectionPool:handle_call/3",
      ":ets",
      "select_count",
      "2"
    ],
    [
      "DBConnection.ConnectionPool:handle_call/3#43",
      "DBConnection.ConnectionPool:handle_call/3",
      ":ets",
      "select_count",
      "2"
    ]
  ],
  bif_call: [
    [":code_server:call/1#12", ":code_server:call/1", ":erlang", "self", "0", "0"],
    [":code_server:start_link/1#9", ":code_server:start_link/1", ":erlang", "self", "0", "0"],
    [
      ":dets_server:-handle_call/3-fun-0-/2#4",
      ":dets_server:-handle_call/3-fun-0-/2",
      ":erlang",
      "element",
      "2",
      "0"
    ],
    [":dist_ac:collect_answers/4#6", ":dist_ac:collect_answers/4", ":erlang", "node", "0", "0"],
    [":dist_ac:handle_call/3#136", ":dist_ac:handle_call/3", ":erlang", "element", "2", "60"],
    [":dist_ac:handle_call/3#23", ":dist_ac:handle_call/3", ":erlang", "node", "0", "0"],
    [":dist_ac:handle_call/3#43", ":dist_ac:handle_call/3", ":erlang", "=:=", "2", "0"],
    [":dist_ac:handle_call/3#55", ":dist_ac:handle_call/3", ":erlang", "node", "0", "0"],
    [":dist_ac:wait_dist_start/7#38", ":dist_ac:wait_dist_start/7", ":erlang", "node", "0", "0"],
    [
      "DBConnection.ConnectionPool:handle_call/3#48",
      "DBConnection.ConnectionPool:handle_call/3",
      ":erlang",
      "self",
      "0",
      "0"
    ]
  ],
  local_call: [
    [
      ":code_server:-start_link/1-fun-0-/3#5",
      ":code_server:-start_link/1-fun-0-/3",
      ":code_server:init/3",
      "3"
    ],
    [
      ":code_server:handle_call/3#104",
      ":code_server:handle_call/3",
      ":code_server:add_paths/6",
      "6"
    ],
    [
      ":code_server:handle_call/3#123",
      ":code_server:handle_call/3",
      ":code_server:add_path/6",
      "6"
    ],
    [
      ":code_server:handle_call/3#147",
      ":code_server:handle_call/3",
      ":code_server:set_path/5",
      "5"
    ],
    [
      ":code_server:handle_call/3#168",
      ":code_server:handle_call/3",
      ":code_server:run_loader_next/2",
      "2"
    ],
    [
      ":code_server:handle_call/3#179",
      ":code_server:handle_call/3",
      ":code_server:finish_loading/3",
      "3"
    ],
    [
      ":code_server:handle_call/3#195",
      ":code_server:handle_call/3",
      ":code_server:where_is_file/3",
      "3"
    ],
    [
      ":code_server:handle_call/3#209",
      ":code_server:handle_call/3",
      ":code_server:stick_mod/3",
      "3"
    ],
    [
      ":code_server:handle_call/3#220",
      ":code_server:handle_call/3",
      ":code_server:stick_dir/3",
      "3"
    ],
    [
      ":code_server:handle_call/3#231",
      ":code_server:handle_call/3",
      ":code_server:stick_mod/3",
      "3"
    ],
    [
      ":code_server:handle_call/3#242",
      ":code_server:handle_call/3",
      ":code_server:stick_dir/3",
      "3"
    ],
    [
      ":code_server:handle_call/3#253",
      ":code_server:handle_call/3",
      ":code_server:do_soft_purge/1",
      "1"
    ],
    [
      ":code_server:handle_call/3#26",
      ":code_server:handle_call/3",
      ":code_server:do_purge/1",
      "1"
    ],
    [
      ":code_server:handle_call/3#264",
      ":code_server:handle_call/3",
      ":code_server:do_purge/1",
      "1"
    ],
    [
      ":code_server:handle_call/3#274",
      ":code_server:handle_call/3",
      ":code_server:schedule_or_run_loader/4",
      "4"
    ],
    [
      ":code_server:handle_call/3#282",
      ":code_server:handle_call/3",
      ":code_server:get_object_code/2",
      "2"
    ],
    [
      ":code_server:handle_call/3#308",
      ":code_server:handle_call/3",
      ":code_server:do_dir/3",
      "3"
    ],
    [
      ":code_server:handle_call/3#348",
      ":code_server:handle_call/3",
      ":code_server:del_paths/4",
      "4"
    ],
    [
      ":code_server:handle_call/3#36",
      ":code_server:handle_call/3",
      ":code_server:schedule_or_run_loader/4",
      "4"
    ],
    [
      ":code_server:handle_call/3#364",
      ":code_server:handle_call/3",
      ":code_server:del_path/4",
      "4"
    ],
    [
      ":code_server:handle_call/3#385",
      ":code_server:handle_call/3",
      ":code_server:-handle_call/3-lc$^0/1-0-/1",
      "1"
    ],
    [
      ":code_server:handle_call/3#400",
      ":code_server:handle_call/3",
      ":code_server:all_loaded/1",
      "1"
    ],
    [
      ":code_server:handle_call/3#411",
      ":code_server:handle_call/3",
      ":code_server:error_msg/2",
      "2"
    ],
    [
      ":code_server:handle_call/3#62",
      ":code_server:handle_call/3",
      ":code_server:run_loader/4",
      "4"
    ],
    [
      ":code_server:handle_call/3#84",
      ":code_server:handle_call/3",
      ":code_server:replace_path/6",
      "6"
    ],
    [
      ":code_server:handle_system_msg/5#25",
      ":code_server:handle_system_msg/5",
      ":code_server:suspend_loop/3",
      "3"
    ],
    [":code_server:init/3#96", ":code_server:init/3", ":code_server:loop/1", "1"],
    [":code_server:loop/1#29", ":code_server:loop/1", ":code_server:on_load_down/3", "3"],
    [":code_server:loop/1#30", ":code_server:loop/1", ":code_server:loop/1", "1"],
    [":code_server:loop/1#38", ":code_server:loop/1", ":code_server:run_loader_next/2", "2"],
    [":code_server:loop/1#39", ":code_server:loop/1", ":code_server:loop/1", "1"],
    [":code_server:loop/1#51", ":code_server:loop/1", ":code_server:handle_system_msg/5", "5"],
    [":code_server:loop/1#59", ":code_server:loop/1", ":code_server:handle_call/3", "3"],
    [":code_server:loop/1#66", ":code_server:loop/1", ":code_server:system_terminate/4", "4"],
    [":code_server:loop/1#73", ":code_server:loop/1", ":code_server:reply/2", "2"],
    [":code_server:loop/1#75", ":code_server:loop/1", ":code_server:loop/1", "1"],
    [":code_server:loop/1#78", ":code_server:loop/1", ":code_server:loop/1", "1"],
    [":code_server:loop/1#85", ":code_server:loop/1", ":code_server:system_terminate/4", "4"],
    [":code_server:loop/1#89", ":code_server:loop/1", ":code_server:loop/1", "1"],
    [
      ":code_server:suspend_loop/3#21",
      ":code_server:suspend_loop/3",
      ":code_server:handle_system_msg/5",
      "5"
    ],
    [
      ":code_server:suspend_loop/3#28",
      ":code_server:suspend_loop/3",
      ":code_server:system_terminate/4",
      "4"
    ],
    [
      ":code_server:system_continue/3#5",
      ":code_server:system_continue/3",
      ":code_server:loop/1",
      "1"
    ],
    [
      ":dets_server:handle_call/3#33",
      ":dets_server:handle_call/3",
      ":dets_server:set_verbose/1",
      "1"
    ],
    [
      ":dets_server:handle_call/3#43",
      ":dets_server:handle_call/3",
      ":dets_server:request/2",
      "2"
    ],
    [
      ":dist_ac:-sync_dacs/1-fun-0-/1#15",
      ":dist_ac:-sync_dacs/1-fun-0-/1",
      ":dist_ac:wait_dacs/4",
      "4"
    ],
    [
      ":dist_ac:collect_answers/4#37",
      ":dist_ac:collect_answers/4",
      ":dist_ac:collect_answers/4",
      "4"
    ],
    [
      ":dist_ac:collect_answers/4#67",
      ":dist_ac:collect_answers/4",
      ":dist_ac:collect_answers/4",
      "4"
    ],
    [
      ":dist_ac:collect_answers/4#8",
      ":dist_ac:collect_answers/4",
      ":dist_ac:collect_answers/4",
      "4"
    ],
    [
      ":dist_ac:collect_answers/4#83",
      ":dist_ac:collect_answers/4",
      ":dist_ac:collect_answers/4",
      "4"
    ],
    [
      ":dist_ac:find_any_node/5#36",
      ":dist_ac:find_any_node/5",
      ":dist_ac:collect_answers/4",
      "4"
    ],
    [":dist_ac:handle_call/3#100", ":dist_ac:handle_call/3", ":dist_ac:ac_stop_it/1", "1"],
    [":dist_ac:handle_call/3#146", ":dist_ac:handle_call/3", ":dist_ac:ac_takeover/4", "4"],
    [":dist_ac:handle_call/3#190", ":dist_ac:handle_call/3", ":dist_ac:dist_replace/3", "3"],
    [":dist_ac:handle_call/3#214", ":dist_ac:handle_call/3", ":dist_ac:dist_find_nodes/2", "2"],
    [
      ":dist_ac:handle_call/3#225",
      ":dist_ac:handle_call/3",
      ":dist_ac:ensure_take_control/2",
      "2"
    ],
    [":dist_ac:handle_call/3#231", ":dist_ac:handle_call/3", ":dist_ac:load/2", "2"],
    [":dist_ac:handle_call/3#248", ":dist_ac:handle_call/3", ":dist_ac:dist_flat_nodes/2", "2"],
    [":dist_ac:handle_call/3#250", ":dist_ac:handle_call/3", ":dist_ac:intersection/2", "2"],
    [
      ":dist_ac:handle_call/3#262",
      ":dist_ac:handle_call/3",
      ":dist_ac:dist_change_update/2",
      "2"
    ],
    [":dist_ac:handle_call/3#28", ":dist_ac:handle_call/3", ":dist_ac:dist_update_run/4", "4"],
    [":dist_ac:handle_call/3#53", ":dist_ac:handle_call/3", ":dist_ac:dist_flat_nodes/2", "2"],
    [":dist_ac:handle_call/3#60", ":dist_ac:handle_call/3", ":dist_ac:send_msg/2", "2"],
    [":dist_ac:handle_call/3#70", ":dist_ac:handle_call/3", ":dist_ac:permit/6", "6"],
    [":dist_ac:handle_call/3#90", ":dist_ac:handle_call/3", ":dist_ac:ac_start_it/2", "2"],
    [":dist_ac:handle_cast/2#20", ":dist_ac:handle_cast/2", ":dist_ac:dist_check/1", "1"],
    [":dist_ac:handle_cast/2#29", ":dist_ac:handle_cast/2", ":dist_ac:dist_take_control/1", "1"],
    [":dist_ac:handle_cast/2#43", ":dist_ac:handle_cast/2", ":dist_ac:sync_dacs/1", "1"],
    [
      ":dist_ac:start_distributed/6#120",
      ":dist_ac:start_distributed/6",
      ":dist_ac:wait_dist_start/7",
      "7"
    ],
    [
      ":dist_ac:start_distributed/6#142",
      ":dist_ac:start_distributed/6",
      ":dist_ac:wait_dist_start2/6",
      "6"
    ],
    [":dist_ac:wait_dacs/4#41", ":dist_ac:wait_dacs/4", ":dist_ac:dist_merge/3", "3"],
    [":dist_ac:wait_dacs/4#47", ":dist_ac:wait_dacs/4", ":dist_ac:wait_dacs/4", "4"],
    [":dist_ac:wait_dacs/4#64", ":dist_ac:wait_dacs/4", ":dist_ac:wait_dacs/4", "4"],
    [
      ":dist_ac:wait_dist_start/7#127",
      ":dist_ac:wait_dist_start/7",
      ":dist_ac:start_distributed/6",
      "6"
    ],
    [
      ":dist_ac:wait_dist_start/7#36",
      ":dist_ac:wait_dist_start/7",
      ":dist_ac:get_cached_weight/2",
      "2"
    ],
    [
      ":dist_ac:wait_dist_start/7#51",
      ":dist_ac:wait_dist_start/7",
      ":dist_ac:wait_dist_start/7",
      "7"
    ],
    [":dist_ac:wait_dist_start/7#65", ":dist_ac:wait_dist_start/7", ":dist_ac:ac_error/3", "3"],
    [":dist_ac:wait_dist_start/7#87", ":dist_ac:wait_dist_start/7", ":dist_ac:ac_started/3", "3"],
    [":dist_ac:wait_dist_start2/6#34", ":dist_ac:wait_dist_start2/6", ":dist_ac:ac_error/3", "3"],
    [
      ":dist_ac:wait_dist_start2/6#49",
      ":dist_ac:wait_dist_start2/6",
      ":dist_ac:ac_started/3",
      "3"
    ],
    [
      ":dist_ac:wait_dist_start2/6#79",
      ":dist_ac:wait_dist_start2/6",
      ":dist_ac:start_distributed/6",
      "6"
    ],
    [
      ":ejabberd_hooks:handle_call/3#20",
      ":ejabberd_hooks:handle_call/3",
      ":ejabberd_hooks:handle_unsubscribe/3",
      "3"
    ],
    [
      ":ejabberd_hooks:handle_call/3#32",
      ":ejabberd_hooks:handle_call/3",
      ":ejabberd_hooks:handle_subscribe/3",
      "3"
    ],
    [
      ":ejabberd_hooks:handle_call/3#44",
      ":ejabberd_hooks:handle_call/3",
      ":ejabberd_hooks:handle_delete/3",
      "3"
    ],
    [
      ":ejabberd_hooks:handle_call/3#56",
      ":ejabberd_hooks:handle_call/3",
      ":ejabberd_hooks:handle_add/3",
      "3"
    ],
    [
      ":rabbit_disk_monitor:get_reply/2#32",
      ":rabbit_disk_monitor:get_reply/2",
      ":rabbit_disk_monitor:newline/2",
      "2"
    ],
    [
      ":rabbit_disk_monitor:get_reply/2#41",
      ":rabbit_disk_monitor:get_reply/2",
      ":rabbit_disk_monitor:get_reply/2",
      "2"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#13",
      ":rabbit_disk_monitor:handle_call/3",
      ":rabbit_disk_monitor:set_min_check_interval/2",
      "2"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#146",
      ":rabbit_disk_monitor:handle_call/3",
      ":rabbit_disk_monitor:set_disk_limits/2",
      "2"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#22",
      ":rabbit_disk_monitor:handle_call/3",
      ":rabbit_disk_monitor:set_max_check_interval/2",
      "2"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#39",
      ":rabbit_disk_monitor:handle_call/3",
      ":rabbit_disk_monitor:set_disk_limits/2",
      "2"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#40",
      ":rabbit_disk_monitor:handle_call/3",
      ":rabbit_disk_monitor:start_timer/1",
      "1"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#58",
      ":rabbit_disk_monitor:handle_call/3",
      ":rabbit_disk_monitor:set_disk_limits/2",
      "2"
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#59",
      ":rabbit_disk_monitor:handle_call/3",
      ":rabbit_disk_monitor:start_timer/1",
      "1"
    ],
    [
      ":rabbit_disk_monitor:run_port_cmd/2#22",
      ":rabbit_disk_monitor:run_port_cmd/2",
      ":rabbit_disk_monitor:get_reply/2",
      "2"
    ]
  ],
  closure_def: [
    [":code_server:start_link/1", ":code_server:-start_link/1-fun-0-/3"],
    [":dets_server:handle_call/3", ":dets_server:-handle_call/3-fun-0-/2"],
    [":dist_ac:wait_dist_start/7", ":dist_ac:-wait_dist_start/7-fun-0-/3"],
    [":dist_ac:wait_dist_start2/6", ":dist_ac:-wait_dist_start2/6-fun-0-/3"]
  ],
  literal_value: [
    [":code_server:call/1#16", "x0", ":code_server"],
    [":code_server:call/1#41", "x1", "[:flush]"],
    [":code_server:call/1#7", "x1", ":code_server"],
    [":code_server:call/1#8", "x0", ":process"],
    [":code_server:handle_call/3#160", "x1", "[:flush]"],
    [":code_server:handle_call/3#206", "x1", "false"],
    [":code_server:handle_call/3#217", "x1", "false"],
    [":code_server:handle_call/3#228", "x1", "true"],
    [":code_server:handle_call/3#239", "x1", "true"],
    [":code_server:handle_call/3#273", "x0", ":get_object_code"],
    [":code_server:handle_call/3#409", "x0", "~c\" ** Codeserver*** ignoring ~w~n \""],
    [":code_server:handle_call/3#50", "x1", "[:flush]"],
    [":code_server:loop/1#50", "x0", ":running"],
    [":code_server:loop/1#64", "x2", "nil"],
    [":code_server:loop/1#65", "x0", ":normal"],
    [":code_server:loop/1#82", "x2", "nil"],
    [":code_server:suspend_loop/3#20", "x0", ":suspended"],
    [":code_server:suspend_loop/3#25", "x2", "nil"],
    [":dets_server:handle_call/3#54", "x2", ":dets_registry"],
    [":dets_server:handle_call/3#55", "x1", "nil"],
    [":dist_ac:-wait_dist_start/7-fun-0-/3#10", "x0", "false"],
    [":dist_ac:-wait_dist_start/7-fun-0-/3#13", "x0", "true"],
    [":dist_ac:-wait_dist_start2/6-fun-0-/3#10", "x0", "false"],
    [":dist_ac:-wait_dist_start2/6-fun-0-/3#13", "x0", "true"],
    [":dist_ac:collect_answers/4#18", "x1", "3"],
    [":dist_ac:collect_answers/4#39", "x1", "true"],
    [":dist_ac:collect_answers/4#56", "x1", "false"],
    [":dist_ac:collect_answers/4#74", "x1", "false"],
    [":dist_ac:handle_call/3#127", "x1", "2"],
    [":dist_ac:handle_call/3#144", "x0", ":req"],
    [":dist_ac:handle_call/3#149", "x1", "2"],
    [":dist_ac:handle_call/3#17", "x1", "2"],
    [":dist_ac:handle_call/3#35", "x1", "2"],
    [":dist_ac:handle_call/3#47", "y0", "false"],
    [":dist_ac:handle_call/3#88", "x0", ":req"],
    [":dist_ac:handle_cast/2#12", "x1", ":distributed"],
    [":dist_ac:handle_cast/2#13", "x0", ":kernel"],
    [":dist_ac:handle_cast/2#25", "y0", "nil"],
    [":dist_ac:handle_cast/2#31", "x1", ":dist_ac_took_control"],
    [":dist_ac:handle_cast/2#36", "x0", "true"],
    [":dist_ac:wait_dacs/4#11", "x1", "true"],
    [":dist_ac:wait_dacs/4#26", "x1", "false"],
    [":dist_ac:wait_dacs/4#54", "x1", "false"],
    [":dist_ac:wait_dist_start/7#103", "x1", "false"],
    [":dist_ac:wait_dist_start/7#12", "x1", "true"],
    [":dist_ac:wait_dist_start/7#29", "x1", "false"],
    [":dist_ac:wait_dist_start/7#66", "x1", "false"],
    [":dist_ac:wait_dist_start/7#88", "x1", "false"],
    [":ejabberd_hooks:handle_call/3#66", "x1", ":ejabberd_hooks"],
    [":ejabberd_hooks:handle_call/3#67", "x0", ":warning"],
    [":ejabberd_hooks:handle_call/3#75", "x2", "~c\"Unexpected call from ~p: ~p\""],
    [":ejabberd_hooks:handle_call/3#76", "x1", ":warning"],
    [
      ":ejabberd_hooks:handle_call/3#77",
      "x4",
      "%{clevel: ~c\"\\e[1;49;93m\", ctext: ~c\"\\e[0;49;93m\"}"
    ],
    [":ejabberd_hooks:handle_call/3#79", "x0", "%{mfa: {:ejabberd_hooks, :handle_call, 3}}"],
    [":rabbit_disk_monitor:handle_call/3#108", "x1", ":rabbit_disk_monitor"],
    [":rabbit_disk_monitor:handle_call/3#109", "x0", ":info"],
    [":rabbit_disk_monitor:handle_call/3#114", "x1", ":info"],
    [
      ":rabbit_disk_monitor:handle_call/3#115",
      "x2",
      "~c\"Free disk space monitor was already disabled\""
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#116",
      "x0",
      "%{mfa: {:rabbit_disk_monitor, :handle_call, 3}}"
    ],
    [":rabbit_disk_monitor:handle_call/3#125", "x1", ":rabbit_disk_monitor"],
    [":rabbit_disk_monitor:handle_call/3#126", "x0", ":info"],
    [
      ":rabbit_disk_monitor:handle_call/3#131",
      "x2",
      "~c\"Cannot set disk free limit: disabled disk free space monitoring\""
    ],
    [":rabbit_disk_monitor:handle_call/3#132", "x1", ":info"],
    [":rabbit_disk_monitor:handle_call/3#133", "x3", "nil"],
    [
      ":rabbit_disk_monitor:handle_call/3#134",
      "x0",
      "%{mfa: {:rabbit_disk_monitor, :handle_call, 3}}"
    ],
    [":rabbit_disk_monitor:handle_call/3#41", "x1", ":rabbit_disk_monitor"],
    [":rabbit_disk_monitor:handle_call/3#42", "x0", ":info"],
    [":rabbit_disk_monitor:handle_call/3#47", "x1", ":info"],
    [
      ":rabbit_disk_monitor:handle_call/3#48",
      "x2",
      "~c\"Free disk space monitor was already enabled\""
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#49",
      "x0",
      "%{mfa: {:rabbit_disk_monitor, :handle_call, 3}}"
    ],
    [":rabbit_disk_monitor:handle_call/3#60", "x1", ":rabbit_disk_monitor"],
    [":rabbit_disk_monitor:handle_call/3#61", "x0", ":info"],
    [":rabbit_disk_monitor:handle_call/3#66", "x1", ":info"],
    [
      ":rabbit_disk_monitor:handle_call/3#67",
      "x2",
      "~c\"Free disk space monitor was manually enabled\""
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#68",
      "x0",
      "%{mfa: {:rabbit_disk_monitor, :handle_call, 3}}"
    ],
    [":rabbit_disk_monitor:handle_call/3#86", "x1", ":rabbit_disk_monitor"],
    [":rabbit_disk_monitor:handle_call/3#87", "x0", ":info"],
    [":rabbit_disk_monitor:handle_call/3#92", "x1", ":info"],
    [
      ":rabbit_disk_monitor:handle_call/3#93",
      "x2",
      "~c\"Free disk space monitor was manually disabled\""
    ],
    [
      ":rabbit_disk_monitor:handle_call/3#94",
      "x0",
      "%{mfa: {:rabbit_disk_monitor, :handle_call, 3}}"
    ],
    ["DBConnection.ConnectionPool:handle_call/3#34", "x1", "[{{{:_, :_}}, [], [true]}]"],
    ["DBConnection.ConnectionPool:handle_call/3#37", "x1", "0"],
    ["DBConnection.ConnectionPool:handle_call/3#41", "x1", "[{{{:_, :_, :_}}, [], [true]}]"],
    ["DBConnection.ConnectionPool:handle_call/3#45", "x0", "0"]
  ],
  tuple_literal: [
    [":code_server:call/1#13", "x1", ":code_call", "3"],
    [":code_server:call/1#33", "x0", ":DOWN", "3"],
    [":code_server:handle_call/3#109", "x0", ":reply", "3"],
    [":code_server:handle_call/3#129", "x0", ":reply", "3"],
    [":code_server:handle_call/3#153", "x0", ":reply", "3"],
    [":code_server:handle_call/3#170", "x0", ":reply", "3"],
    [":code_server:handle_call/3#181", "x0", ":reply", "3"],
    [":code_server:handle_call/3#200", "x0", ":reply", "3"],
    [":code_server:handle_call/3#211", "x0", ":reply", "3"],
    [":code_server:handle_call/3#222", "x0", ":reply", "3"],
    [":code_server:handle_call/3#233", "x0", ":reply", "3"],
    [":code_server:handle_call/3#244", "x0", ":reply", "3"],
    [":code_server:handle_call/3#255", "x0", ":reply", "3"],
    [":code_server:handle_call/3#266", "x0", ":reply", "3"],
    [":code_server:handle_call/3#290", "x0", ":reply", "3"],
    [":code_server:handle_call/3#298", "x0", ":reply", "3"],
    [":code_server:handle_call/3#310", "x0", ":reply", "3"],
    [":code_server:handle_call/3#32", "x0", ":load_module", "4"],
    [":code_server:handle_call/3#332", "x0", ":reply", "3"],
    [":code_server:handle_call/3#337", "x0", ":reply", "3"],
    [":code_server:handle_call/3#353", "x0", ":reply", "3"],
    [":code_server:handle_call/3#371", "x0", ":reply", "3"],
    [":code_server:handle_call/3#378", "x0", ":stop", "4"],
    [":code_server:handle_call/3#387", "x0", ":reply", "3"],
    [":code_server:handle_call/3#39", "x0", ":badarg", "2"],
    [":code_server:handle_call/3#393", "x0", ":reply", "3"],
    [":code_server:handle_call/3#402", "x0", ":reply", "3"],
    [":code_server:handle_call/3#413", "x0", ":noreply", "2"],
    [":code_server:handle_call/3#56", "x0", ":load_module", "4"],
    [":code_server:handle_call/3#64", "x0", ":noreply", "2"],
    [":code_server:handle_call/3#90", "x0", ":reply", "3"],
    [":dets_server:handle_call/3#18", "x0", ":\"$1\"", "2"],
    [":dets_server:handle_call/3#25", "x0", ":reply", "3"],
    [":dets_server:handle_call/3#35", "x0", ":reply", "3"],
    [":dets_server:handle_call/3#48", "x0", ":stop", "4"],
    [":dets_server:handle_call/3#59", "x0", ":reply", "3"],
    [":dist_ac:handle_call/3#102", "x0", ":reply", "3"],
    [":dist_ac:handle_call/3#108", "x0", ":not_loaded", "2"],
    [":dist_ac:handle_call/3#109", "x0", ":error", "2"],
    [":dist_ac:handle_call/3#110", "x0", ":reply", "3"],
    [":dist_ac:handle_call/3#161", "x0", ":noreply", "2"],
    [":dist_ac:handle_call/3#167", "x0", ":already_running_locally", "2"],
    [":dist_ac:handle_call/3#168", "x0", ":error", "2"],
    [":dist_ac:handle_call/3#169", "x0", ":reply", "3"],
    [":dist_ac:handle_call/3#174", "x0", ":not_running_distributed", "2"],
    [":dist_ac:handle_call/3#175", "x0", ":error", "2"],
    [":dist_ac:handle_call/3#176", "x0", ":reply", "3"],
    [":dist_ac:handle_call/3#200", "x0", ":reply", "3"],
    [":dist_ac:handle_call/3#206", "x1", ":error", "2"],
    [":dist_ac:handle_call/3#207", "x0", ":stop", "4"],
    [":dist_ac:handle_call/3#217", "x0", ":reply", "3"],
    [":dist_ac:handle_call/3#234", "x0", ":reply", "3"],
    [":dist_ac:handle_call/3#252", "x0", ":reply", "3"],
    [":dist_ac:handle_call/3#265", "x0", ":reply", "3"],
    [":dist_ac:handle_call/3#272", "x0", ":reply", "3"],
    [":dist_ac:handle_call/3#278", "x0", ":reply", "3"],
    [":dist_ac:handle_call/3#56", "x1", ":dist_ac_new_permission", "5"],
    [":dist_ac:handle_call/3#73", "x0", ":reply", "3"],
    [":dist_ac:handle_call/3#92", "x0", ":reply", "3"],
    [":dist_ac:handle_cast/2#50", "x0", ":state", "11"],
    [":dist_ac:handle_cast/2#51", "x0", ":noreply", "2"],
    [":dist_ac:wait_dist_start/7#39", "x2", ":dist_ac", "2"],
    [":dist_ac:wait_dist_start/7#40", "x1", ":dist_ac_weight", "4"],
    [":dist_ac:wait_dist_start/7#93", "x0", ":distributed", "2"],
    [":dist_ac:wait_dist_start2/6#51", "x0", ":distributed", "2"],
    [":ejabberd_hooks:handle_call/3#22", "x0", ":reply", "3"],
    [":ejabberd_hooks:handle_call/3#34", "x0", ":reply", "3"],
    [":ejabberd_hooks:handle_call/3#46", "x0", ":reply", "3"],
    [":ejabberd_hooks:handle_call/3#58", "x0", ":reply", "3"],
    [":ejabberd_hooks:handle_call/3#83", "x0", ":noreply", "2"],
    [":rabbit_disk_monitor:get_reply/2#19", "x0", ":port_died", "2"],
    [":rabbit_disk_monitor:handle_call/3#138", "x0", ":reply", "3"],
    [":rabbit_disk_monitor:handle_call/3#148", "x0", ":reply", "3"],
    [":rabbit_disk_monitor:handle_call/3#15", "x0", ":reply", "3"],
    [":rabbit_disk_monitor:handle_call/3#156", "x0", ":reply", "3"],
    [":rabbit_disk_monitor:handle_call/3#160", "x0", ":noreply", "2"],
    [":rabbit_disk_monitor:handle_call/3#24", "x0", ":reply", "3"],
    [":rabbit_disk_monitor:handle_call/3#73", "x0", ":reply", "3"],
    [":rabbit_disk_monitor:handle_call/3#99", "x0", ":reply", "3"],
    [":rabbit_guid:handle_call/3#12", "x0", ":noreply", "2"],
    [":rabbit_guid:handle_call/3#8", "x0", ":reply", "3"],
    ["DBConnection.ConnectionPool:handle_call/3#20", "x0", ":reply", "3"],
    ["DBConnection.ConnectionPool:handle_call/3#49", "x2", ":pool", "2"],
    ["DBConnection.ConnectionPool:handle_call/3#53", "x0", ":reply", "3"]
  ],
  implements_behaviour: [
    [":dets_server", ":gen_server"],
    [":dist_ac", ":gen_server"],
    [":ejabberd_hooks", ":gen_server"],
    [":rabbit_disk_monitor", ":gen_server"],
    [":rabbit_guid", ":gen_server"],
    ["DBConnection.ConnectionPool", "DBConnection.Pool"],
    ["DBConnection.ConnectionPool", "GenServer"]
  ],
  recv_start: [
    [":code_server:call/1#20", ":code_server:call/1", "1", "40"],
    [":code_server:loop/1#10", ":code_server:loop/1", "1", "57"],
    [":code_server:start_link/1#19", ":code_server:start_link/1", "1", "5"],
    [":code_server:suspend_loop/3#8", ":code_server:suspend_loop/3", "1", "71"],
    [":dist_ac:collect_answers/4#44", ":dist_ac:collect_answers/4", "1", "306"],
    [":dist_ac:handle_cast/2#8", ":dist_ac:handle_cast/2", "1", "43"],
    [":dist_ac:wait_dacs/4#16", ":dist_ac:wait_dacs/4", "1", "29"],
    [":dist_ac:wait_dist_start/7#16", ":dist_ac:wait_dist_start/7", "1", "213"],
    [":dist_ac:wait_dist_start2/6#13", ":dist_ac:wait_dist_start2/6", "1", "221"],
    [
      ":ejabberd_hooks:-do_trace_on/4-fun-0-/4#19",
      ":ejabberd_hooks:-do_trace_on/4-fun-0-/4",
      "0",
      "318"
    ],
    [":rabbit_disk_monitor:get_reply/2#8", ":rabbit_disk_monitor:get_reply/2", "1", "82"],
    [":rabbit_disk_monitor:run_os_cmd/1#20", ":rabbit_disk_monitor:run_os_cmd/1", "0", "196"]
  ],
  named_process: [
    [":code_server", ":code_server"],
    [":dets_server", ":dets"],
    [":dist_ac", ":dist_ac"],
    [":ejabberd_hooks", ":ejabberd_hooks"],
    [":rabbit_disk_monitor", ":rabbit_disk_monitor"],
    [":rabbit_guid", ":rabbit_guid"]
  ]
}
