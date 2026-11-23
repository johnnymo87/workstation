# Phase 2: Grafana on cloudbox (workstation-4si2.3)

Parent design: `docs/plans/2026-11-23-llm-spend-metrics-design.md`
("Architecture", "Implementation constraints", phase 2). Dashboards are phase 3
(`workstation-4si2.4`); this phase ships an empty, reachable Grafana with one
working datasource.

## Goal

Grafana OSS 12.3.6 on cloudbox, listening on `127.0.0.1:3000` only, with the
`frser-sqlite-datasource` 3.8.2 plugin and a provisioned **read-only**
datasource for `/var/lib/llm-ledger/ledger.db`. The Mac reaches it at
`http://127.0.0.1:3001`.

## Facts this plan rests on (checked 2026-11-23)

- **The nixpkgs grafana unit already has `PrivateTmp = true`**, and
  `ProtectSystem = "full"` (not `strict`). The frser plugin uses
  `modernc.org/sqlite` (pure Go), which spills sorts to `/tmp` like C SQLite.
  So the "disk I/O error on first GROUP BY" found in phase 1 does not apply
  here; the post-deploy smoke test runs a GROUP BY through Grafana to prove it.
- **`http_addr` defaults to `127.0.0.1` in the NixOS module** (it deviates from
  upstream's all-interfaces default). We still set it explicitly and guard it,
  because a default can change under a nixpkgs bump, and cloudbox has a public
  IP and no NixOS firewall.
- **frser opens `pathPrefix + path + "?" + pathOptions`** (`query.go:246`).
  With `pathPrefix = "file:"` and `pathOptions = "mode=ro"` that is an SQLite
  URI opened read-only. `attachLimit = 0` disables `ATTACH`, which would
  otherwise let any query read any SQLite file the grafana user can open.
- The plugin honours `[plugin.frser-sqlite-datasource] block_list`
  (exported as `GF_PLUGIN_BLOCK_LIST`); we block `grafana.db` so even an admin
  cannot point a datasource at Grafana's own DB.
- **`admin_password` and `secret_key` defaults are public** (`admin`, and a
  fixed string in the module). Both come from sops via `$__file{}`. The secrets
  are owned by `grafana`, mode 0400. That keeps them out of casual reads and out
  of shell-env injection, but it is **not** a boundary against agents: dev has
  passwordless sudo. Jonathan reads the admin password with
  `sudo cat /run/secrets/grafana_admin_password`. `admin_password` only takes
  effect when grafana.db is first created, so neither secret has
  `restartUnits`; rotation is in `hosts/cloudbox/grafana.nix`'s header.

**As built, after the pre-PR review** (supersedes the sketch below where they
differ): `pathOptions = "mode=ro&_pragma=busy_timeout(5000)"` (frser and its
driver set no busy timeout, so panels hit SQLITE_BUSY in the writer's commit
window); `snapshots.external_enabled = false`; the guard also pins
`unified_alerting.ha_peers` empty (setting it opens `0.0.0.0:9094`); both Mac
agents share one locked master-creation script (`cloudboxChartForward`), since
a racing loser leaks a daemonized ssh and gcloud.
- **Mac tunnel.** The precedent is `cloudbox-chart-tunnel`
  (`users/dev/home.darwin.nix`): a socket-activated launchd agent that owns a
  loopback port and runs `ssh -W` per connection over a ControlMaster it
  creates itself. The grafana agent reuses the existing `cloudbox-chart` ssh
  host block and its master (`-W 127.0.0.1:3000 cloudbox-chart`), so **no
  `update-ssh-config.sh` change and no re-run on the Mac is needed**. `-W`
  ignores the block's `LocalForward 4710`. Port 3001 on the Mac avoids a local
  Grafana or dev server on 3000.

## Tasks

### T1. sops secrets (done by the lead)

`grafana_admin_password` and `grafana_secret_key` added to
`secrets/cloudbox.yaml` with `sops set --value-stdin` (48 hex chars each, never
printed). Recipients unchanged.

### T2. Guard check first, then `hosts/cloudbox/grafana.nix`

Write the check in `flake.nix` (`checks.${devboxSystem}.cloudbox-grafana-exposure`)
before the module, confirm it fails (grafana not enabled), then add the module.

The check, eval part (pattern: `cloudbox-pigeon-slack-wiring`):

- grafana enabled; `settings.server.http_addr == "127.0.0.1"`;
  `http_port == 3000`; `protocol == "http"`; `openFirewall == false`;
- `analytics.reporting_enabled`, `check_for_updates`,
  `check_for_plugin_updates`, `feedback_links_enabled` all false;
  `news.news_feed_enabled == false`;
- `security.admin_password` and `security.secret_key` are exactly
  `$__file{<sops path>}` of `grafana_admin_password` / `grafana_secret_key`;
  both secrets owned by `grafana`, mode `0400`;
- `users.users.grafana.extraGroups` contains `llm-ledger`;
- `declarativePlugins` contains the frser plugin;
- exactly one provisioned datasource of type `frser-sqlite-datasource`, with
  `jsonData.path == "/var/lib/llm-ledger/ledger.db"`, `pathPrefix == "file:"`,
  `pathOptions` containing `mode=ro`, `attachLimit == 0`, `editable == false`;
- no `GF_SERVER_*` variable in `systemd.services.grafana.environment` or its
  `serviceConfig.Environment`/`EnvironmentFile` (an env var would override the
  ini).

Build part: extract the rendered ini path from `systemd.services.grafana.script`
(`-config /nix/store/...`) and grep it for `http_addr=127.0.0.1` /
`reporting_enabled=false` etc., so the check covers the file Grafana actually
reads, not only the option values.

The module (`hosts/cloudbox/grafana.nix`, imported next to `./llm-ledger.nix`):

```nix
services.grafana = {
  enable = true;
  declarativePlugins = [ pkgs.grafanaPlugins.frser-sqlite-datasource ];
  settings = {
    server = { http_addr = "127.0.0.1"; http_port = 3000; protocol = "http";
               domain = "127.0.0.1"; root_url = "http://127.0.0.1:3001/"; };
    analytics = { reporting_enabled = false; check_for_updates = false;
                  check_for_plugin_updates = false; feedback_links_enabled = false; };
    news.news_feed_enabled = false;
    security = { admin_password = "$__file{...}"; secret_key = "$__file{...}";
                 disable_gravatar = true; };
    users.allow_sign_up = false;
    "plugin.frser-sqlite-datasource".block_list = "grafana.db";
  };
  provision = { enable = true; datasources.settings = { apiVersion = 1; datasources = [ {
    name = "llm-ledger"; uid = "llm-ledger"; type = "frser-sqlite-datasource";
    access = "proxy"; isDefault = true; editable = false;
    jsonData = { path = "/var/lib/llm-ledger/ledger.db"; pathPrefix = "file:";
                 pathOptions = "mode=ro"; attachLimit = 0; };
  } ]; }; };
};
users.users.grafana.extraGroups = [ "llm-ledger" ];
sops.secrets.grafana_admin_password = { owner = "grafana"; group = "grafana"; mode = "0400"; restartUnits = [ "grafana.service" ]; };
sops.secrets.grafana_secret_key     = { same };
```

`root_url` is the Mac-side URL, so links Grafana generates (and that
quota-watch alerts will carry in phase 3) open through the tunnel.

### T3. Mac tunnel agent

`launchd.agents.cloudbox-grafana-tunnel` in `users/dev/home.darwin.nix`, a copy
of `cloudbox-chart-tunnel` with `-W 127.0.0.1:3000`, `SockNodeName =
"127.0.0.1"`, `SockServiceName = "3001"`, its own `StandardErrorPath`. Comment
why it reuses `cloudbox-chart`'s host block and master.

Eval check `darwin-grafana-tunnel` (pattern: `darwin-goose-wiring`, eval-only
on the Linux leg): agent enabled, listener on `127.0.0.1:3001`, IPv4 stream,
`inetdCompatibility.Wait == false`, `StandardErrorPath` set, script contains
`-W 127.0.0.1:3000 "$host"` with `host=cloudbox-chart`.

### T4. Docs

- `hosts/cloudbox/llm-ledger.nix`: replace the "Grafana joins this group in
  phase 2" comment with a pointer to `grafana.nix`.
- Design doc phase 2 line: mark as built, with the path and port facts above.

## Verification after deploy

1. `systemctl status grafana`; `ss -tlnp | grep :3000` shows `127.0.0.1:3000`
   only.
2. `curl -s 127.0.0.1:3000/api/health` returns ok.
3. With the admin password (read via sudo, never echoed), query
   `/api/datasources/uid/llm-ledger/health` and
   `/api/ds/query` with
   `SELECT backend, count(*) n, sum(cost_usd) c FROM requests WHERE ts >= $__from AND ts < $__to GROUP BY backend`
   over the last 7 days; non-empty frames prove group read access, the
   read-only URI and the temp-dir behaviour.
4. A write through the datasource (`CREATE TABLE x(a)`) fails with a read-only
   error.
5. Mac: after Jonathan's next `home-switch`, `http://127.0.0.1:3001` loads the
   login page. (Not verifiable from cloudbox.)
