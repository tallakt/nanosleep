# How late a process wakes on a fixed grid, by each way of waiting:
#
#     mix run bench/compare.exs [interval in microseconds, default 1000] [ticks, default 3000]
#
# Run it on an idle machine, from a terminal of its own, for numbers that mean something.

defmodule Compare do
  def run([]), do: run(["1000"])
  def run([interval]), do: run([interval, "3000"])

  def run([interval, ticks]) do
    interval = String.to_integer(interval) * 1000
    ticks = String.to_integer(ticks)
    {:ok, realtime} = Nanosleep.open()
    {:ok, ordinary} = Nanosleep.open(realtime: false)

    IO.puts("#{div(interval, 1000)} us grid, #{ticks} ticks; lateness in microseconds\n")
    IO.puts("                          p50     p90     p99   p99.9     max")

    for {name, wait} <- [
          {"Erlang timer", &erlang/1},
          {"nanosleep, not realtime", &Nanosleep.sleep_until(ordinary, &1)},
          {"nanosleep", &Nanosleep.sleep_until(realtime, &1)},
          {"nanosleep, spin 250 us", &Nanosleep.sleep_until(realtime, &1, spin: 250_000)}
        ] do
      row(name, grid(wait, interval, ticks))
    end
  end

  defp erlang(deadline) do
    ref = :erlang.start_timer(div(deadline + 999_999, 1_000_000), self(), :tick, abs: true)
    receive do: ({:timeout, ^ref, :tick} -> :ok)
  end

  defp grid(wait, interval, ticks) do
    start = System.monotonic_time(:nanosecond) + interval

    for i <- 0..(ticks - 1) do
      deadline = start + i * interval
      wait.(deadline)
      System.monotonic_time(:nanosecond) - deadline
    end
  end

  defp row(name, lates) do
    sorted = Enum.sort(lates)
    at = fn q -> div(Enum.at(sorted, trunc(q * (length(sorted) - 1))), 1000) end
    cells = Enum.map([at.(0.5), at.(0.9), at.(0.99), at.(0.999), div(List.last(sorted), 1000)], &pad/1)
    IO.puts(String.pad_trailing(name, 24) <> Enum.join(cells))
  end

  defp pad(n), do: String.pad_leading("#{n}", 8)
end

Compare.run(System.argv())
