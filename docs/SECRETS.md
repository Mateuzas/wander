# Secrets

The repo is public. Anything secret, or anything we'd rather not publish, is
committed only in encrypted form with [SOPS](https://github.com/getsops/sops)
and [age](https://age-encryption.org). Plaintext never gets committed.

## What's in here today

| File | Holds | Used by |
|---|---|---|
| `secrets/signing.enc.yaml` | `DEVELOPMENT_TEAM` (Apple team ID) | `App/Config/Signing.local.xcconfig` via `scripts/secrets.sh xcconfig` |

The MVP has no backend and MapKit needs no API key, so this is the only
secret right now. Likely next: an App Store Connect API key (`.p8`) for
TestFlight uploads from CI.

## Layout

- `.sops.yaml`: encryption rules. Only `secrets/*.enc.{yaml,json,env}`
  are encrypted, to the age **public** keys listed there.
- `secrets/`: encrypted files only. Keys stay readable and values are
  `ENC[...]`, so diffs still show which entry changed.
- `scripts/secrets.sh`: edit, render, rekey.
- `scripts/check-secrets.sh`: fails if anything plaintext would be published.
  The `Secrets` GitHub workflow runs it on every PR, together with gitleaks
  over the full git history.
- `.gitignore`: blocks `.env*`, `*.p8`, `*.p12`, `*.cer`, provisioning
  profiles, age keys, `*.dec.*` and `App/Config/*.local.xcconfig`.

## Setup on a new Mac

```sh
brew install sops age
```

Get the Wander age private key from the owner's password manager and add it
to your key file (sops reads every key in it):

```sh
mkdir -p ~/.config/sops/age
cat wander.key >> ~/.config/sops/age/keys.txt   # then delete wander.key
chmod 600 ~/.config/sops/age/keys.txt
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt   # put in ~/.zshrc
```

Then, before building for a real iPhone:

```sh
scripts/secrets.sh xcconfig   # writes App/Config/Signing.local.xcconfig
```

Simulator builds and CI don't need this: `DEVELOPMENT_TEAM` is just empty.

## Everyday use

```sh
scripts/secrets.sh edit signing          # opens decrypted in $EDITOR, re-encrypts on save
scripts/secrets.sh edit appstoreconnect  # creates secrets/appstoreconnect.enc.yaml
scripts/secrets.sh check                 # same check CI runs
```

Rules:

- Never write decrypted output inside the repo, except the generated,
  gitignored `*.local.xcconfig`. If you need a file, use `*.dec.*` (ignored)
  or a path outside the repo, and delete it afterwards.
- Never paste secrets into PR descriptions, commit messages, issues or CI logs.
- Binary secrets (`.p8`, `.p12`): store them as a base64 string value in a
  YAML file instead of committing the binary.

## Adding a person or CI

1. They run `age-keygen -o wander.key` and send you the **public** key (`age1…`).
2. Append it to the `age:` list in `.sops.yaml` (comma-separated).
3. `scripts/secrets.sh rekey`, then commit.

Removing someone: delete their key, rekey, **and rotate the secrets**. They
may have kept old plaintext, and old ciphertext stays in git history.

### When CI needs to decrypt (e.g. TestFlight)

Create a separate age key for CI, add its public key as above, and store the
private key as the GitHub Actions secret `SOPS_AGE_KEY` (repo Settings →
Secrets and variables → Actions). In the workflow, expose it only to the
step that needs it:

```yaml
- name: Decrypt signing settings
  env:
    SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}
  run: scripts/secrets.sh xcconfig
```

Fork PRs can't read repo secrets, so decrypting jobs should run only on
`push` to `main` (or on tags), not on `pull_request`.

## If a secret leaks

1. Rotate it with the provider first (revoke the key or token). That's
   the real fix.
2. Put the new value in with `scripts/secrets.sh edit …`.
3. Rewriting git history doesn't un-publish anything on a public repo
   (forks, caches), so treat any pushed secret as burned.

Note: the Apple team ID was in `project.pbxproj` before this setup, so it is
still in the public history. That's acceptable: a team ID is an identifier
that's embedded in every signed app, not a credential, so it doesn't need
rotating.
