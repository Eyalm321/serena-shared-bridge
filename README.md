# serena-shared-bridge

**One [serena](https://github.com/oraios/serena) language server per *project*, shared across all your agents — instead of one per *agent*.**

A tiny, drop-in wrapper for [Claude Code](https://claude.com/claude-code) (and any MCP client that spawns serena over stdio). When you run many parallel agents — fan-out, worker pools, multiple panes — each one normally spawns its **own** serena process and its **own** language server (rust-analyzer, pyright, …), often **several GB each**. On the same repo that's pure duplication, and on a busy box it ends in a global OOM.

This routes every agent through one shared serena per project, and reaps idle/orphaned ones. Linux + systemd, ~2 bash scripts, no daemon to babysit.

## The problem it solves

serena's stdio transport is 1:1 — one server per client by design. With N parallel agents you get N serena processes and N language servers. This shows up across the serena tracker:

- **[#1235](https://github.com/oraios/serena/issues/1235)** — duplicate instances when the same project is open in multiple clients.
- **[#1367](https://github.com/oraios/serena/issues/1367)** / **[#1549](https://github.com/oraios/serena/issues/1549)** — orphaned serena processes persisting and growing to extreme RSS, crashing machines.
- **[#979](https://github.com/oraios/serena/issues/979)** — launching from `~/` makes `--project-from-cwd` activate your **entire home directory**, triggering a recursive scan that blows the 30s MCP timeout.
- **[#1496](https://github.com/oraios/serena/issues/1496)** — worktree teammates silently edit the **primary** checkout because serena stays rooted to it.
- Cross-client: [openai/codex#12333](https://github.com/openai/codex/issues/12333) hits the same duplication.

serena already supports `--transport sse` (one server, many clients, one shared LSP). The missing piece is the *glue*: auto-routing each agent to the right per-project server and managing lifecycle. The maintainers consider that glue [out of scope for serena itself](https://github.com/oraios/serena/issues/1278) ("a template layer … outside Serena itself") — so this is that layer.

## How it works

`serena-shared-bridge` is registered as the `serena` MCP command. Per agent it:

1. Resolves the project root (`git rev-parse --show-toplevel`, else cwd).
2. Ensures **one** detached serena SSE server for that root — singleton via a lock + a `root→port` registry (`$XDG_RUNTIME_DIR/serena-shared/`).
3. Bridges the agent's stdio MCP ↔ that SSE server with [`mcp-proxy`](https://github.com/sparfenyuk/mcp-proxy).

So agents on the same repo share one server + one LSP. The server is detached, so it outlives individual agents and the next one reuses it.

`serena-shared-reap` (systemd user timer, every 10 min) reaps any server that's been idle (no client connected) for ≥30 min, or that's orphaned (running but not listening). That's the fix for the orphan-RSS issues above.

**It deliberately runs serena-free** (no LSP) for:
- **linked git worktrees** — fan-out/ephemeral workers that edit per a handoff and don't need symbol tools (and sidesteps the #1496 mis-rooting trap), and
- **`$HOME`** — never a project; avoids the #979 home-dir scan.

Override either with `SERENA_SHARED=force`.

## Install

Requires Linux + systemd (user units), `git`, `ss` (iproute2), `flock`, and `uvx` ([uv](https://github.com/astral-sh/uv)).

```sh
git clone https://github.com/Eyalm321/serena-shared-bridge ~/dev/serena-shared-bridge
~/dev/serena-shared-bridge/install.sh
```

The installer copies the scripts to `~/.local/bin`, installs + enables the reaper timer, and registers serena to route through the bridge in Claude Code's **user** scope (backing up your config first). It's idempotent.

## Configuration (env)

| var | default | meaning |
|---|---|---|
| `SERENA_SHARED` | `1` | `1` = shared bridge (skip worktrees/`$HOME`); `force` = always shared, even there; `0` = disable, fall back to per-agent stdio serena |
| `SERENA_REAP_GRACE` | `1800` | seconds a server must be idle before the reaper kills it |

## Caveats

- **Linux + systemd only** for now (uses `/proc`, `ss`, systemd user timers). macOS/launchd port welcome.
- **One shared LSP serializes symbol queries** — correct under heavy concurrency (validated to 32 simultaneous clients, 0 errors), but if many agents query at the exact same moment, latency grows (they queue, never fail). The trade for killing per-agent LSP RAM.
- **Fail-open**: any bridge failure falls back to the original per-agent stdio serena, so an agent never loses serena because of this.
- A worktree/`$HOME` skip makes the client show serena as "failed to connect" — cosmetic; those agents intentionally run serena-free.

## License

MIT — see [LICENSE](LICENSE).
