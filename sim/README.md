# Cairn and Quarry Swarm simulator

A ComputerCraft 1.63 simulator that runs the real, unchanged Cairn and Quarry
Swarm programs in a fake world, in simulated time. A full Cairn quarry trip
(out, RM undock, return) takes about 2 seconds of real time.

It runs ComputerCraft's own `bios.lua`, shell, `rednet`, `parallel`,
`textutils` and `gps` from your ComputerCraft jar. Only the parts that are
Java in the real mod are faked: the filesystem, timers, terminal, redstone,
peripherals, modems and turtle commands. Because of that, the behaviours that
matter here come from the real ROM code:

- An event a program is not waiting for is lost. A turtle waiting for its
  move, or a computer inside `sleep`, misses any rednet message that arrives
  meanwhile.
- A turtle command takes effect one tick after it is issued and answers when
  its animation ends. A reboot before the effect loses the command. A reboot
  after the effect keeps it, but the program never hears back.
- `rednet.send` goes out on every open modem, and the receiver drops the
  duplicate copy.

The world follows Redstone In Motion 2.3.0.0, from its source:

- A drive moves the carriage one block when its redstone input turns on
  (rising edge only), away from the side the signal comes from.
- Platform and support carriages carry every block connected to them, up to
  5000. More than that refuses the move.
- Every computer on the carriage stops when the move starts and boots again
  when it ends, one second later. A blocked move changes nothing and nobody
  reboots.

## Setup

You need `luajit` or `lua5.1`, and your ComputerCraft 1.63 jar for the ROM.

```
bash sim/fetch_rom.sh /path/to/ComputerCraft1.63.jar
```

This extracts the ROM to `sim/ccrom/` (ignored by git, since the ROM belongs
to ComputerCraft).

The programs are read from two folders: the Quarry Swarm from this
repository's root, and Cairn from `cairn/` in this repository once Cairn is
merged in. Until then, clone the Cairn repository and point the simulator at
it with `cairn=` or the `SIM_CAIRN` variable. `swarm=` or `SIM_SWARM` picks a
different Quarry Swarm folder.

## Running one scenario

```
cd sim
luajit run.lua cairn=/path/to/Cairn
```

Options are `name=value` arguments, or `SIM_NAME` environment variables:

| Option | Meaning | Default |
|---|---|---|
| `start` | Drive2's starting position `x,y,z` | `100,64,200` |
| `dest` | Quarry destination for Drive2 | start + `37,0,-21` |
| `cruise` | Cruise Y sent with the Quarry command | the higher of start and destination Y |
| `mine` | Seconds the RM spends "mining" before it comes back | `20` |
| `return` | `0` stops once the RM reaches the seed | `1` |
| `events` | Disturbances, comma separated (see below) | none |
| `wiring` | Which computer side drives which direction, e.g. `Drive1:top=D;Drive2:back=N` | Cairn's own table |
| `wirecheck` | `0` lets a pulse reach its drive even if a computer sits on that side | `1` |
| `range` | Wireless modem range in blocks | `64` |
| `motion` | Seconds a carriage move takes | `1.0` |
| `tlimit` | Simulated seconds before giving up | `2000` |
| `stall` | Stop after this many seconds without progress | `300` |
| `out` | Folder for logs | `sim/out/` |
| `verbose` | `1` prints the event log while running | `0` |
| `dumpfiles` | `1` writes every computer's files to the output folder | `0` |

Events:

| Event | What happens |
|---|---|
| `reboot:Drive2@12.5` | That computer reboots at 12.5 s (`Drive1`, `Drive2`, `RM`, `Controller`) |
| `off:Drive1@40` | That computer loses power and stays off |
| `restart@100` | Server restart: the world is saved, every computer stops and boots 20 s later |
| `crash@100` | Server crash: the world goes back to its last autosave (every 45 s), computer files do not |

## What the scenario does

`scenarios/cairn_quarry.lua` builds the carriage as it is in the game: Drive2
(2700), a carriage engine, the carriage, a second engine, and Drive1 (2701)
four blocks north of Drive2. The Down cable runs over Drive1 and the north
engine, the Up cable under Drive2 and the south engine, and the ender chest
hangs under the carriage. The RM is docked on top of Drive2 facing north. A
stand-in for the controller (2705) sends `set_chunk_grid` and then `quarry`. Drive2's state is pre-seeded with its true
position, as if typed in after a clean install.

Cairn and the RM run their real programs. When the RM saves the `DEPLOYING`
phase, the simulator checks it stands on the expected seed block facing north,
then switches it off: the swarm deployment and mining are not simulated yet.
After `mine` seconds the RM is put back on the dock and answers Cairn's status
query with `quarry_complete`, as the real RM does when docked after Pack It
Up. The RM's own return route is therefore not tested yet.

The checks:

- Every time Drive2 saves its state with no move in progress, the saved
  position must equal where Drive2 really is.
- Every time the RM saves `cairn_rm.cfg` with no move in progress, its saved
  position and facing must match reality.
- The RM must start deploying on the seed block the geometry calls for.
- At the end Cairn must be back at its start with the RM on the dock.
- No turtle may dig or attack a computer or the carriage, and no program may
  loop without yielding.

Modem distances are measured from the computer itself, as ComputerCraft 1.63
does for a modem attached to a computer, so the RM's range checks against
Drive2 and Drive1 behave as they do in the game.

Results:

| Result | Meaning |
|---|---|
| `PASS` | The trip completed and every check held |
| `SAFE_STOP` | A program stopped and asked for a person, with every position still correct |
| `STALLED` | Nothing happened for `stall` seconds and no program explained why |
| `FAIL` | A check failed (`^ VIOLATION`) or something unsafe happened (`^ FATAL`) |

Output goes to the `out` folder: `sim.log` (every boot, redstone change,
carriage move and turtle move) and `screen_<name>.txt` (everything each
computer printed).

## The sweep

```
SIM_CAIRN=/path/to/Cairn bash sim/suite.sh            # about 1,500 runs
SIM_CAIRN=/path/to/Cairn bash sim/suite.sh quick      # 6 runs
SIM_CAIRN=/path/to/Cairn bash sim/suite.sh restarts   # server restarts and crashes only
```

It runs routes in several directions (including negative coordinates), a
route that has to climb and descend, and reboots, server restarts and crashes
at closely spaced times across the trip, including a second RM reboot while
it is still recovering from the first. Runs that do not pass keep their
logs in `out/suite/<run>/`.

## Files

| File | What |
|---|---|
| `run.lua` | Command line, options, runs one scenario |
| `lib/sim.lua` | The simulation: ROM loading, logging, autosave, server restart and crash |
| `lib/sched.lua` | Event queue in simulated time |
| `lib/machine.lua` | One computer: the Java-side APIs and event delivery |
| `lib/turtle.lua` | Turtle commands |
| `lib/net.lua` | Wired and wireless modems |
| `lib/world.lua` | Blocks, terrain and Redstone In Motion carriages |
| `scenarios/cairn_quarry.lua` | The Cairn quarry trip and its checks |
| `suite.sh`, `one.sh` | The sweep |
| `fetch_rom.sh` | Extracts the ROM from your ComputerCraft jar |

## Limits

- The swarm's deployment, mining, Dump and Pack It Up are not simulated, and
  the RM's return route is replaced by placing it on the dock.
- No chunk loading, mobs, or OpenPeripheral inventories yet.
- Terminals report no colour, so the plain shell runs instead of multishell.
- `http` always fails, as if GitHub were unreachable.
