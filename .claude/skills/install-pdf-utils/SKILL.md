---
name: install-pdf-utils
description: Build and copy "PDF Utils.app" to /Applications, verify it actually launched, and sweep stale build debris. Use when the user asks to install, deploy, or copy PDF Utils to Applications.
---

Install the most recent PDF Utils build into /Applications.

This is the sibling of SyncCloud's `install-sync-cloud`, but almost every mechanism differs and the differences are the point: **PDF Utils is not an Xcode app.** SwiftPM has no `.app` product type, so `scripts/build-app.sh` hand-assembles the bundle into `build/PDF Utils.app` — there is no DerivedData to search, and the bundle embeds two things that keep running after you close the app. Every check below states why it exists.

**macOS has no `timeout(1)`.** `timeout 5 some-cmd` exits **127 (command not found)** for every input, which reads as "everything timed out". Wherever a command must be bounded, background it and poll `kill -0 $!` (steps 3 and 8).

1. Find the newest built bundle. It is `build/PDF Utils.app` in the repo root — **not** `~/Library/Developer/Xcode/DerivedData`, which never contains this app. Worktrees each have their own `build/`, so search them too, and pick by **binary** mtime rather than bundle mtime (`ditto` and `codesign` touch the bundle, so the directory timestamp can be newer than the code inside it):
   ```bash
   ROOT=$(git rev-parse --show-toplevel)
   APP=$( { find "$ROOT/build" -maxdepth 1 -name '*.app' -type d 2>/dev/null
            find "$ROOT/.claude/worktrees" -maxdepth 3 -path '*/build/*.app' -type d 2>/dev/null
          } | while read -r a; do
            printf '%s\t%s\n' "$(stat -f %m "$a/Contents/MacOS/PdfUtils" 2>/dev/null || echo 0)" "$a"
          done | sort -rn | head -1 | cut -f2- )
   echo "$APP"
   ```
   Use `find`, not a glob — the bundle name contains a space (`PDF Utils.app`, from `CFBundleName`, while the target and binary are `PdfUtils`), and under zsh a non-matching glob aborts the whole command rather than falling through. Quote `"$APP"` everywhere downstream for the same reason.
2. Compare the binary's mtime (`stat -f '%Sm' "$APP/Contents/MacOS/PdfUtils"`) with the latest commit (`git log -1 --format='%ci %h %s'`). If the build is older than HEAD, rebuild and re-resolve `$APP`:
   ```bash
   scripts/build-app.sh
   ```
   Do not substitute a bare `swift build`. The script also compiles the asset catalog, assembles the extension and helper, and code-signs inside-out — the nested `.appex` must be signed **with** its sandbox entitlements first, then the app signed **without** `--deep` so it seals the extension without stripping them. A plain `swift build` produces binaries with no bundle at all.
3. Quit what is running — and note that **three** separate processes can be holding the old build, not one:
   ```bash
   pgrep -fl 'PDF Utils.app/Contents/MacOS/PdfUtils'   # the app
   pgrep -fl 'PdfUtilsHelper'                          # menu-bar helper (a login item)
   pgrep -fl 'PdfUtilsFinder'                          # Finder Sync extension
   ```
   **The Finder Sync extension is the one that bites.** It runs inside Finder's plug-in host out of `/Applications/PDF Utils.app/Contents/PlugIns/PdfUtilsFinder.appex`, and it stays running *with the app closed* — verified: with no `PdfUtils` process at all, `PdfUtilsFinder` was live out of the installed bundle. Quitting the app does not touch it, so replacing the bundle underneath leaves the user's Finder menu driven by the previous build. The helper is a separate login item (launchd job `com.pdfutils.PdfUtils.Helper`) with the same problem.

   Bound the AppleEvent rather than letting `osascript` set the pace. A modal sheet makes the app refuse the quit with `User canceled. (-128)`; a wedged app never answers at all and `osascript` hangs until `AppleEvent timed out. (-1712)`. Either way `rm -rf` then succeeds regardless (the running process holds the inode) and `open` merely re-activates the old instance, so the install reports success while the user stays on the previous build:
   ```bash
   osascript -e 'quit app "PDF Utils"' & OSA=$!
   for _ in $(seq 1 15); do kill -0 $OSA 2>/dev/null || break; sleep 1; done
   kill -0 $OSA 2>/dev/null && kill -9 $OSA 2>/dev/null   # AppleEvent hung; stop waiting on it
   sleep 2
   pkill -TERM -f 'PDF Utils.app/Contents/MacOS/PdfUtils' 2>/dev/null
   pkill -TERM -f 'PdfUtilsHelper' 2>/dev/null
   pkill -KILL -f 'PdfUtilsFinder' 2>/dev/null            # Finder respawns it from the NEW bundle
   sleep 2
   pgrep -fl 'PdfUtils' || echo "quit OK — nothing holding the old build"
   ```
   Killing the extension is safe: `pluginkit` respawns it on demand, which is precisely how it picks up the new code.
4. Replace the installed copy. Use `ditto`, never `cp -R` — the signature and its sealed resources must survive the copy intact:
   ```bash
   rm -rf "/Applications/PDF Utils.app" && ditto "$APP" "/Applications/PDF Utils.app"
   ```
5. Confirm the signature survived — **but check the extension and helper, not the app.** `codesign --verify` on the app reports `code has no resources but signature indicates they must be present` on a perfectly healthy install: SwiftPM's `Bundle.module` accessor requires the resource bundle to sit at the `.app` root, which codesign sees as unsealed content. Gating on a clean app verify would fail every good install. What genuinely must hold is the sandbox entitlement on the extension — a FinderSync extension will not load without it:
   ```bash
   codesign --verify --verbose=1 "/Applications/PDF Utils.app/Contents/PlugIns/PdfUtilsFinder.appex"
   codesign -d --entitlements - "/Applications/PDF Utils.app/Contents/PlugIns/PdfUtilsFinder.appex" 2>/dev/null | grep -i sandbox
   codesign --verify --verbose=1 "/Applications/PDF Utils.app/Contents/Library/LoginItems/PdfUtilsHelper.app"
   codesign -dv "/Applications/PDF Utils.app" 2>&1 | grep -iE 'Identifier|Signature'   # identity only
   ```
   Expect `valid on disk` + `satisfies its Designated Requirement` for the appex, `[Key] com.apple.security.app-sandbox` present, and `Signature=adhoc` for the app (that matches its shipped signing).
6. Confirm the Finder extension is still registered and now points at the new bundle:
   ```bash
   pluginkit -mAv | grep -i pdfutils
   ```
   Expect one `com.pdfutils.PdfUtils.FinderSync` entry at `/Applications/PDF Utils.app/…`. The install path does not change, so the registration normally survives; if the entry is gone, re-add it with `pluginkit -a "/Applications/PDF Utils.app/Contents/PlugIns/PdfUtilsFinder.appex"`.
7. If Spotlight shows duplicate "PDF Utils" entries, other worktrees' `build/` staging copies are being indexed. Find them with `mdfind "kMDItemFSName == 'PDF Utils.app'"` and unregister any that are not `/Applications` — see step 14.
8. Launch the freshly installed app and **verify it actually got through launch**. Neither a silent `open` exit nor a `pgrep` hit is proof: an app can come up with a live process, zero windows and nothing logged (that is exactly how SyncCloud's 2026-07-30 wedged launch passed both checks). `pgrep` proves a process exists; it says nothing about whether that process finished launching.

   The signal that separates the two is the app's own log. `ActivityLog` writes `~/pdf-utils.log`, and `applicationDidFinishLaunching` logs `PDF Utils <version> launched` (real line: `[2026-07-24 13:19:29.837] [INFO] PDF Utils 1.0 launched`). So record the log size before `open` and poll for new bytes:
   ```bash
   LOG=~/pdf-utils.log
   BEFORE=$(wc -c < "$LOG" 2>/dev/null || echo 0)
   open "/Applications/PDF Utils.app"
   for _ in $(seq 1 30); do
     AFTER=$(wc -c < "$LOG" 2>/dev/null || echo 0)
     [ "$AFTER" -ne "$BEFORE" ] && break
     sleep 1
   done
   if [ "$AFTER" -ne "$BEFORE" ]; then
     echo "LAUNCH OK — new log output:"; tail -c "+$((BEFORE+1))" "$LOG" | head -20
   else
     echo "LAUNCH FAILED — no log output in 30s; the app did not start. Go to step 9."
   fi
   ```
   Compare with `-ne`, not `-gt`: if the log was rotated or truncated the new file is *smaller*, and `-gt` would read that as "no output" and fail a healthy launch. Note the log is only flushed on the app's own schedule (`flushToDisk` on terminate, plus normal writes) — the launch line itself appears promptly, which is why it is the check.

   **Do not substitute a window count.** `osascript -e 'tell application "System Events" to get count of windows …'` fails on this machine with `-25211 osascript is not allowed assistive access`, so it errors whether the app is healthy or wedged and cannot tell them apart.
9. If step 8 reported LAUNCH FAILED, **diagnose it — do not report success, and do not guess.** The process is alive but stuck, so the question is where. `sample` answers in seconds; the log is empty by definition in this failure, because the app never got far enough to write it.
   ```bash
   PID=$(pgrep -f 'PDF Utils.app/Contents/MacOS/PdfUtils' | head -1)
   sample "$PID" 3 -file /tmp/pdfutils-sample.txt >/dev/null
   sed -n '/com.apple.main-thread/,/^$/p' /tmp/pdfutils-sample.txt | head -40
   ```
   Report the top main-thread frames verbatim. **A `.task` closure carries a `body.getter` symbol name**, so a frame reading `SomeView.body.getter closure #N` does *not* prove I/O in the render pass — it may be an async task that is merely main-actor isolated. If `pgrep` finds no pid at all the app crashed rather than hung; look under `~/Library/Logs/DiagnosticReports/PdfUtils-*.ips`.
10. Confirm the running process is the one just installed, not a survivor of step 3: its start time must be **later** than the installed binary's mtime.
    ```bash
    ps -p $(pgrep -f 'PDF Utils.app/Contents/MacOS/PdfUtils' | head -1) -o lstart=
    stat -f '%Sm' "/Applications/PDF Utils.app/Contents/MacOS/PdfUtils"
    ```
    This passes on a wedged app too — a process that hangs during launch still started after the binary was written — so it confirms *which build* is running, never *that the app works*. Step 8 is what establishes the latter.
11. Report both timestamps **and the new log lines from step 8** as the evidence. If step 9 ran, report the blocking frame instead and say plainly that the install did not come up.

## Cleanup sweep

Run after the install is confirmed, never before — a sweep that runs first can delete the build you were about to install.

**Total, but never blind. Four things look exactly like debris and are not:**

- **`~/actions-runner-pdfutils-x64/_work/…`** — the self-hosted CI runner builds this repo there, with SwiftPM `.build` dirs indistinguishable from a stale worktree's, and it is often *mid-job*. (There are three runner dirs on this machine; `~/actions-runner-synccloud*` belong to the other project.) Never match build dirs by name — exclude every `*/actions-runner-*` path.
- **Anything owned by a live worktree.** Other sessions run concurrently; `git worktree list` is the authority.
- **Unmerged branches.** Use `git branch -d`, **never `-D`**: that refusal is the safety mechanism.
- **Stashes.** They live in the shared repo and survive worktree removal and `git branch -d`, so a stash is often the only copy of an abandoned experiment. Never `git stash clear`.

12. **Stale SwiftPM build trees.** This project's build output is `.build/` per checkout plus the assembled `build/*.app`, and a removed worktree leaves both behind. Delete only those under a worktree path that no longer exists:
    ```bash
    git worktree prune
    for d in "$(git rev-parse --show-toplevel)"/.claude/worktrees/*/; do
      [ -d "$d" ] || continue
      git worktree list --porcelain | grep -qF "worktree ${d%/}" || { echo "orphan tree: $d"; rm -rf "$d"; }
    done
    du -sh "$(git rev-parse --show-toplevel)"/.build 2>/dev/null   # safe to delete; SwiftPM rebuilds
    ```
13. **Leaked test debris.** The test suites use scratch defaults suites and temp logs, which leave `<Suite>-<UUID>.plist` in `~/Library/Preferences` and `pdf-utils-tests-<pid>.log` / `pdfutils-*-<UUID>.log` in the temp dir. Sweep the debris but **do not "fix" the mechanism** — on the sibling project the same leak was measured across five runs and found to oscillate (6 → 0 → 32 → 32 → 16 → 16) and never grow, because cfprefsd rewrites a plist after exit and the next run's own sweep takes it. Measure across 4+ runs before concluding anything is broken. Match on shape, never on `com.*`, and tolerate files vanishing mid-sweep (they do):
    ```bash
    ls ~/Library/Preferences/*.plist | grep -vi '/com\.' | grep -Ei -- '-[0-9A-F]{8}-[0-9A-F]{4}-' | tr '\n' '\0' | xargs -0 rm -f
    find "$TMPDIR" -maxdepth 1 \( -name 'pdf-utils-tests-*.log' -o -name 'pdfutils-*.log' \) -delete 2>/dev/null
    ```
    `find`, not `rm "$TMPDIR"/pdfutils-*.log`: when nothing matches, zsh aborts the command with `no matches found` instead of running it — so on a already-clean machine the glob form fails noisily and, in a longer script, takes the rest of the sweep down with it.
    Do **not** delete `~/pdf-utils.log` — that is the live app's activity log and the launch evidence step 8 depends on.
14. **Stale LaunchServices registrations.** Worktree `build/` copies get indexed and registered, which is what puts duplicate "PDF Utils" entries in Spotlight and Launchpad. Unregister every registered path that no longer exists:
    ```bash
    LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
    mdfind "kMDItemFSName == 'PDF Utils.app'" | while read -r p; do
      [ -e "$p" ] || "$LSREG" -u "$p"
    done
    mdfind "kMDItemFSName == 'PDF Utils.app'"   # expect /Applications + any live worktree build
    ```
    Take care not to unregister the *installed* copy — that is what un-registers the app from Finder's extension list too.
15. **Merged branches and dead worktrees.** A branch is a candidate only if it has **no worktree** and is **merged into `main`**; `git branch -d` enforces the second condition itself.

    **Ask before deleting release-shaped branches.** Unlike the sibling project, whose stale branches are all disposable session branches, this repo's merged-and-worktree-free branches are `v1.0` and `v1.1` — release markers someone may be keeping on purpose. "Merged" makes them safe to delete in the sense that no commit is lost, but it does not make them *unwanted*. Skip anything matching `v*` or `release/*` unless the user says otherwise; a tag would be the durable form if they want them gone. Before removing a worktree, check it for uncommitted work (`git -C <wt> status --short`) and for a process sitting in it (`lsof -a -d cwd +D <wt>`), and `git stash push` anything dirty rather than discarding it.
    ```bash
    WT=$(git worktree list --porcelain | awk '/^branch /{sub("refs/heads/","",$2); print $2}')
    for b in $(git for-each-ref --format='%(refname:short)' refs/heads); do
      echo "$WT" | grep -qx "$b" || git branch -d "$b"     # -d, never -D
    done
    git worktree prune
    git gc                  # NOT --prune=now while other sessions are live
    ```
    `git gc --prune=now` immediately discards unreachable objects, and a concurrent session may hold objects written but not yet referenced (a commit being built, a stash mid-write). Plain `git gc` keeps the two-week grace, which is the margin. Only use `--prune=now` when `git worktree list` shows nothing but the primary.

    macOS notes: `xargs -a` is GNU-only — read a branch list with `git branch -d $(cat file | tr '\n' ' ')`; and `rm -rf` on a path beginning with `-` needs a `./` prefix.
