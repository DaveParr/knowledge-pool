# Backups and restores

How decks come back after a bad deploy, an admin mistake, or the loss of the Railway
project. Decided in #107, built in #138.

**On the Hobby plan there is one layer: a daily dump on the admin's machine**, the last
14 kept, made by `scripts/backup.sh`. It survives the loss of the whole project.
Restore 2 rebuilds from it.

Railway's volume backups (scheduled daily, weekly and monthly, restored in place by
Restore 1) need the Pro plan: on Hobby the Backups tab can only view, restore and
delete backups that already exist (checked 2026-11-19). If the plan moves to Pro, turn
on all three schedules, go back to a weekly dump keeping 8
(`KP_BACKUP_SCHEDULE=weekly KP_BACKUP_KEEP=8 scripts/backup.sh install-timer`), and
run the Restore 1 drill.

Every restore is the whole database, with the app down, decided by the admin alone. A
restore brings back what was deleted since the backup (decks, and the decks of users
removed since), and loses the edits made since. The invite list lives at WorkOS and is
not restored. Removed data lingers in the dumps until they age out: about two weeks
with 14 daily dumps.

## The dump script

`scripts/backup.sh` opens Railway's SSH tunnel to the Postgres service (Postgres has no
public address), runs `pg_dump --format=custom --no-owner` over the whole database to
`~/.local/share/knowledge-pool/backups/knowledge-pool-<UTC time>.dump`, reads the file
back with `pg_restore --list`, and keeps the newest 14. If anything fails it exits
non-zero and raises a desktop notification; the old dumps stay as they were.

It needs `railway` logged in (`railway login`), `python3`, and Postgres client tools of
version 18 or newer: when the local `pg_dump` is older it runs them from the
`postgres:18` Docker image. It reaches the production project by id, so it runs from
any directory.

```sh
scripts/backup.sh               # one dump now
scripts/backup.sh install-timer # install and start the systemd user timer
journalctl --user -u kp-backup  # what the timer's runs printed
systemctl --user list-timers kp-backup.timer
```

`install-timer` writes `kp-backup.service` and `kp-backup.timer` (from
`scripts/systemd/`) into `~/.config/systemd/user/`, with this checkout's path (run it
from the main checkout, not a worktree that will be removed) and the
current `PATH` filled in, and enables the timer (daily by default). `Persistent=true` runs a missed dump
when the machine next starts. Run it again after moving the checkout.

Settings, as environment variables: `KP_BACKUP_DIR` (must be outside the repo; created
mode 700), `KP_BACKUP_KEEP` (default 14), `KP_BACKUP_SCHEDULE` (the timer's `OnCalendar`,
default `daily`), `KP_BACKUP_SERVICE` (see below). `install-timer` copies the
first three into the units.

The script dumps the Postgres service whose private host the app's `JAC_DB_URL`
names, so after Restore 2 moves the app to a new service the dump follows it. Set
`KP_BACKUP_SERVICE` only to check a particular service: if it is not the app's database,
`dump` fails with the notification.

Keep the dumps on the encrypted disk and in the admin's own backup of it, nowhere else:
each one holds every user's decks and the sign-in tables.

## Restore 1: roll back in place

For a bad deploy or an admin mistake, when the Postgres service and its volume still
exist. **Needs Railway's volume backups, so the Pro plan**; on Hobby, use Restore 2 with
the newest dump from before the damage, into a new Postgres service.

1. **Take the app down**, so no write lands mid-restore: app service → Deployments →
   the active deployment → ⋮ → Remove.
2. **Restore the backup**: Postgres service → Backups → the chosen backup → Restore.
   Railway stages the change: review it and Deploy. It mounts a new volume and keeps
   the old one unmounted.
3. **Bring the app back**: app service → Deployments → the latest → ⋮ → Redeploy. Check
   `https://<app>/healthz` answers 200 and open one deck.
4. **Redo** any deck deletions and user removals made since the backup's time.
5. **Tell users** which period of edits was lost.
6. **After a week**, delete the old, unmounted volume.

Before each Postgres upgrade (#109), take a manual backup on the Backups tab (Pro), or
on Hobby run `scripts/backup.sh`.

## Restore 2: rebuild from a dump

For a wiped volume, a deleted Postgres service, or a lost project. Also how the
database moves region.

1. If the project is gone, the app must not reach the new database before the dump is
   in it (it would create its own tables, and `restore` only loads into an empty
   database). So: run `scripts/deploy_wizard.sh`'s Railway stages up to and including
   "Postgres predicate locks", and stop there. Its `Postgres` service is the new, empty
   database, set up as step 3 asks. Set `KP_RAILWAY_PROJECT` and
   `KP_RAILWAY_ENVIRONMENT` to the new ids (or change the defaults in
   `scripts/backup.sh`), do step 4 into `Postgres`, then carry on with the wizard from
   "the app service" through "GitHub: Railway project token" (the app's build now
   succeeds: `main` has the Dockerfile). Leave the wizard there: its later stages are
   for the first deploy. Finish with step 6. Steps 2, 3 and 5 do not apply.
2. **Take the app down** if it is up (as in Restore 1).
3. **Create Postgres 18 with no public address**: Create → Database → PostgreSQL. Name
   it (say `Postgres-EU`; a name of its own leaves any old service alone). Settings →
   Source image: pin the tag to 18. Settings → Networking: remove any TCP proxy.
   Settings → Scale: the region you want (it moves the empty volume). Then set the predicate locks and
   restart, as the deploy wizard does:
   ```sh
   railway ssh --service Postgres-EU
   psql -U postgres -c "ALTER SYSTEM SET max_pred_locks_per_transaction = 1024"
   ```
   Restart the service, and check `SHOW max_pred_locks_per_transaction` answers 1024.
4. **Load the newest good dump** into its empty database:
   ```sh
   scripts/backup.sh restore ~/.local/share/knowledge-pool/backups/<newest>.dump Postgres-EU
   ```
   It asks you to type the service name, refuses a database that already has tables,
   and runs `pg_restore --no-owner --exit-on-error`. It prints how long the restore took.
5. **Point the app at it**: app service → Variables → `JAC_DB_URL` =
   `${{Postgres-EU.DATABASE_URL}}` (it resolves to the new service's private
   `*.railway.internal` address). If the app moves region too, set it under the app's
   Settings → Scale. Then deploy **from source**
   (`railway redeploy --from-source -s knowledge-pool`): a plain redeploy, or one of an
   earlier deployment, reuses that deployment's region.
6. Steps 3 to 5 of Restore 1. Going back is pointing `JAC_DB_URL` at the old service
   again. If an old Postgres service still exists, keep it for a week, then delete it.

## A scratch restore on this machine

The dump drill restores into a throwaway Postgres 18 here and compares row counts with
production:

```sh
COUNTS="select table_name || ' ' || (xpath('/row/c/text()', query_to_xml(format(
  'select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text
  from information_schema.tables where table_schema = 'public' order by 1"

docker run -d --name kp-scratch -e POSTGRES_PASSWORD=scratch postgres:18
docker exec kp-scratch pg_isready -U postgres   # repeat until it answers
docker exec -i kp-scratch pg_restore -U postgres -d postgres --no-owner --exit-on-error \
  < ~/.local/share/knowledge-pool/backups/<newest>.dump
docker exec kp-scratch psql -U postgres -d postgres -Atc "$COUNTS"
railway ssh -p fb141f57-62d6-4897-98d5-bc6e145d915f -e 65957dce-6184-4fb6-948b-085ac9c5d6b1 \
  --service <the app's Postgres> -- psql -U postgres -d railway -Atc "$COUNTS"
docker rm -f kp-scratch
```

The app's Postgres is the service `scripts/backup.sh` names in its `wrote … from`
line (`Postgres-EU` since 2026-11-19). The two lists of exact row counts should match (a write between the dump and the count
can move one by a little).

## Drills

Tried before anyone is invited, and the dump drill again after each Postgres major
upgrade. Note how long each restore took on #138 (or the upgrade's ticket).

- Run `scripts/backup.sh`; do the scratch restore above and compare row counts.
- Restore 2 into a second Postgres service, point the app at it, check a deck. Then
  point `JAC_DB_URL` back at the first service, deploy, and delete the second one (on
  2026-11-19 this drill was the move to EU West, so the new service stayed).
- `scripts/backup.sh install-timer`.
- On Pro only: turn on the three schedules, take a manual backup; make a deck, take a
  manual backup, change the deck, run Restore 1, see the deck as it was.
