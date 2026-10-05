# nanosleep

[![CI](https://github.com/tallakt/nanosleep/actions/workflows/ci.yml/badge.svg)](https://github.com/tallakt/nanosleep/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/nanosleep.svg)](https://hex.pm/packages/nanosleep)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-purple.svg)](https://hexdocs.pm/nanosleep)

*Implemented by AI under the supervision of Tallak Tveide.*

Sleeps shorter than a millisecond, for the BEAM.

Erlang's timers count in milliseconds. nanosleep runs a small C program as a
port, which sleeps for the nanoseconds asked with the operating system's high
resolution timers and then answers; the answer wakes the waiting process. The
wake-up comes from outside the BEAM rather than from its timer wheel.

```elixir
{:ok, sleeper} = Nanosleep.open()
{:ok, slept} = Nanosleep.sleep(sleeper, 250_000)
```

The program wakes within microseconds; its answer then waits for the BEAM to
deliver it, typically some tens of microseconds. For a start on the
microsecond, `Nanosleep.sleep_until/3` with `spin:` wakes that much early and
waits out the rest busy, for that much CPU each time:

```elixir
deadline = System.monotonic_time(:nanosecond) + 2_000_000
{:ok, late} = Nanosleep.sleep_until(sleeper, deadline, spin: 250_000)
```

A process that does more than sleep, such as a GenServer, asks with
`Nanosleep.wake_after/2` and gets the answer as a message; see `Nanosleep`.

The program asks to be scheduled in real time where it may: the time
constraint policy on macOS, SCHED_FIFO at the lowest real-time priority on
Linux (with root, CAP_SYS_NICE or an rtprio limit), and time critical thread
priority on Windows. It only ever sleeps and answers.

## Safe to run beside your application

The C code runs in its own operating system process, not in the BEAM: if it
crashes, the port closes and its owner gets `{:closed, status}` from
`Nanosleep.message/2`, and may open another. The program exits when its port
closes or the BEAM goes away.

## Installation

```elixir
{:nanosleep, "~> 0.1"}
```

It needs a C compiler where it compiles: `cc` and `make` on Linux and macOS,
and on Windows MSVC's `cl` and `nmake`, from a Developer Command Prompt.
Linux, macOS and Windows (10 version 1803 or later for sleeps shorter than a
millisecond).

## How well

How late a process wakes on a fixed grid, measured with `bench/compare.exs`
(3000 ticks; lateness in microseconds; run it on your own hardware to see yours).

**Linux**: a Scaleway bare-metal server, 2 × Intel Xeon E5-2620 v2, Debian 13
with its real-time kernel (6.12, PREEMPT_RT), as root, CPU governor
`performance` and only shallow idle states (`cpupower idle-set -D 10`):

| 1 ms grid | p50 | p90 | p99 | p99.9 | max |
|---|---|---|---|---|---|
| Erlang timer | 1612 | 1614 | 1621 | 1873 | 3849 |
| nanosleep, not realtime | 64 | 68 | 76 | 99 | 198 |
| nanosleep | 45 | 48 | 65 | 142 | 217 |
| nanosleep, spin 250 µs | 0 | 0 | 0 | 1 | 30 |

| 500 µs grid | p50 | p90 | p99 | p99.9 | max |
|---|---|---|---|---|---|
| Erlang timer | 1879 | 1912 | 1929 | 1955 | 2198 |
| nanosleep, not realtime | 61 | 63 | 67 | 103 | 182 |
| nanosleep | 48 | 53 | 64 | 129 | 204 |
| nanosleep, spin 250 µs | 0 | 0 | 0 | 2 | 6 |

The same machine with the CPU left as installed (governor `schedutil`, all
idle states): nanosleep 150 / 199 / 219 / 241 / 293 on the 1 ms grid, and
with spin 0 / 0 / 2 / 9 / 50. Deep idle states are what make the wake-up slow.

**macOS**: an Apple Silicon MacBook in everyday use, four runs. The medians
held from run to run; the tail is the desktop's:

| 1 ms grid | p50 | p90 | p99 | max |
|---|---|---|---|---|
| Erlang timer | 1338–1495 | 1357–1525 | 1695–4020 | 3802–10546 |
| nanosleep | 60 | 75–78 | 300–586 | 6411–7111 |
| nanosleep, spin 250 µs | 0 | 0 | 154–273 | 4192–5796 |

The program itself wakes within microseconds; most of what's left is the BEAM
delivering its answer, which `spin` takes out of the timing for that much CPU
per wake-up. Windows works, and hasn't been measured.

## License

Apache-2.0; see LICENSE and NOTICE.
