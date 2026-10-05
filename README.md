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

On a MacBook (Apple Silicon), in a background session, 300 sleeps each:

| asked | late, median | p99 | max |
|---|---|---|---|
| 100 µs | 2 µs | 5 µs | 9 µs |
| 1 ms | 6 µs | 22 µs | 31 µs |

That's the program's own wake-up; the message then takes some microseconds to
reach the waiting process, more when the BEAM's schedulers are asleep or busy.

## License

Apache-2.0; see LICENSE and NOTICE.
