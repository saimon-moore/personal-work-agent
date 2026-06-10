# Personal Work Agent

Standalone helper scripts for a local-only Hermes install on Linux and macOS.

## Goals

- Install Hermes under `$HOME/.hermes`
- Keep Hermes local-only by default
- Prefer Docker-backed command execution
- Prefer `mise` global Node LTS when `mise` is installed
- Still work when `mise` is not installed

## Scripts

- `./install.sh`
- `./doctor.sh`
- `./uninstall.sh`
- `./skills-manifest.json`
- `./chief-of-staff-skills-manifest.json`

## Defaults

- Hermes home: `$HOME/.hermes`
- Wrapper: `$HOME/.local/bin/hermes`
- Sandbox image: `local-hermes-sandbox:node-lts`
- Node strategy: `auto`

## Node strategy

`auto` uses this precedence:

1. `mise exec -C "$HOME" node@lts -- ...` when `mise` exists
2. Hermes-managed Node at `$HERMES_HOME/node/bin/node` when present
3. ambient system environment otherwise

You can override with:

- `--node-strategy auto`
- `--node-strategy mise`
- `--node-strategy ambient`

## Install

```bash
./install.sh
```

The local installer keeps Hermes bundled built-in skills and then applies the curated custom skills listed in [`skills-manifest.json`](skills-manifest.json).

Hosted one-line install commands:

```bash
curl -fsSL https://raw.githubusercontent.com/saimon-moore/personal-work-agent/main/install.sh | bash -s -- --skills-manifest https://raw.githubusercontent.com/saimon-moore/personal-work-agent/main/skills-manifest.json
```

```bash
curl -fsSL https://raw.githubusercontent.com/saimon-moore/personal-work-agent/main/install.sh | bash -s -- --skills-manifest https://raw.githubusercontent.com/saimon-moore/personal-work-agent/main/skills-manifest.json --with-chief-of-staff
```

Advanced options:

- `--skip-custom-skills`
- `--skills-manifest PATH_OR_URL`
- `--with-chief-of-staff`
- `--chief-of-staff-home PATH`

## AI Chief Of Staff

If you want Hermes set up for the [AI Chief of Staff starter](https://github.com/casim/ai-chief-of-staff-starter), use:

```bash
./install.sh --with-chief-of-staff
```

This does two things:

- installs the starter's Hermes-compatible skills from [`chief-of-staff-skills-manifest.json`](chief-of-staff-skills-manifest.json)
- bootstraps the starter vault into `$HOME/chief-of-staff` by default

You can change the vault location with:

```bash
./install.sh --with-chief-of-staff --chief-of-staff-home /path/to/chief-of-staff
```

Notes:

- the starter vault is separate from `~/.hermes`; it is intended to be your working directory for daily notes, meetings, concepts, and goals
- if the target vault directory already exists and is non-empty, the installer leaves it in place
- the starter skills are installed globally into Hermes under the `chief-of-staff` category

Recommended manual follow-up:

```bash
hermes setup
```

## Verify

```bash
./doctor.sh
./doctor.sh --json
```

## Uninstall

```bash
./uninstall.sh
```

## Security posture

- Gateway is not installed or started by these scripts
- Hermes terminal backend is configured to `docker`
- Docker sandbox defaults to `--network=none`
- Launch cwd is not mounted into the container by default

## Caveats

- These scripts intentionally use Hermes's official installer for v1.
- The Hermes installer may still install optional host packages such as `ffmpeg`, `ripgrep`, or build dependencies via `apt` or `brew`.
- `--skip-browser` is used by default because the target environment is often headless.
- URL-installed skills whose upstream `SKILL.md` lacks a valid `name:` field need a manifest `name` override for unattended install.

## Custom Skills Manifest

[`skills-manifest.json`](skills-manifest.json) is the repo-managed source of truth for curated custom skills.

To update the bundle, edit the `skills` array and add or change entries like this:

```json
{
  "identifier": "owner/repo/path/to/skill-dir",
  "name": "new-skill",
  "category": "research/tools",
  "enabled": true
}
```

Or, if you prefer to keep a GitHub folder URL in the manifest, this is also accepted:

```json
{
  "url": "https://github.com/owner/repo/tree/main/path/to/skill-dir",
  "name": "new-skill",
  "category": "research/tools",
  "enabled": true
}
```

Example:

```json
{
  "skills": [
    {
      "identifier": "owner/repo/path/to/skill-dir",
      "name": "repo-skill",
      "category": "collaboration/tools"
    },
    {
      "url": "https://github.com/owner/repo/tree/main/path/to/other-skill",
      "name": "github-folder-skill",
      "category": "collaboration/tools",
      "enabled": true
    },
    {
      "url": "https://example.com/skills/new-skill/SKILL.md",
      "name": "new-skill",
      "category": "research/tools",
      "enabled": true
    }
  ]
}
```

Behavior:

- provide either `identifier` or `url`
- `identifier` should be a Hermes GitHub skill identifier like `owner/repo/path/to/skill-dir`
- GitHub folder URLs like `https://github.com/owner/repo/tree/main/path/to/skill-dir` are also accepted and translated to a Hermes identifier automatically
- direct `url` installs still work for raw `SKILL.md` files
- `name` is optional, but required for unattended installs when the remote skill has no valid `name:` frontmatter
- `category` is optional
- `enabled: false` skips an entry
- manifest entry failures are best-effort and do not fail the overall Hermes install

## Chief Of Staff Skills Manifest

[`chief-of-staff-skills-manifest.json`](chief-of-staff-skills-manifest.json) is the curated list of starter skills installed by `--with-chief-of-staff`.

It currently bundles:

- `plan-my-day`
- `weekly-review`
- `review-against-concept`
- `sync`
