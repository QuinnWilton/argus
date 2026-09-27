pub type Pid

@external(erlang, "erlang", "spawn")
fn spawn(f: fn() -> a) -> Pid

@external(erlang, "erlang", "send")
fn send(pid: Pid, message: m) -> m

/// Starts a process nothing links to or monitors.
pub fn start() -> Pid {
  let pid = spawn(fn() { loop() })
  send(pid, Nil)
  pid
}

fn loop() -> Nil {
  loop()
}
