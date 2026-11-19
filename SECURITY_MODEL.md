# Security model

This file is the shared threat model for all of Noam Small's projects (3am-cloud, barista, gemach-finder, macagent, next-gen-finance, substack-notes, sunset-bay, t3code). Devin security scans read it to prioritize findings. Keep it up to date when trust boundaries, entry points or accepted risks change.

Shared threat model for eight unrelated repositories owned by noamsmall18, each scanned separately. No repository has a SECURITY_MODEL.md; everything below is drafted from the code unless marked **(user)**. No dedicated infrastructure repository; deployment config lives inside the repos (GitHub Actions workflows, `wrangler.toml`, `netlify.toml`, Vercel, `t3code/infra`).

## Components

| Component | Repo / code | Trust boundary |
|---|---|---|
| 3AM Cloud Runner | `3am-cloud`: `runner.mjs`, `agents.mjs`, `.github/workflows/reply.yml`, `memory/`, `.claude/skills/` | GitHub Actions job driven by Telegram messages via the `threeam-telegram` Worker bridge (`WORKER_URL`, `BRIDGE_KEY`); holds `CLAUDE_CODE_OAUTH_TOKEN`, `CODEX_AUTH_JSON`, `GH_REPOS_TOKEN` (push access to all repos) |
| Substack Notes Autopilot | `substack-notes`: `src/`, `bin/`, `.github/workflows/`, `relay/worker.js`, `mac/` | Cloud `write` job (LLM agents reading untrusted feeds; holds `CLAUDE_CODE_OAUTH_TOKEN` and Codex auth JSON on disk, but no Substack/Telegram/git creds) → `publish` job (Substack/Telegram/git creds); Cloudflare Worker relay gated by `x-relay-key`; Mac LaunchAgent posting via Chrome extension |
| T3 Code Server | `t3code`: `apps/server`, `packages/*` (providers, source-control, ssh, tailscale, secret-provider-*) | Node WebSocket/HTTP server that spawns coding-agent CLIs with user credentials; pairing-token auth; reachable on LAN/Tailscale/tunnel |
| T3 Code Clients | `t3code`: `apps/web`, `apps/desktop` (Electron), `apps/mobile` | Browser/Electron/RN clients; app.t3.codes connects to user-hosted servers |
| T3 Connect Relay | `t3code`: `infra/relay`, `infra/task-cache` | Hosted tunnel/relay between clients and servers |
| macagent | `macagent`: `src/macagent` (loop, safety, shell_risk, approvals, mcp_server), `Sources/` (macctl Swift), `chrome/` extension | Local agent with screen/keyboard/shell control; Chrome extension with `<all_urls>` host permissions + nativeMessaging; reads untrusted screen/web content (prompt injection) |
| Barista / Marketbar | `barista`: `Barista/` (AppKit), `Barista/Web/`, `PortfolioWebServer.swift`, `ScriptRunner.swift` | Local macOS menu-bar app; fetches market data (Yahoo, CoinGecko, Kraken); local portfolio web server; script runner |
| Next Gen Finance Site | `next-gen-finance`: `app/`, `app/api/*`, `lib/`, `sanity/`, `app/studio` | Public Next.js site on Vercel; Sanity CMS + embedded Studio; Resend newsletter; public stats/subscribe/source-icon APIs |
| Gemach Finder | `gemach-finder`: `src/app`, `src/app/admin`, `src/lib` | Public Next.js site on Supabase (anon key client-side, service role server-side); password-gated admin (`ADMIN_PASSWORD`, `gemach_admin` cookie); public suggestion/request/report forms |
| Sunset Bay | `sunset-bay`: `src/`, `build.js`, `index.html` | Static browser game, no backend |

## Entry points and who can reach them

- **Anyone on the internet:** next-gen-finance public pages and `app/api/{track,article-stats,subscribe,unsubscribe,source-icon,market-data,revalidate,send-edition}`; gemach-finder pages, server actions (`g/[slug]/actions.ts`, `requests/actions.ts`, suggestions), `/admin` login; substack relay Worker URL (key-gated); 3AM Telegram Worker (outside these repos); T3 Connect relay.
- **Authenticated admin/editor:** Sanity Studio (`/studio`, Sanity auth), gemach-finder admin (shared password).
- **Noam only (inferred):** Telegram → 3AM runner, Substack Notes workflows, T3 Code server (pairing), macagent, Barista.
- **Untrusted content that agents read:** web pages, Substack feeds/notes, Telegram messages, repository content, screen contents — all treated as data per the repos' AGENTS.md.

## Assets

- Credentials: Claude OAuth token, Codex auth JSON, `GH_REPOS_TOKEN`, `BRIDGE_KEY`, `SUBSTACK_SID`, `SUBSTACK_RELAY_KEY`, Telegram bot token, `SUPABASE_SERVICE_ROLE_KEY`, `SANITY_API_TOKEN`, `SANITY_WEBHOOK_SECRET`, `RESEND_API_KEY`, `ADMIN_PASSWORD`, provider keys inside T3 Code.
- Control of Noam's Mac and browser sessions (macagent, Chrome extension, T3 Code server shell access).
- Integrity of public content (next-gen-finance.org, Gemach Finder listings) and of Noam's Substack account.
- Personal data: newsletter subscriber emails (Resend), Gemach Finder submissions, portfolio data (Barista), Noam's money details (must never be published per substack-notes rules).

## Attacker profiles

- Anonymous internet user hitting the public sites and APIs (abuse, injection, SSRF, auth bypass, data exposure, spam/email abuse).
- Prompt-injection author: content in web pages, feeds, emails, screen, or repos steering an agent (3AM, Substack agents, macagent, T3 Code agents) into exfiltrating secrets or taking actions.
- Malicious website visited in Chrome/Electron/WebView (extension message abuse, localhost server CSRF/DNS-rebinding against T3 Code server or Barista web server).
- Network-adjacent attacker on LAN/Tailscale reaching T3 Code server.
- Supply chain: GitHub Actions/npm dependencies in workflows.

## Existing controls (from code)

- substack-notes: agent `write` job has no Substack, Telegram or git credentials (it does hold the Claude and Codex model credentials); relay allowlists five Substack endpoints and constant-time key check.
- next-gen-finance: rate limiting, published-post-only stats, Sanity webhook signature (only when `SANITY_WEBHOOK_SECRET` set), signed unsubscribe tokens, send-edition nonce in a private Sanity doc, SSRF host filter on source-icon.
- gemach-finder: constant-time admin password compare, random session tokens, service key server-side only.
- t3code: pairing tokens with scopes; server unauthenticated until paired.
- macagent: safety, shell_risk, approvals, injection modules.

## User-provided facts

- **(user)** Next Gen Finance is the app with public sign-up (newsletter/readers). The other apps have no public sign-up; Noam is the only one who signs in to Gemach Finder admin, T3 Code, macagent, 3AM, Barista and Substack Notes. Unauthenticated internet attackers still matter everywhere (every attacker matters).
- **(user)** Most important assets: secrets and tokens (Claude, GitHub, Substack, Supabase, Telegram); control of Noam's Mac (macagent, 3AM, Chrome extension); integrity of the public sites (next-gen-finance.org, Gemach Finder); subscriber emails and Gemach Finder user data.
- **(user)** Portfolio data in Barista/Marketbar was not named among the most important assets.
- **(user)** Scan all of t3code.

## Out of scope / accepted risk

- **(user)** Nothing: every attacker matters, including Sunset Bay and attackers with local access to the Mac.

## Open questions

- Upstream T3 Code code vs Noam's 3AM changes: should upstream-only findings be reported upstream?
