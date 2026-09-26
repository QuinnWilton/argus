# Closed-issue pairs: the finding is present at `pre` (the commit before
# the fix) and absent at `fix`. A pair without a `fix` is present-only —
# the fix did not remove the shape (postgrex#746 keeps its :infinity
# default behind an option) or lives outside the compiled tree.
#
# Titles are matched exactly against `Argus.Findings.t().title`; `module:`
# is the finding's anchor module, which keeps another module's identical
# title from standing in for the one the fix removed.
[
  %{
    repo: "oban-bg/oban",
    issue: "oban#21",
    module: "Oban.Queue.Watchman",
    pre: "7143d7a91a4a062075db99f3698afb19cf5dab58",
    fix: "882febddee194d87127f2693e37bfe08c2d6550a",
    finding: {:shutdown, "terminate/2 calls a sibling that may already be down"}
  },
  # postgrex#763's own instance (the pool manager starting connections
  # under :db_connection's supervisor) reaches the supervisor through a
  # Watcher message argus does not resolve; the same shape in the
  # ownership manager is what the rule sees, and the fix leaves it.
  %{
    repo: "elixir-ecto/db_connection",
    issue: "postgrex#763",
    module: "DBConnection.Ownership.Manager",
    pre: "6c4e5c2a3eec47a80537704187e314dbeb6cfbe4",
    finding: {:shutdown, "Children started under another tree outlive their owner"}
  },
  %{
    repo: "sneako/finch",
    issue: "finch#213",
    module: "Finch.HTTP2.Pool",
    pre: "28827940193f0436f55f1688874e7b65f6079b05",
    fix: "ca530c889f7fd1e036ea292d7d0c17adb01d0cd2",
    finding: {:mailbox, "A {:call, from} clause never replies"}
  },
  %{
    repo: "whatyouhide/redix",
    issue: "redix#317",
    module: "Redix.Cluster",
    pre: "cef6129a0aa2093e24d8b1ab5b6853d0b58a3b41",
    fix: "3f88e8e9a9d0627ca91f77fa2c475b679b0f77b9",
    finding: {:mailbox, "Task.yield on a linked task cannot see it crash"}
  },
  %{
    repo: "elixir-ecto/ecto",
    issue: "ecto#2338",
    module: "Ecto.Repo.Preloader",
    pre: "5422d3158194e872092ee00b46bed89db1e356d8",
    fix: "12a745234fa9bda86620708316b7682bd6454222",
    finding: {:mailbox, "Task.async in library code links to an unknown caller"}
  },
  # The library's public call lives in its `use Supervisor` module and
  # runs in whoever calls it: Task.async linked every caller to the pool
  # worker's task (a crash took the caller down; a timed-out task's
  # reply was left in its mailbox). The fix runs the transaction in the
  # caller with no task.
  %{
    repo: "revelrylabs/elixir-nodejs",
    issue: "elixir-nodejs#45",
    module: "NodeJS.Supervisor",
    pre: "cce7e0f988b59e66da539dd959e241d614b79917",
    fix: "34029b6091093c6d0a79022e2f89203c4c142785",
    finding: {:mailbox, "Task.async in library code links to an unknown caller"}
  },
  %{
    repo: "whatyouhide/redix",
    issue: "redix#334",
    module: "Redix.Cluster.Manager",
    pre: "d3bab6e7be417c0a34f5781844f9d3068b13e489",
    fix: "e67e61a04120cd07507cbf2c372a3f9dc7189bc0",
    finding: {:coupling, "Two restart authorities for the same child"}
  },
  # jackalope 8b7415f "Change the application supervision strategy to rest
  # for one": Hare casts and calls Hare.TortoiseClient, which lives in the
  # sibling Hare.Supervisor branch of the one_for_one Hare.TopSupervisor, so
  # either restarting alone left the other holding subscription state the
  # restart threw away. The fix is the strategy change and nothing else;
  # its message spells out the dependency.
  %{
    repo: "smartrent/jackalope",
    issue: "jackalope@8b7415f",
    module: "Hare.Application",
    pre: "35b067010384f34a3215d2f71b5eba4341d6423d",
    fix: "8b7415f2d9149e3aa80c2ad4cd4cc84d7af869b8",
    finding: {:coupling, "Coupled children under one_for_one"}
  },
  %{
    repo: "phoenixframework/phoenix",
    issue: "phoenix#5981",
    module: "Phoenix.Endpoint.Supervisor",
    pre: "d34efa88e4727994cc22576508cf5878c0567f20",
    fix: "092605f4c3696c4bfe3a531b024030090c1ea23b",
    finding: {:startup, "Shared state written after the tree is up"}
  },
  %{
    repo: "phoenixframework/phoenix_live_view",
    issue: "phoenix_live_view#4359",
    module: "Phoenix.LiveView.Channel",
    pre: "01b8517e3105e475c3499a965bd4ce702b72b0cd",
    fix: "b100e1070c6ff646261392359ce848adb5c29ec6",
    finding: {:blocking, "Peer call catches :noproc but not :shutdown"}
  },
  %{
    repo: "cabol/nebulex",
    issue: "nebulex#140",
    module: "Nebulex.RPC",
    pre: "faff154",
    fix: "bde4e3fe832e8a5b87a2aa2b41f3b356e9e62f18",
    finding: {:failure, ":erpc.call transport failures fall through the rescue"}
  },
  %{
    repo: "whatyouhide/redix",
    issue: "redix#338",
    module: "Redix.Cluster.Manager",
    pre: "b77331e2a0e8e8f5efc35b36ee1258afe7460002",
    fix: "b31bd23ce10623f9b8e0af0f3f7992a54b1a440c",
    finding: {:ets, "ETS table read while its owner may be restarting"}
  },
  %{
    repo: "elixir-ecto/postgrex",
    issue: "postgrex#746",
    module: "Postgrex.Protocol",
    pre: "412b55567b6f0f3feb587e38466fcab047581c0f",
    finding: {:startup, "init/1 waits on a socket with no timeout"}
  },
  %{
    repo: "elixir-lang/gen_stage",
    issue: "gen_stage#238",
    module: "GenStage.Streamer",
    pre: "ee272d3df26ff9463a577e46cac43afdcc989aa5",
    fix: "ae0a6c61bf0a0fdd200a34ce0079296d1480914b",
    finding: {:mailbox, "handle_info/2 has no catch-all"}
  },
  %{
    repo: "commanded/commanded",
    issue: "commanded#332",
    module: "Commanded.ProcessManagers.ProcessManagerInstance",
    pre: "9f45a30",
    finding: {:mailbox, "handle_info/2 has no catch-all"}
  },
  %{
    repo: "elixir-horde/horde",
    issue: "horde#217",
    pre: "74820c2",
    finding: {:blocking, "Synchronous call cycle"}
  },
  %{
    repo: "phoenixframework/phoenix_pubsub",
    issue: "phoenix_pubsub#194",
    module: "Phoenix.Tracker.Shard",
    pre: "8b92e8f8769de8d8ccf3e5a6f9706621717ce3e0",
    fix: "148ae108d5713aa420a4beade69b44939c283a12",
    finding: {:shutdown, "Permanent child stops itself and is restarted"}
  },
  %{
    repo: "elixir-ecto/postgrex",
    issue: "postgrex#781",
    module: "Postgrex.Parameters",
    pre: "313d6c90dea21f320035501e5d7d6a1e34a74cd4",
    fix: "85c7cf430d0c4519cc7cadf6599bcb173276de0f",
    finding: {:mailbox, "Server monitors but never demonitors"}
  },
  # Present-only shapes found on the trees themselves, not from an issue.
  %{
    repo: "whitfin/cachex",
    issue: "cachex:router-rpc-without-timeout",
    module: "Cachex.Router",
    pre: "44ac7e445bba03a9953a46ff61da2f168dd8cc57",
    finding: {:blocking, "RPC without a bounded timeout"}
  },
  %{
    repo: "elixir-horde/horde",
    issue: "horde:signal-shutdown-unguarded-call",
    module: "Horde.SignalShutdown",
    pre: "74820c2",
    finding: {:shutdown, "terminate/2 calls a sibling that may already be down"}
  },
  %{
    repo: "cabol/nebulex",
    issue: "nebulex:bootstrap-global-lock-in-init",
    module: "Nebulex.Adapters.Replicated.Bootstrap",
    pre: "faff154",
    finding: {:startup, "Cluster-wide lock during init"}
  },
  # ── The classes hypothesized after the pass, validated against issues ──
  %{
    repo: "derekkraan/horde",
    issue: "horde:erpc-noconnection-race",
    module: "Horde.Registry",
    pre: "f9ef5c4c9d1ad6f24a619a2252b5f25ec6602493",
    fix: "30bb1a17ebbec4a834bd7b7845ab021e5b696225",
    finding: {:failure, ":erpc.call in a boolean context with no rescue"}
  },
  %{
    repo: "phoenixframework/phoenix_live_dashboard",
    issue: "phoenix_live_dashboard#218",
    # The rpc and its shape match live in the SystemInfo wrapper.
    module: "Phoenix.LiveDashboard.SystemInfo",
    pre: "e562c63922ea3518d7963bef3e84b433dae5cd80",
    finding: {:failure, "RPC result matched without a {:badrpc, _} clause"}
  },
  # The same tree's info components match what SystemInfo's
  # fetch_process_info/1 and its siblings return — each one :rpc.call's
  # answer, passed through — for {:ok, info} and :error only; a node
  # that is gone crashes the component (the class's wrapper arm). The
  # later "Use erpc" commit (20b9e71) makes them raise instead, which is
  # not a fix of the class, so this pair is present-only.
  %{
    repo: "phoenixframework/phoenix_live_dashboard",
    issue: "phoenix_live_dashboard:rpc-wrapper",
    module: "Phoenix.LiveDashboard.ProcessInfoComponent",
    pre: "e562c63922ea3518d7963bef3e84b433dae5cd80",
    finding: {:failure, "RPC result matched without a {:badrpc, _} clause"}
  },
  # EMQX's BPAPI audit (emqx#18287 fixed about fifteen callers of
  # rpc-backed proto modules): the delayed-message DELETE handler matched
  # emqx_delayed:delete_delayed_message/2's result — a facade returning
  # emqx_delayed_proto_v2's `rpc:call` answer — for ok and not_found
  # only, so an unreachable node was a case_clause and a 500. The finding
  # is at the handler's closure, through two wrappers. The monorepo
  # builds from its root, without its QUIC, RocksDB and jq NIFs.
  %{
    repo: "emqx/emqx",
    issue: "emqx#18287",
    module: ":emqx_delayed_api",
    pre: "8fe9f79d71771303515e13e8c9a5f184e081af79",
    fix: "b32a01f559e3afafdb66058fba04d85f45a44a3b",
    otp: "27.3.3",
    elixir: "1.18.3-otp-27",
    app: "emqx_modules",
    env: %{
      "PROFILE" => "emqx-enterprise",
      "MIX_ENV" => "emqx-enterprise",
      "BUILD_WITHOUT_QUIC" => "1",
      "BUILD_WITHOUT_ROCKSDB" => "1",
      "BUILD_WITHOUT_JQ" => "1"
    },
    finding: {:failure, "RPC result matched without a {:badrpc, _} clause"}
  },
  # ── A message a GenServer is sent and has no clause for ────────────
  # oban 5518653 "Remove monitored processes from listeners list": the PG
  # notifier monitored every listener in handle_call and dropped the
  # :DOWN in its catch-all, so dead listeners piled up and it kept
  # dispatching to them. The fix is the :DOWN clause.
  %{
    repo: "oban-bg/oban",
    issue: "oban@5518653",
    module: "Oban.Notifiers.PG",
    pre: "9448f0380da28624c52eaaf83eef08982260eb02",
    fix: "55186534272612aa65ba7e03d62602a012a99fe3",
    finding: {:mailbox, "A message the server is sent reaches only its catch-all handle_info/2"}
  },
  # sequin 6693949: c996f2b made SlotMessageStore arm :max_memory_check
  # from handle_continue with no handle_info clause for it and no
  # catch-all — a FunctionClauseError five minutes after every start.
  # Its locked rabbit_common predates OTP 28's public_key headers.
  %{
    repo: "sequinstream/sequin",
    issue: "sequin@6693949",
    module: "Sequin.DatabasesRuntime.SlotMessageStore",
    otp: "27.3.3",
    elixir: "1.18.3-otp-27",
    pre: "94fbd525996e9c980c57dcccd99f4ba2eaab65dc",
    fix: "6693949a27af272c4783a86536d67911de289d22",
    finding: {:mailbox, "No handle_info/2 clause for a message the server is sent"}
  },
  # sequin 035ee6f "Remove sensitive sink values from IO.inspect": NatsSink
  # held a NATS password, JWT and nkey seed and printed all three; the fix
  # is `@derive {Inspect, except: [:password, :jwt, :nkey_seed]}`, no
  # `redact: true`. Only :password is in the name table (the other two are
  # a prior's, which the corpus runs without); the derive hides all three.
  %{
    repo: "sequinstream/sequin",
    issue: "sequin@035ee6f",
    module: "Sequin.Consumers.NatsSink",
    otp: "27.3.3",
    elixir: "1.18.3-otp-27",
    pre: "ad46d68c109354a3f6a554c1eb5a120fd7c90834",
    fix: "035ee6fcbb399f8920d4468d217853b0bcd051da",
    finding: {:exposure, "Secret field printed by inspect/1"}
  },
  # astarte f3edb85 "correctly reconnect to amqp after a connection loss":
  # a refactor removed AMQPEventsProducer's :init clause and left
  # schedule_connect/0 re-arming :init after a lost connection; its only
  # clause took :DOWN. Its locked rabbit_common uses `maybe` as an atom,
  # a keyword from OTP 27.
  %{
    repo: "astarte-platform/astarte",
    issue: "astarte@f3edb85",
    subdir: "apps/astarte_data_updater_plant",
    module: "Astarte.DataUpdaterPlant.AMQPEventsProducer",
    otp: "26.2.5.6",
    elixir: "1.18.4-otp-26",
    pre: "6539a98bf4ebd1d43940aa083717669b1f5f6c07",
    fix: "f3edb85d33c4151cf6b8a1770eae8da3d7040865",
    finding: {:mailbox, "No handle_info/2 clause for a message the server is sent"}
  },
  %{
    repo: "beam-bots/bb",
    issue: "bb#214",
    module: "BB.Loop",
    pre: "6c5dc2b5a22f8cf532a696f46d40e2ee79e3a53a",
    fix: "4bd552ca6a816614f6059c9d2e98fc583a27de16",
    finding: {:mailbox, "Timer cancelled without flushing its message"}
  },
  %{
    repo: "cabol/nebulex",
    issue: "nebulex:generation-heartbeat-no-flush",
    module: "Nebulex.Adapters.Local.Generation",
    pre: "faff154",
    finding: {:mailbox, "Timer cancelled without flushing its message"}
  },
  # tortoise#46 (70044be -> b891da1) is the connect-in-init pair, but its
  # 2018 tree no longer compiles on Elixir >= 1.15 (a recursive variable
  # in a pattern); the rule is pinned by fixtures until a buildable pair
  # turns up.
  %{
    repo: "elixir-horde/horde",
    issue: "horde#193",
    # Anchored at the impl's handle_call that stops the sibling; the
    # sibling's stop API it goes through is the related frame.
    module: "Horde.DynamicSupervisorImpl",
    pre: "74820c2",
    finding: {:shutdown, "A callback stops a sibling the supervisor owns"}
  },
  # phoenix_storybook 96d5246 "Fix atom exhaustion from playground LiveView
  # params": handle_event("upper-tab-navigation", %{"tab" => tab}, _) called
  # String.to_atom(tab); the fix looks the tab up in an allowlist. No PR; the
  # fix went straight to main, and its parent is on main.
  %{
    repo: "phenixdigital/phoenix_storybook",
    issue: "phoenix_storybook@96d5246",
    module: "PhoenixStorybook.Story.Playground",
    pre: "56ab8464d4375fa52db806148a06cce126ad481d",
    fix: "96d524690af0fe197a49f60d18e564a620b9ef81",
    finding:
      {:unsafe_input, "Unbounded atom creation fed by request data from a LiveComponent event"}
  },
  # The same fix, seen from the LiveView: handle_params/3 reached the tab and
  # theme conversions through current_tab/2 and current_theme/2.
  %{
    repo: "phenixdigital/phoenix_storybook",
    issue: "phoenix_storybook@96d5246 (StoryLive)",
    module: "PhoenixStorybook.StoryLive",
    pre: "56ab8464d4375fa52db806148a06cce126ad481d",
    fix: "96d524690af0fe197a49f60d18e564a620b9ef81",
    finding:
      {:unsafe_input, "Unbounded atom creation fed by request data from a LiveView callback"}
  },
  # hammer#94: count_hit/4 asked :ets.member/2 whether the bucket existed and
  # inserted it when it did not, on the public buckets table; the fix is one
  # update_counter/4 with a default. The PR calls itself a performance change,
  # and the single operation is also what removes the race.
  %{
    repo: "ExHammer/hammer",
    issue: "hammer#94",
    module: "Hammer.Backend.ETS",
    pre: "f86fe7ef56d0125f804fb67800f8160e2833b011",
    fix: "8c7a5b2f2940c615b5ae23ee5b67e5c5a6fc0a72",
    finding: {:races, "Read-then-write race on an ETS key"}
  },
  # hammer#129: the atomic backends looked a key up and, when it was absent,
  # inserted a fresh :atomics array with insert; two first hits each insert
  # one, and the hit counted into the replaced array is lost. The table is
  # the one `use Hammer` hands in, which nothing in the library names. #130
  # (7.0.1) makes the first array with insert_new in each hit/5, and misses
  # the same shape in Hammer.Atomic.FixWindow's inc/4 and set/4, which the
  # rule still reports at the fix — hence LeakyBucket here.
  %{
    repo: "ExHammer/hammer",
    issue: "hammer#129",
    module: "Hammer.Atomic.LeakyBucket",
    pre: "7dcff06c63916a126dc780e15371136126932222",
    fix: "252029ee0d9207b21144093fc466346e5f8368a5",
    finding: {:races, "Read-then-write race on an ETS key"}
  },
  # tesla#768: Tesla.Mock.agent_set/1 looked the mock agent up by name and
  # started it under the test supervisor when absent; two tests doing so at
  # once made one of them lose. The fix takes {:error, {:already_started, _}}.
  %{
    repo: "elixir-tesla/tesla",
    issue: "tesla#768",
    module: "Tesla.Mock",
    pre: "727cb0f",
    fix: "8cf7745",
    finding: {:races, "Lookup-then-start race on a process name"}
  },
  # supavisor a8463de: DbHandler.handle_prepared_statement_pkts/2 calls
  # :gen_statem.call/3 bare while its three sibling sites catch :exit and
  # return {:error, _}; its only caller halts on {:error, _}, so a dead or slow
  # DbHandler crashes the ClientHandler instead. No issue and no fix, so the
  # pair is present-only. The four are DbHandler's client API, each calling
  # the pid it is handed: one population, the module's processes.
  %{
    repo: "supabase/supavisor",
    issue: "supavisor@a8463de",
    module: "Supavisor.DbHandler",
    pre: "a8463de46ae77fb3a2f49a53eda1d6680caa0ad3",
    finding: {:failure, "Call made bare where other call sites catch its exit"}
  },
  # blockster_v2 e8b3d3c: EngagementTracker.deduct_user_token_balance/4 reads
  # a user's balances with a dirty_read in one helper and writes the deducted
  # balance with a dirty_write in another, from LiveView processes — the
  # double spend its own shop GenServer exists to prevent. The read and the
  # write meet across functions. No fix, so the pair is present-only.
  %{
    repo: "rubyad/blockster_v2",
    issue: "blockster_v2@e8b3d3c",
    module: "BlocksterV2.EngagementTracker",
    pre: "e8b3d3c143825d88ef0993f788a6053b2b527acc",
    finding: {:races, "Read-then-write race on a Mnesia record"}
  },
  # ztlp 39fa329: ZtlpNs.Store.do_insert/1 dirty_reads a record, compares its
  # serial, and dirty_writes the new one, from concurrent Task.Supervisor
  # workers: two updates both pass the check and the older can win. The key
  # is a tuple built at runtime, the same value handed to both calls.
  # Present-only; the Mix project is under ns/.
  %{
    repo: "priceflex/ztlp",
    issue: "ztlp@39fa329",
    subdir: "ns",
    module: "ZtlpNs.Store",
    pre: "39fa3297a256bf69bad33d4152e18de745d6dc59",
    finding: {:races, "Read-then-write race on a Mnesia record"}
  },
  # elvengard_ecs 1118693 "Fix MnesiaBackend race condition on insert_new":
  # do_insert_new/4 dirty_reads {type, key} and dirty_writes the record when
  # the read is empty — an insert-if-absent two processes can both pass.
  # The helper names the key by its parameters and the record whole, so
  # they are one record only where create_entity/3 builds it and
  # insert_new/1 hands it on as elements and whole. The fix moves the pair
  # into a transaction.
  %{
    repo: "elvengard-mmo/elvengard_ecs",
    issue: "elvengard_ecs@1118693",
    module: "ElvenGard.ECS.MnesiaBackend",
    pre: "20c52974c4f58f3921203416202fc413714df40e",
    fix: "1118693fcf6f1413b048a5dd8e0c5e5520f90d4e",
    finding: {:races, "Read-then-write race on a Mnesia record"}
  },
  # ── exposure: a secret inspect/1 prints ──────────────────────────────
  # langchain#266 redacted :api_key in six embedded schemas at once and
  # missed ChatPerplexity, which still reports at fix — the module anchor
  # is what keeps that one from standing in for this one.
  %{
    repo: "brainlid/langchain",
    issue: "langchain#266",
    module: "LangChain.ChatModels.ChatAnthropic",
    pre: "3e02d6b417b7041c0420b1f8cd937f479ea385ae",
    fix: "38e957d2985b054ce51e087b51bb1af54aee9754",
    finding: {:exposure, "Secret field printed by inspect/1"}
  },
  %{
    repo: "supabase/supavisor",
    issue: "supavisor#746",
    module: "Supavisor.Tenants.User",
    pre: "0e85637a03483c60c4e10b6708cbe29933f23fcb",
    fix: "1bf7b4b6785832608478909f19938d94b8b779e0",
    finding: {:exposure, "Secret field printed by inspect/1"}
  },
  # The aware arm: two virtual password fields beside it were already
  # redact: true, so the stored hash was an oversight, not an unfamiliar API.
  %{
    repo: "nerves-hub/nerves_hub_web",
    issue: "nerves_hub_web#2828",
    module: "NervesHub.Accounts.User",
    pre: "59ccadd36f2861c667c488937dea66fc35488fe7",
    fix: "3ab4e8cd77ac9dd7259085f47d70396697d988ed",
    finding: {:exposure, "Secret field printed by inspect/1"}
  },
  # ── unsafe_input: atom creation ───────────────────────────────────────
  # Federation representation keys arrive through the open-ended _Any
  # scalar, so they bypass schema coercion; the fix is to_existing_atom
  # with a rescue.
  %{
    repo: "DivvyPayHQ/absinthe_federation",
    issue: "absinthe_federation#133",
    module: "Absinthe.Federation.Schema.EntitiesField",
    pre: "c53bb3b3e87051f234cebad7aa9a96311f2f6c2b",
    fix: "c3838cda2a7f65c4893291668c223b0d6acf4516",
    finding: {:unsafe_input, "Dynamic atom creation reachable from an exported function"}
  },
  # The devices API put the raw `sort_direction` query param through
  # String.to_atom/1; the fix maps "desc" and anything else to two atoms.
  # The action is reached only through Phoenix's apply in action/2, so
  # the finding needs controller actions as request entries.
  %{
    repo: "nerves-hub/nerves_hub_web",
    issue: "nerves_hub_web#2942",
    module: "NervesHubWeb.API.DeviceController",
    pre: "0bb6b5cc55b801d97fa2fa72218eb7124e23e0c5",
    fix: "3c4bcf5017bd91493437d6ad836d1e2427f618ba",
    finding:
      {:unsafe_input,
       "Unbounded atom creation fed by request data from a Phoenix controller action (HTTP request)"}
  },
  # CVE-2026-48597: String.to_atom(uri.scheme) in the Mint adapter, fixed
  # with a two-clause allowlist — the remediation the finding recommends.
  %{
    repo: "elixir-tesla/tesla",
    issue: "tesla:GHSA-h74c-q9j7-mpcm",
    module: "Tesla.Adapter.Mint",
    pre: "bb1a2c3da2775924d96e3db8e315dcc4d5d2246e",
    fix: "4699c3cb3e2fd6078f99f45f11cf7466aeedbf0e",
    finding: {:unsafe_input, "Dynamic atom creation reachable from an exported function"}
  },
  # CVE-2026-53423: every 4-byte MP4 box name interned as an atom — the
  # same class sourced from file bytes rather than from params.
  %{
    repo: "membraneframework/membrane_mp4_plugin",
    issue: "membrane_mp4_plugin#135",
    module: "Membrane.MP4.Container.Header",
    pre: "6a7458b7f13a2f48578affe4431d05c994c1b9df",
    fix: "56373d1ddc86968e55fbde795c14eeba24357b57",
    finding: {:unsafe_input, "Dynamic atom creation reachable from an exported function"}
  },
  # ── unsafe_input: decompression ───────────────────────────────────────
  # GHSA-mc85-72gr-vm9f: the Compression middleware gunzipped (and
  # unzipped) the response body its call/3 is handed in one call, so a
  # hostile server's few hundred bytes of layered gzip inflated into
  # gigabytes; the fix streams through :zlib.safeInflate/2 under a
  # required :max_body_size.
  %{
    repo: "elixir-tesla/tesla",
    issue: "tesla:GHSA-mc85-72gr-vm9f",
    module: "Tesla.Middleware.Compression",
    pre: "db963dba67651b9abd1fc420a1d9679cf6efe182",
    fix: "340f75b5d191dc747ef7ac6365bd002d1cd55a9d",
    finding: {:unsafe_input, "Unbounded decompression of a caller's input"}
  },
  # GHSA-frh3-6pv6-rc8j: permessage-deflate inflated a whole WebSocket
  # frame with :zlib.inflate/2; the fix inflates with safeInflate under a
  # max_inflate_ratio. The frame reaches the inflate from the connection's
  # handle_data/3 through frame parsing the flow summaries do not follow
  # (a local helper's return), so the finding is a path, at :info.
  %{
    repo: "mtrudel/bandit",
    issue: "bandit:GHSA-frh3-6pv6-rc8j",
    module: "Bandit.WebSocket.PerMessageDeflate",
    pre: "fc3cf61f636f1f2acd708783a260dd494c3444fe",
    fix: "8156921a51e684a951221da7bc30a70a022f722e",
    finding:
      {:unsafe_input,
       "Unbounded decompression transitively reachable from a ThousandIsland handler (socket data)"}
  },
  # ── unsafe_input: deserialization ─────────────────────────────────────
  # Paginator decodes an opaque cursor straight off the query string. The
  # two commits are the two steps down: paginator#16 added [:safe], which
  # clears "without :safe" but leaves the [:safe] warning (a fun that
  # references a loaded module still deserializes); the later move to
  # Plug.Crypto.non_executable_binary_to_term/2 clears the sink.
  %{
    repo: "duffelhq/paginator",
    issue: "paginator#16",
    module: "Paginator.Cursor",
    pre: "3142b9f38b6f7949404dc0aef23bb02cc3b462e7",
    fix: "01ed029876f221c2fc6694999aba98b7beeda585",
    finding: {:unsafe_input, "binary_to_term without :safe"}
  },
  %{
    repo: "duffelhq/paginator",
    issue: "paginator:non-executable-binary-to-term",
    module: "Paginator.Cursor",
    pre: "24237ba10e17ae77adb4e3a3e5d34abf730221c4",
    fix: "b4945c6e30b2b2599047ad3c10389671662c3bad",
    finding: {:unsafe_input, "binary_to_term with [:safe] and no shape check"}
  },
  # sequin 46ce4e1, present-only and live at upstream HEAD: DebouncedLogger.log/4
  # looks a bucket up and then calls :ets.update_counter/3 bare, while the
  # flush the first call scheduled with :timer.apply_after takes the same row
  # from another process; a caller that logs in that window crashes with
  # ArgumentError. It was also a failure.inconsistent_handling pair, judged
  # by the three rescued update_counter sites of Sequin.Benchmark.Stats —
  # on the benchmark's own two tables, not the logger's, whose table is
  # `cfg.table_name || @default_table` and no literal. A belief is now
  # keyed on its target, and another table's convention is not this
  # table's: that pair was right about the bug for a reason that is not
  # evidence, and is gone. The race below is the finding that says why.
  #
  # The same bug as the race it is: log/4's lookup decides the bucket is
  # there and update_counter/3 acts on it, while flush_bucket/4, which a
  # :timer.apply_after runs in a process of its own, takes the row. The
  # table is `cfg.table_name || @default_table`, the default's arm naming
  # the table setup_ets/0 creates.
  %{
    repo: "sequinstream/sequin",
    issue: "sequin@46ce4e1",
    module: "Sequin.DebouncedLogger",
    pre: "46ce4e1048437575ce3c40ebb3eb589a4b9e4f27",
    finding: {:races, "ETS row acted on after another process may have removed it"}
  },
  # ── Round-1 mining: fixes of classes argus already reports ───────────
  # Each is a fix a project made for a bug argus's rule describes, found
  # by the 2026-09-25 mining and verified on both sides.
  #
  # broadway_kafka: the producer waited for the coordinator's :DOWN in a
  # blocking receive inside handle_info, and deadlocked; the fix drops the
  # receive.
  %{
    repo: "dashbitco/broadway_kafka",
    issue: "broadway_kafka@e380290",
    module: "BroadwayKafka.Producer",
    pre: "6ef6f41fab0fa5bcf8b322ac9129042c8ce45ceb",
    fix: "e380290c47077fbdee96d7c49c7b25730b972fe7",
    finding: {:blocking, "Blocking receive inside an OTP callback"}
  },
  # supavisor: the client handler threw away the ref of its manager
  # monitor, so any :DOWN read as "the manager went down".
  %{
    repo: "supabase/supavisor",
    issue: "supavisor@e80c9a2",
    module: "Supavisor.ClientHandler",
    pre: "0fe14108d26bfeb13e403a24885179cd0abe6f4a",
    fix: "e80c9a2cf7c56bb3fdfebb850992d913311a46c1",
    finding: {:mailbox, "Server drops the ref of a monitor it establishes"}
  },
  # oban#532, the bug coupling's rest_for_one rule was written from: the
  # queue producer starts jobs under the Task.Supervisor started before
  # it, and a producer restart left the old jobs running; the fix is
  # :one_for_all.
  %{
    repo: "oban-bg/oban",
    issue: "oban#532",
    module: "Oban.Queue.Producer",
    pre: "5c64333de16d4707be8a04628401610912c04b07",
    fix: "f5afde4bb41784e09069cdfc97b1307f53a6acc1",
    finding: {:coupling, "rest_for_one restarts the owner but not the processes it started"}
  },
  # livebook: three Task.Supervisor.start_child results discarded; the
  # fix matches them.
  %{
    repo: "livebook-dev/livebook",
    issue: "livebook@56ecd47",
    module: "Livebook.Hubs",
    pre: "c70c4d9ff5ba63aa6136eebe22df578d8704398f",
    fix: "56ecd4775f34f876fec940f07570ad19d6520404",
    finding: {:failure, "start_child result ignored"}
  },
  # finch: an async HTTP/1 request ran in a bare spawn that outlived its
  # caller; the fix links it.
  %{
    repo: "sneako/finch",
    issue: "finch@9ae43ef",
    module: "Finch.HTTP1.Pool",
    pre: "8bae1ce64132b1866bdab33b8dae055a0e444de8",
    fix: "9ae43ef7f71aef81583e2ff1ef74512613ce788d",
    finding: {:failure, "Unlinked process spawned"}
  },
  # postgrex: SimpleConnection armed a {:timeout, ms, _} action and took
  # it as (:info, :timeout, ...), so the idle ping never ran.
  %{
    repo: "elixir-ecto/postgrex",
    issue: "postgrex@83bac66",
    module: "Postgrex.SimpleConnection",
    pre: "0b73cfa852d9178762ec81af86f783548386ce9e",
    fix: "83bac660991e0d7e138e96dbb5ffff3fc22a9065",
    finding: {:mailbox, "Timeout armed but never handled"}
  },
  # phoenix_live_view: UploadChannel trapped exits with no {:EXIT, ...}
  # clause. (LiveViewTest's UploadClient keeps the shape at the fix.)
  %{
    repo: "phoenixframework/phoenix_live_view",
    issue: "phoenix_live_view@2b4d182",
    module: "Phoenix.LiveView.UploadChannel",
    pre: "de8963239539d2f9520562c360d2afa2a10620fc",
    fix: "2b4d182a7457d960da20fd1566e20388bd089beb",
    finding: {:shutdown, "trap_exit without an {:EXIT, ...} clause"}
  },
  # bandit: the HTTP/1 handler trapped exits with no {:EXIT, ...} clause.
  # (InitialHandler keeps the shape at the fix.)
  %{
    repo: "mtrudel/bandit",
    issue: "bandit@094d3c5",
    module: "Bandit.HTTP1.Handler",
    pre: "f72e4e8d47558a6cd6d5314579d5c0dc77d849fa",
    fix: "094d3c58f5bc3ce2ab90442be2ba7348d918e6b3",
    finding: {:shutdown, "trap_exit without an {:EXIT, ...} clause"}
  },
  # anubis-mcp#209: Session replied to its pending callers in terminate/2
  # and never trapped exits, so a DynamicSupervisor.terminate_child
  # skipped it; the fix traps exits.
  %{
    repo: "zoedsoupe/anubis-mcp",
    issue: "anubis-mcp#209",
    module: "Anubis.Server.Session",
    pre: "ca0b9631554cb2657d930c0f10a50afddf17fe95",
    fix: "a224c00f2e5df92cd6b19a561f74ef102c54739d",
    finding: {:shutdown, "Cleanup in terminate/2 of a process that never traps exits"}
  },
  # ── blocking: a socket call with no timeout inside a callback ────────
  # kafka_ex#556: the client's reconnect ran :gen_tcp.connect/3, whose
  # timeout is the operating system's, from its handle_call/handle_info;
  # against a black-holed broker every produce, fetch and commit behind it
  # stalled for minutes. The fix passes connect/4 a timeout.
  %{
    repo: "kafkaex/kafka_ex",
    issue: "kafka_ex#556",
    module: "KafkaEx.Network.Socket",
    pre: "c6ba2a73c1ff96f8943e6cf40a0bf10722217efc",
    fix: "e33abf0bc5d34137c7cfc5513801c9ccbb2b5a62",
    finding: {:blocking, "Socket call with no timeout inside a callback"}
  },
  # supavisor#1153: a client that sends an SSLRequest and stalls mid-TLS
  # handshake held its ClientHandler, and its socket, forever: the
  # handshake ran in a gen_statem callback as :ssl.handshake/2 with options,
  # so no state timeout could fire. The fix passes handshake/3 2.5 s.
  # (Supavisor.ClientHandler.Cancel's connect to the database stays at fix.)
  %{
    repo: "supabase/supavisor",
    issue: "supavisor#1153",
    module: "Supavisor.ClientHandler",
    pre: "369dc8003667b44acada3e5700c993d6027d420a",
    fix: "9d7df2d8c33d01bb1c3e69cb8c0ea118ed9fc4d4",
    finding: {:blocking, "Socket call with no timeout inside a callback"}
  },
  # redix#99: SocketOwner's handle_info(:connect) read the AUTH and SELECT
  # replies with :gen_tcp.recv/2; the fix threads the connect timeout in.
  %{
    repo: "whatyouhide/redix",
    issue: "redix#99",
    module: "Redix.Utils",
    pre: "0d25d1fa036bc74e261ab9649e2b1245767d1a8c",
    fix: "9a2eed624bb20bd89c6b0e14a764e53936fd256c",
    finding: {:blocking, "Socket call with no timeout inside a callback"}
  },
  # supavisor#962: the DbHandler gen_statem connected upstream with
  # :gen_tcp.connect/3 in its :connect event; the fix gives connect/4 1 s
  # behind a proxy, 5 s otherwise.
  %{
    repo: "supabase/supavisor",
    issue: "supavisor#962",
    module: "Supavisor.DbHandler",
    pre: "b1a680a9fd04d37553f0a5bbfdc84b16d4fe2913",
    fix: "08c14231e920304e2e5265e05f4f6ab6c05560ce",
    finding: {:blocking, "Socket call with no timeout inside a callback"}
  },
  # aprs.me: AprsIsConnection's handle_info(:connect) called
  # :gen_tcp.connect/3; the fix passes 10 s. (Aprsme.Is keeps its own
  # untimed connect at the fix.)
  %{
    repo: "aprsme/aprs.me",
    issue: "aprs.me@709780f",
    module: "Aprsme.AprsIsConnection",
    pre: "d8ea2b785f9fa334472fc7c87ea67b5d143950d8",
    fix: "709780ff24495318305c1297287577e229c53d80",
    finding: {:blocking, "Socket call with no timeout inside a callback"}
  },
  # ── mailbox: the close of a socket the server holds ──────────────────
  # exshome: MpvSocket connected to mpv with :gen_tcp.connect/3, whose
  # socket is active by default, and took only its data; the first mpv
  # restart crashed it. The fix adds a {:tcp_closed, _} clause that
  # reconnects.
  %{
    repo: "exshome/exshome",
    issue: "exshome@c1e2a01",
    module: "Exshome.MpvSocket",
    pre: "f89ed6ec0b4388a32aff889501701fb5ce617c6b",
    fix: "c1e2a0154d30acc943ed28b0087ed4b7797c730a",
    finding: {:mailbox, "No handle_info/2 clause for the close of the server's socket"}
  },
  # ── ets: a named table a server's start_link creates ─────────────────
  # ex_uid2: Dsp.start_link created the named keyring table and then
  # started the GenServer, so the table belonged to the supervisor and a
  # restart raised on :ets.new; the fix moves the call into init/1.
  %{
    repo: "market-ops/ex_uid2",
    issue: "ex_uid2@69e7279",
    module: "ExUid2.Dsp",
    pre: "b3e9fad7c9576123a96c6b8a34130cf76dfe6bbd",
    fix: "69e72793b5b2ecabe4848d6ca2088d0575c31ca9",
    finding: {:ets, "Named ETS table created in start_link fails the server's restart"}
  },
  # ── mailbox: a periodic timer loop armed again while it runs ─────────
  # ant: Ant.Queue's three :check_workers clauses re-arm through
  # schedule_check/1 and drop the ref, and every finished job's
  # handle_call({:dequeue, _}) arms :check_workers again, so the queue
  # polled once more per interval for every job done. The fix keeps the
  # ref and cancels it before re-arming ("Without cancelling, the timer
  # would fire multiple times within the check interval").
  %{
    repo: "MikeAndrianov/ant",
    issue: "ant@b6f9f90",
    module: "Ant.Queue",
    pre: "01e5e4309e9e64493cc1bc8bcf3da996990d0a6b",
    fix: "b6f9f90e1ee2661b478c272ccb8a0146b5195821",
    finding: {:mailbox, "Periodic timer loop armed again while it runs"}
  },
  # xandra: the control connection's refresh loop re-arms
  # :refresh_topology after every refresh and drops the ref, and each
  # NEW_NODE or REMOVED_NODE push event (from the socket clause) arms
  # another: one more topology query loop per topology change. The fix
  # keeps the ref and cancels it before re-arming.
  %{
    repo: "whatyouhide/xandra",
    issue: "xandra#411",
    module: "Xandra.Cluster.ControlConnection",
    pre: "9687585283eaae179c4eab35e4af9b23cc048727",
    fix: "ffe09a867b1a7ff16ea7bc8005e6645ea2f96635",
    finding: {:mailbox, "Periodic timer loop armed again while it runs"}
  },
  # sequin: the consumer producer's receive loop stores its ref under
  # receive_timer and never reads it, and every handle_demand/2 enters
  # the same function and arms another poll ("stop hammering our
  # database"). Broadway's own producers head that function with
  # `receive_timer: nil`; the fix arms only in init/1 and the loop.
  %{
    repo: "sequinstream/sequin",
    issue: "sequin#371",
    module: "Sequin.ConsumersRuntime.ConsumerProducer",
    pre: "45aaaf8c849e9a92c7499f7866b57cd500ab8464",
    fix: "f17a93ec3174e8f1698cba32aa274fd6ae1ab81d",
    otp: "27.3.3",
    elixir: "1.18.3-otp-27",
    finding: {:mailbox, "Periodic timer loop armed again while it runs"}
  },
  # ── effects: an effect a rollback cannot undo, inside a transaction ──
  # nerves_hub_web: update_deployment/2 broadcast "deployments/update"
  # from inside its Repo.transaction, and the orchestrator and device
  # channels reloaded the deployment before the transaction committed
  # (stale data). The fix (bd1847c) broadcasts the update on {:ok, _},
  # after the commit, and leaves audit_changes!/2's "archives/updated"
  # broadcast inside the transaction, so the finding stays: present-only.
  # Found by round 3 of the mining, once Phoenix.PubSub was an effect.
  %{
    repo: "nerves-hub/nerves_hub_web",
    issue: "nerves_hub_web@bd1847c",
    module: "NervesHub.Deployments",
    pre: "dca4c520d01aa8413130db620ec12cd906c77360",
    # Its phoenix_html 3.3 does not compile under 1.19.
    otp: "27.3.3",
    elixir: "1.18.3-otp-27",
    finding: {:effects, "A process operation inside a transaction"}
  },
  # ── failure: a local-only BIF on a pid that may be another node's ────
  # aprs.me: the leader election's cleanup called Process.alive?/1 on the
  # pid :global.whereis_name/1 answered, usually another node's, and the
  # node check came after it; the fix asks node(pid) == node() first and
  # rpcs a remote pid. The tree vendors its `aprs` dependency as a
  # submodule, and its regexes in module attributes need OTP 27.
  %{
    repo: "aprsme/aprs.me",
    issue: "aprs.me@37c9ac7",
    module: "Aprsme.Cluster.LeaderElection",
    pre: "9caab57dbe3dafcfe2e5c634c0c2c9343fc56cf4",
    fix: "37c9ac79ed238f0295a4af7794d54f0c1ec246a9",
    otp: "27.3.3",
    elixir: "1.18.3-otp-27",
    submodules: true,
    finding: {:failure, "Local-only BIF on a pid that may be on another node"}
  },
  # aprs.me: the :global conflict resolver asked Process.info/2 of both
  # holders of the name, one of them always on another node; the fix
  # chooses by node name.
  %{
    repo: "aprsme/aprs.me",
    issue: "aprs.me@9212088",
    module: "Aprsme.Cluster.LeaderElection",
    pre: "777acc2700304992bb31ee7a75ea61c9a0dec295",
    fix: "9212088bebb0fb76bc56b7a4febd889d3c03fd9e",
    otp: "27.3.3",
    elixir: "1.18.3-otp-27",
    submodules: true,
    finding: {:failure, "Local-only BIF on a pid that may be on another node"}
  },
  # phoenix_live_dashboard: the application tree walked a process's
  # links and asked each for its group leader, and a link may be another
  # node's; the fix asks node(pid) == node() first.
  %{
    repo: "phoenixframework/phoenix_live_dashboard",
    issue: "phoenix_live_dashboard#495",
    module: "Phoenix.LiveDashboard.SystemInfo",
    pre: "f12805a9f800d03631219f9f9d5108e49d1b2771",
    fix: "57e8a1f834615cb2385e81eae7c6d1d15d47b4c9",
    finding: {:failure, "Local-only BIF on a pid that may be on another node"}
  },
  # ── failure: an rpc to a function the module does not export ─────────
  # realtime: transaction/3's remote clause erpc'd transaction/4 through
  # Realtime.Rpc.enhanced_call/5, and the module defined transaction/2,3;
  # the fix adds the fourth parameter. (realtime#818's run_db_request/2,
  # the same shape, is a 2024 tree that builds on no installed toolchain.)
  %{
    repo: "supabase/realtime",
    issue: "realtime#1229",
    module: "Realtime.Database",
    pre: "0147dbb737765df4aa3ff8daeaa68b423d31e593",
    fix: "ac00218ec00a606463a836c4df9dce6d38f4d29a",
    otp: "27.3.3",
    elixir: "1.18.3-otp-27",
    finding: {:failure, "RPC to a function the module does not export"}
  },
  # ── failure: a file, socket or port an error path loses ──────────────
  # thousand_island: sendfile/4 opened a raw fd per call and never closed
  # it, on both transports; the fix closes it in an `after`.
  %{
    repo: "mtrudel/thousand_island",
    issue: "thousand_island#78",
    module: "ThousandIsland.Transports.TCP",
    pre: "db0db573754a3ee096353bcb2a97c402d48ac6a5",
    fix: "45e7b511773863c0c97623b2ea0b81879b5d6560",
    finding: {:failure, "File, socket or port lost on a path that never closes it"}
  },
  # ── mailbox: a subscription made again each time a callback runs ─────
  # nerves_hub_web: the device list re-subscribed each listed device
  # through socket.endpoint on every refresh, and never unsubscribed the
  # old ones ("runaway duplicate PubSub subscriptions"); the fix
  # unsubscribes them first.
  %{
    repo: "nerves-hub/nerves_hub_web",
    issue: "nerves_hub_web#2588",
    module: "NervesHubWeb.Live.Devices.Index",
    pre: "29e5b56765ce53503e8004328b7d56711c3a17a9",
    fix: "59dd4c6182cf173b602fa500361cbfce6cec833f",
    finding: {:mailbox, "Subscription made again each time a callback runs"}
  },
  # ── shutdown: a Broadway producer that keeps fetching while it drains ─
  # Broadway 1.1 stopped switching a draining producer to :accumulate,
  # and three producers' prepare_for_draining/1 only cancelled the poll
  # and cleared receive_timer, the field their fetch asks to be nil: the
  # next demand fetched again. Each fix adds `draining: true` and a first
  # clause that takes it.
  %{
    repo: "elixir-broadway/broadway_sqs",
    issue: "broadway_sqs@5b8f18a",
    module: "BroadwaySQS.Producer",
    pre: "fb517d7656db36b803b2511f718d9b69c7e9d332",
    fix: "5b8f18a78e4760b5fcc839ad576be8c63345add0",
    finding: {:shutdown, "Broadway producer keeps fetching while it drains"}
  },
  %{
    repo: "elixir-broadway/broadway_cloud_pub_sub",
    issue: "broadway_cloud_pub_sub@fb44279",
    module: "BroadwayCloudPubSub.Producer",
    pre: "5c432c0f399a4c7fe83e3c7a826d55fd8e6443c3",
    fix: "fb442793f264e4abd82f8bbb4870d9de028c3a50",
    finding: {:shutdown, "Broadway producer keeps fetching while it drains"}
  },
  %{
    repo: "akash-akya/off_broadway_redis_stream",
    issue: "off_broadway_redis_stream#58",
    module: "OffBroadwayRedisStream.Producer",
    pre: "39ebe39cf1e727c362cfa8d442ca20ad2252c084",
    fix: "60ec40f2a5b9bbf1fd10025190f3abf1b1f1701e",
    finding: {:shutdown, "Broadway producer keeps fetching while it drains"}
  },
  # ── structure: a supervisor its own child_spec/1 registers as a worker ─
  # Round 4 of the mining (M4-25): TenantSupervisor, a `use Supervisor`
  # module, overrode child_spec/1 with a map that said restart: :transient
  # and nothing of its type, and DynamicSupervisor.start_child/2 started
  # every tenant's tree as a worker; the fix added type: :supervisor.
  %{
    repo: "supabase/supavisor",
    issue: "supavisor#850",
    module: "Supavisor.TenantSupervisor",
    pre: "d2234462d2a272eea242ce06a3158be3fddd7f23",
    fix: "6b77121fc697b419e8203bac1c52a69910bb80f3",
    # Its locked credo and artificery build only on OTP 27 and Elixir 1.18.
    otp: "27.3.3",
    elixir: "1.18.3-otp-27",
    finding: {:structure, "Supervisor registered as a worker"}
  }
]
