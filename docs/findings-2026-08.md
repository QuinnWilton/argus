# Corpus findings, August 2026

Results from two new analyses — `request_surface` and `callback_receive` —
run over the sample corpus. Every finding below was read against source
before being written down, and the ones that did not survive that reading
are recorded too, because they are what calibrated the analyses.

Severity here is what the evidence supports, not what the analysis emitted.

---

## 1. Livebook — unvalidated `String.to_atom` on websocket payload

**Where** `lib/livebook_web/live/session_live.ex:397, 411, 428`
**Analysis** `request_surface` / `remote_atom_exhaustion`, proximity `direct`
**Severity** Low-to-moderate. Real bug, cheap fix, does not cross a
privilege boundary in the default deployment.

Three `handle_event/3` clauses take `"tag"` straight out of the client
payload and convert it:

```elixir
def handle_event("apply_cell_delta", %{"cell_id" => _, "tag" => tag, ...}, socket) do
  tag = String.to_atom(tag)
```

`tag` is whatever the browser's JavaScript pushed over the websocket. There
is no guard, no changeset, and no `to_existing_atom`. The domain it is
checked against downstream is exactly two values — `source_access/2` in
`lib/livebook/session/data.ex:2192` has clauses for `:primary` and
`:secondary` and nothing else.

The BEAM atom table is fixed-size (default 1,048,576) and never garbage
collected. A client that pushes `report_cell_revision` with a fresh random
`tag` each time permanently consumes one slot per message; when the table
fills, the VM aborts and takes every session on the node with it.

**Why the severity is not higher.** `SessionLive`'s routes sit behind the
`:auth` pipeline, and an authenticated Livebook user can already evaluate
arbitrary code — including `:erlang.halt/0`. So this is not an escalation
in the standard single-user deployment. It matters as defence in depth, and
it matters more wherever session access is broader than code-execution
trust: shared collaborative sessions, or any deployment fronting Livebook
with its own authorization.

**Fix** `String.to_existing_atom/1`, or match `"primary"`/`"secondary"`
explicitly and reject the rest.

---

## 2. Supabase Realtime — unvalidated `String.to_atom` on URL query parameters

**Where** `lib/realtime/api.ex:65,68` reached from
`lib/realtime_web/live/tenants_live/index.ex:53`
**Analysis** `request_surface` / `remote_atom_exhaustion`, proximity `adjacent`
**Severity** Moderate. Post-authentication denial of service.

```elixir
def list_tenants(opts) when is_list(opts) do
  field = Keyword.get(opts, :order_by, "inserted_at") |> String.to_atom()
  order = Keyword.get(opts, :order, "desc") |> String.to_atom()
```

`handle_params/3` feeds it directly from the URL:

```elixir
def handle_params(params, _url, socket) do
  changeset = Filter.changeset(socket.assigns.filter_changeset, params)
  form = Filter.apply_changes_form(changeset)
  ... Api.list_tenants(order_by: form.order_by, order: form.order, ...)
```

and the changeset does not constrain either field:

```elixir
def changeset(form, params \\ %{}) do
  form |> cast(params, [:order_by, :search, :limit, :order])
end
```

`cast/3` coerces types; it does not validate membership. So `order_by` is
an arbitrary attacker-supplied string that becomes a permanent atom. Roughly
a million requests with distinct values aborts the node, and the node is
holding every tenant's websocket connections.

`/admin/tenants` is behind the `:dashboard_admin` pipeline, so this is
post-auth — an admin should nonetheless not be able to kill the node by
editing a URL.

**Fix** `validate_inclusion(:order_by, ~w(inserted_at name ...))` on the
changeset, and `String.to_existing_atom` at the boundary.

---

## 3. TeslaMate — leaked monitor and unhandled `:DOWN` on the reconnect path

**Where** `lib/teslamate/vehicles/vehicle.ex:572-588`
**Analysis** `callback_receive` / `receive_in_callback`, proximity `direct`
**Severity** Moderate-to-high. Crash on an error path, in a supervised
process, exactly when the system is already degraded.

The analysis flagged the selective receive:

```elixir
def handle_event(:info, {:stream, msg}, _state, data)
    when msg in [:too_many_disconnects, :tokens_expired] do
  ref = Process.monitor(data.stream_pid)
  :ok = disconnect_stream(data)

  receive do
    {:DOWN, ^ref, :process, _object, _reason} -> :ok
  after
    1000 -> :continue
  end
  ...
```

That alone is a warning: it runs on the `gen_statem`'s own stack, so the
vehicle state machine handles nothing else for up to a second, and because
the pattern is specific the VM re-scans the mailbox for it.

Reading it surfaced a second, worse bug. On the `after 1000` branch the
monitor is never released — there is no `demonitor` anywhere in the file —
so a `{:DOWN, ref, :process, pid, reason}` arrives later. The module has two
`:DOWN` handlers (lines 615 and 620) and **both match `reason` `:normal`
only**; across 59 `handle_event` clauses there is no catch-all for `:info`.

An abnormal reason is the likely one here, since the process was just
force-disconnected. When it arrives, no clause matches, `gen_statem`
terminates with a bad-event error, and the vehicle process crashes — on the
`:too_many_disconnects` / `:tokens_expired` path, i.e. precisely when the
connection is already misbehaving.

**Fix** `Process.demonitor(ref, [:flush])` after the receive, and a
catch-all `handle_event(:info, {:DOWN, _, _, _, _}, _, _)`.

---

## What did not survive reading

These calibrated the analyses and are the reason the severities above are
worth anything.

| Reported | Verdict |
|---|---|
| sequin — 36 `transitive` atom paths | Not request-tainted. `Sequin.JSON.decode_struct_with_type/1` takes `_kind` from a JSON map, but both callers source it from **storage** (a Postgres JSON column via `Ecto.Type.load/1`, and Redis via `AcknowledgedMessage.decode/1`). A LiveView merely loads those records. |
| teslamate — `Vehicle.busy?/1` (`adjacent`) | `:"#{car_id}"` where `car_id` is a database primary key. Domain is the size of the user's garage. |
| livebook — 2 blocking receives | The documented `cancel_timer` flush idiom. `cancel_timer/1` returning false means the message was already sent, so the receive is guaranteed to match. |
| oban — `binary_to_term` in a worker | `test/support/worker.ex`. Test-only; an artifact of sweeping test-env beams. |
| livebook — `AttachedRuntimeComponent` node/cookie | Node names and cookies genuinely must be atoms for `Node.connect`, and a changeset runs first. Inherent, not a defect. |

The lesson that shaped both analyses: **reachability is not taint**. A path
from a request handler to a sink proves a path exists, not that attacker
data travels it. Every `transitive` finding examined turned out to carry
data from storage or configuration. That is why `request_surface` reports a
proximity and scales severity by it, rather than reporting every path as if
it were the same thing.

## Analysis hygiene notes

- Sweeps pick up `test/support` modules when the project was compiled in
  test env. Worth filtering, or at least labelling.
- Both analyses key findings on the sink site, not the (site, entry) pair.
  A sink reachable from forty controllers is one bug in one place, and
  reporting it forty times buries it.
