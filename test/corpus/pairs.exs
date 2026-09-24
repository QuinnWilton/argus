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
    finding: {:shutdown, "children started under another tree outlive their owner"}
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
    finding: {:mailbox, "Postgrex.Parameters monitors but never demonitors"}
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
    finding: {:exposure, "Sequin.Consumers.NatsSink.password is printed by inspect/1"}
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
  # pair is present-only.
  %{
    repo: "supabase/supavisor",
    issue: "supavisor@a8463de",
    module: "Supavisor.DbHandler",
    pre: "a8463de46ae77fb3a2f49a53eda1d6680caa0ad3",
    finding:
      {:failure, ":gen_statem.call/3 called bare where every other call site catches its exit"}
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
    finding: {:exposure, "LangChain.ChatModels.ChatAnthropic.api_key is printed by inspect/1"}
  },
  %{
    repo: "supabase/supavisor",
    issue: "supavisor#746",
    module: "Supavisor.Tenants.User",
    pre: "0e85637a03483c60c4e10b6708cbe29933f23fcb",
    fix: "1bf7b4b6785832608478909f19938d94b8b779e0",
    finding: {:exposure, "Supavisor.Tenants.User.db_password is printed by inspect/1"}
  },
  # The aware arm: two virtual password fields beside it were already
  # redact: true, so the stored hash was an oversight, not an unfamiliar API.
  %{
    repo: "nerves-hub/nerves_hub_web",
    issue: "nerves_hub_web#2828",
    module: "NervesHub.Accounts.User",
    pre: "59ccadd36f2861c667c488937dea66fc35488fe7",
    fix: "3ab4e8cd77ac9dd7259085f47d70396697d988ed",
    finding: {:exposure, "NervesHub.Accounts.User.password_hash is printed by inspect/1"}
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
  # ArgumentError. The three other update_counter sites in the tree rescue it.
  %{
    repo: "sequinstream/sequin",
    issue: "sequin@46ce4e1",
    module: "Sequin.DebouncedLogger",
    pre: "46ce4e1048437575ce3c40ebb3eb589a4b9e4f27",
    finding:
      {:failure,
       ":ets.update_counter/3 called bare where every other call site catches its error"}
  },
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
  }
]
