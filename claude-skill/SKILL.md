---
name: insomnia
description: Keep a MacBook running with the lid closed (no external display needed) while macOS keeps managing fans and thermal throttling, with a watchdog that puts it to sleep if it overheats, the battery runs low, or a time limit passes; optionally bridges Claude Code Remote Control so sessions can be started from the phone. Use this whenever the user wants the laptop to keep working after closing the lid, says things like "keep my mac awake with the lid shut", "I want to close the laptop and let the agents/build/download keep running", "turn on insomnia", "turn it off, I want normal sleep back", "is insomnia still on", "why won't my mac sleep when I close it", "I want to start Claude sessions from my phone while the laptop is closed", or asks whether running closed is safe for the screen, battery or cooling.
---

# Insomnia

The tool is the `insomnia` command (installed by the repo's `install.sh` into `~/.local/bin`). The menu bar app is `~/Applications/Insomnia.app`.

## Commands

```bash
insomnia status                               # no admin rights needed
insomnia on [--hours N] [--low-power] [--max-temp C] [--min-battery P]
insomnia on --remote <folder> [--remote-spawn worktree]   # plus Claude Code sessions from the phone
insomnia off                                  # normal sleep back; phone access keeps running
insomnia off --all                            # also stop phone access
insomnia remote-on <folder> / insomnia remote-off
insomnia recent-dirs                          # folders of recent Claude Code sessions
insomnia nopasswd-status                      # exit 0 when no-password switching is installed
```

## Running it for the user

1. Run `insomnia status` first and report the state.
2. `on`/`off`/`toggle` need admin rights unless `insomnia nopasswd-status` succeeds. Without it, open the command in the user's own terminal so they can authenticate, or give it to them to run. Never type or pipe their password, and never create sudoers rules yourself.
3. If they want no prompts, suggest `insomnia install-nopasswd` for them to run once. It allows only Insomnia's exact `pmset`/`powermetrics` command lines; never suggest a rule covering the script itself.
4. After any change, run `insomnia status` again and report plainly: running or not, sleep disabled or not, lid, battery %, battery temperature, thermal pressure, phone access.

## Phone access

`--remote <folder>` starts `claude remote-control` (server mode) in that folder. From the Claude mobile app (Code tab) or claude.ai/code the user can continue sessions and create new ones that run on the Mac, up to 32 at once. Phone chats live inside that process: turning Insomnia off leaves it running, and stopping it takes them offline until `insomnia remote-on <same folder>` reconnects them. Needs the `claude` CLI signed in with a claude.ai plan.

## Safety

Watchdog limits: thermal pressure Heavy or worse, battery above 45 °C, under 20% on battery, or the `--hours` limit. On a trip it restores sleep and sleeps the Mac if the lid is closed. A locked screen does not stop work; only sleep does. Keep the Mac on a hard surface or stand, never in a bag or on a bed. For heat questions give the real numbers from `insomnia status`.
