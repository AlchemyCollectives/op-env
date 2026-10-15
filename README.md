# op-env

Write `.env` files from 1Password at deploy time, driven by a small committed
map. One tool for every repo: docker compose stacks, GitHub Actions jobs and
local runs all use the same map and the same code path.

Each entry in the map names one source for one `.env` file:

- **`environment`**: a [1Password Environment](https://www.1password.dev/environments)
  ID, or a list of IDs merged in order (the last one wins when two define the
  same variable). Loaded with the stable `op run --environment` (1Password CLI
  2.41.0 or later), so no beta CLI is needed.
- **`template`**: a committed file of `KEY={{ op://vault/item/field }}` lines,
  resolved with `op inject`. Use this for repos that already keep secrets as
  vault items.

Secret values are never printed. Every file is written with mode 600 to a
temporary file and moved into place, and any failure exits non-zero, so a
deploy never starts with a missing or partial `.env`.

## The map

`environments.json` at the root of the consuming repo:

```json
{
  "environments": {
    "production": {
      "_shared":  { "environment": "<environment id>" },
      "traefik":  { "environment": "<environment id>" },
      "metabase": { "template": "metabase/.env.tpl" }
    },
    "development": {
      "_shared":  { "environment": "<environment id>" },
      "traefik":  { "environment": "<environment id>" }
    }
  }
}
```

- `_shared` writes `./.env`. Any other stack writes `./<stack>/.env`.
- `"environment": ["<shared id>", "<stack id>"]` writes one `.env` holding both,
  so compose can interpolate shared values such as `${DOMAIN}` from the stack's
  own `.env`. The stack's Environment wins on a clash.
- Add `"output": "path/to/file.env"` to an entry to write somewhere else.
- Environment IDs are not secrets: they are useless without a token that has
  been granted access to that Environment.

## Commands

```bash
op-env pull production              # write every production .env
op-env pull production traefik      # just one stack
op-env list production              # stack, source kind, output path (no secrets)
op-env check                        # validate the map and templates, offline
op-env clean production             # delete the files pull writes
op-env export-bws ./bws-export      # one-off: Bitwarden Secrets Manager -> .env files
```

Options: `-m <map>` (default `environments.json`), `-C <dir>` (run as if in
`<dir>`).

Authentication is whatever the 1Password CLI already uses: a service account
(`OP_SERVICE_ACCOUNT_TOKEN`) in CI and on servers, or an interactive
`op signin` locally.

## Setting up 1Password Environments

1. In the 1Password desktop app, open **Developer > Environments** and select
   **New environment**. One Environment per stack per deployment environment
   works well, for example `docker-compose / traefik / production`, plus a
   `_shared` one per deployment environment.
2. Open it and select **Import .env file**, or add variables one by one.
3. **Manage environment > Copy environment ID**, and put the ID in the map.
4. Create a service account per deployment environment (production,
   development) and grant it read access to only that environment's
   Environments. A development token then cannot read production secrets.
5. Store each token where its deploys run, for example as the
   `OP_SERVICE_ACCOUNT_TOKEN` secret of the matching GitHub environment.

## GitHub Actions

```yaml
jobs:
  deploy:
    environment: production
    runs-on: ubuntu-latest
    env:
      OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
    steps:
      - uses: actions/checkout@v4
      - uses: AlchemyCollectives/op-env@v1
        with:
          environment: production
          stacks: traefik metabase     # optional; default is every stack
      - run: docker compose -f traefik/docker-compose.yml up -d
      - if: always()
        uses: AlchemyCollectives/op-env@v1
        with:
          command: clean
          environment: production
```

Inputs: `command` (`pull`, `clean`, `check`), `environment`, `stacks`, `map`,
`working-directory`, `op-version` (default `2.41.0`) and `install-cli`
(default `true`; set `false` when the runner already has the CLI). Pin to a
release tag or commit SHA.

A `check` step needs no token and no CLI, so it suits a pull-request lint job:

```yaml
      - uses: AlchemyCollectives/op-env@v1
        with:
          command: check
```

## Using the script outside Actions

Copy `bin/op-env` from a tagged release into the consuming repo (for example
`scripts/op-env`) and call it from your deploy script. It needs bash 4 or
later, GNU `env` (for `env -0`; Linux and Git Bash have it, stock macOS does
not), `jq` and the 1Password CLI.

## How Environment values are written

`op run --environment` loads variables into a process. op-env runs it twice in
an otherwise empty environment, once without the Environment and once with it,
and keeps only the pairs the Environment added or changed. Nothing from the
caller's shell can leak into the file.

No secret is ever passed as a command-line argument, where any user on the
host could read it with `ps`: the token reaches `op` through its environment,
and the comparison happens inside bash. A test proves this by logging the
arguments of every external command during a pull.

Values are written for docker compose's `env_file`:

| Value | Written as |
|---|---|
| Letters, digits and `_ . / : @ % + , = -` only | `KEY=value` |
| Anything else without a single quote (spaces, `$`, `#`, `"`) | `KEY='value'`, which compose takes literally |
| Contains a newline, or a single quote that needs quoting | refused, naming only the key |

Only `PATH`, `HOME`, every `OP_*` variable, `XDG_CONFIG_HOME`,
`XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS` and the names in
`OP_ENV_PASSTHROUGH` are passed to `op`.

## Migrating from Bitwarden Secrets Manager

With `BWS_ACCESS_TOKEN` and `BWS_PROJECT_ID` set (and `BWS_API_URL` /
`BWS_IDENTITY_URL` for the EU region):

```bash
op-env export-bws ./bws-export
```

Each secret is written unchanged to `./bws-export/<key>.env` (directory mode
700, files 600). Import each file into its Environment, then delete the
directory.

## Development

```bash
shellcheck -x bin/op-env tests/run.sh tests/stub/op
bash tests/run.sh
```

The tests run against a stub `op` (`tests/stub/op`), so they need no network
and no 1Password account.

## Licence

MIT
