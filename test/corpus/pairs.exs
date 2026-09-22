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
    finding: {:shutdown_safety, "terminate/2 calls a sibling that may already be down"}
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
    finding: {:shutdown_safety, "children started under another tree outlive their owner"}
  },
  %{
    repo: "sneako/finch",
    issue: "finch#213",
    module: "Finch.HTTP2.Pool",
    pre: "28827940193f0436f55f1688874e7b65f6079b05",
    fix: "ca530c889f7fd1e036ea292d7d0c17adb01d0cd2",
    finding: {:gen_statem, "A {:call, from} clause never replies"}
  },
  %{
    repo: "whatyouhide/redix",
    issue: "redix#317",
    module: "Redix.Cluster",
    pre: "cef6129a0aa2093e24d8b1ab5b6853d0b58a3b41",
    fix: "3f88e8e9a9d0627ca91f77fa2c475b679b0f77b9",
    finding: {:unsafe_task, "Task.yield on a linked task cannot see it crash"}
  },
  %{
    repo: "elixir-ecto/ecto",
    issue: "ecto#2338",
    module: "Ecto.Repo.Preloader",
    pre: "5422d3158194e872092ee00b46bed89db1e356d8",
    fix: "12a745234fa9bda86620708316b7682bd6454222",
    finding: {:unsafe_task, "Task.async in library code links to an unknown caller"}
  },
  %{
    repo: "whatyouhide/redix",
    issue: "redix#334",
    module: "Redix.Cluster.Manager",
    pre: "d3bab6e7be417c0a34f5781844f9d3068b13e489",
    fix: "e67e61a04120cd07507cbf2c372a3f9dc7189bc0",
    finding: {:coupling, "Two restart authorities for the same child"}
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
    finding: {:distributed, ":erpc.call transport failures fall through the rescue"}
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
    finding: {:error_handling, "handle_info/2 has no catch-all"}
  },
  %{
    repo: "commanded/commanded",
    issue: "commanded#332",
    module: "Commanded.ProcessManagers.ProcessManagerInstance",
    pre: "9f45a30",
    finding: {:error_handling, "handle_info/2 has no catch-all"}
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
    finding: {:supervision, "Permanent child stops itself and is restarted"}
  },
  %{
    repo: "elixir-ecto/postgrex",
    issue: "postgrex#781",
    module: "Postgrex.Parameters",
    pre: "313d6c90dea21f320035501e5d7d6a1e34a74cd4",
    fix: "85c7cf430d0c4519cc7cadf6599bcb173276de0f",
    finding: {:monitor_leak, "Postgrex.Parameters monitors but never demonitors"}
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
    finding: {:shutdown_safety, "terminate/2 calls a sibling that may already be down"}
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
    finding: {:distributed, ":erpc.call in a boolean context with no rescue"}
  },
  %{
    repo: "phoenixframework/phoenix_live_dashboard",
    issue: "phoenix_live_dashboard#218",
    # The rpc and its shape match live in the SystemInfo wrapper.
    module: "Phoenix.LiveDashboard.SystemInfo",
    pre: "e562c63922ea3518d7963bef3e84b433dae5cd80",
    finding: {:distributed, "RPC result matched without a {:badrpc, _} clause"}
  },
  %{
    repo: "beam-bots/bb",
    issue: "bb#214",
    module: "BB.Loop",
    pre: "6c5dc2b5a22f8cf532a696f46d40e2ee79e3a53a",
    fix: "4bd552ca6a816614f6059c9d2e98fc583a27de16",
    finding: {:error_handling, "Timer cancelled without flushing its message"}
  },
  %{
    repo: "cabol/nebulex",
    issue: "nebulex:generation-heartbeat-no-flush",
    module: "Nebulex.Adapters.Local.Generation",
    pre: "faff154",
    finding: {:error_handling, "Timer cancelled without flushing its message"}
  },
  # tortoise#46 (70044be -> b891da1) is the connect-in-init pair, but its
  # 2018 tree no longer compiles on Elixir >= 1.15 (a recursive variable
  # in a pattern); the rule is pinned by fixtures until a buildable pair
  # turns up.
  %{
    repo: "elixir-horde/horde",
    issue: "horde#193",
    # Anchored at the sibling's stop API the impl calls.
    module: "Horde.ProcessesSupervisor",
    pre: "74820c2",
    finding: {:shutdown_safety, "A callback stops a sibling the supervisor owns"}
  }
]
