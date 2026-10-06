# Changelog

## 0.3.0

On Linux the program keeps one priority above the BEAM's while the BEAM is
itself scheduled in real time, and follows it when it changes, so that it
wakes on time without being given a priority. It took the lowest real-time
priority before, whatever the BEAM's. `priority:` asks for a fixed one, as it
did.

## 0.2.0

`Nanosleep.open/1` takes `priority:` on Linux, the SCHED_FIFO priority the
program asks for instead of the lowest. Under a BEAM that is itself scheduled
in real time, the program has to outrank it to wake on time. A priority that
is refused ends the program with status 3, and the option raises on systems
that have no such priority.

## 0.1.0

The first release: `Nanosleep.open/1`, `sleep/3`, `sleep_until/3`,
`wake_after/2`, `wake_at/3`, `spin_until/1` and `message/2`, with a port
program for Linux, macOS and Windows that sleeps with the system's high
resolution timers, in real time where it may.
