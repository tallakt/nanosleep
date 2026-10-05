defmodule Nanosleep do
  @moduledoc """
  Sleeps shorter than a millisecond, which Erlang's timers can't.

  A small C program, started as a port, sleeps for the nanoseconds asked and
  then answers, and the answer wakes the process waiting for it. The program
  sleeps with the operating system's high resolution timers, so the wake-up
  comes from outside the BEAM rather than from its millisecond timer wheel.

      iex> {:ok, sleeper} = Nanosleep.open()
      iex> {:ok, slept} = Nanosleep.sleep(sleeper, 250_000)
      iex> slept >= 250_000
      true

  ## Owned like a socket

  `open/1` starts the program for the calling process, which owns it the way
  it owns a socket: the answers come to it as messages, and when it exits the
  port closes and the program ends. Each process that wants to be woken opens
  its own. A process that does more than sleep, such as a GenServer, asks
  with `wake_after/2` and hands what arrives to `message/2`:

      def handle_info(message, %{sleeper: sleeper} = state) do
        case Nanosleep.message(sleeper, message) do
          {:woke, _slept} -> ...
          {:closed, _status} -> ...
          :other -> ...
        end
      end

  One sleep at a time: the program reads the next request when it has
  answered the last.

  ## On the microsecond

  The program wakes within microseconds of its time, but its answer then
  waits for the BEAM to deliver it, which typically takes tens of
  microseconds. `wake_at/3` with `spin:` asks to be woken a little early, and
  `spin_until/1` waits out the rest busy; `sleep_until/3` does both:

      deadline = System.monotonic_time(:nanosecond) + 2_000_000
      {:ok, _late} = Nanosleep.sleep_until(sleeper, deadline, spin: 250_000)

  ## When it fails

  If the program ends, crashed or killed, the owner gets `{:closed, status}`
  from `message/2`, and may `open/1` again. The port is linked to its owner:
  it usually closes with reason `:normal`, but with `:epipe` if the program
  died as a request was written to it, which takes down an owner that doesn't
  trap exits. One that must survive, traps exits, and `message/2` turns the
  `{:EXIT, port, reason}` into `{:closed, reason}` too.

  Supported on Linux, macOS and Windows (10 version 1803 or later for
  sleeps shorter than a millisecond).
  """

  defstruct [:port]

  @typedoc "A sleeper: the port to its program."
  @opaque t :: %__MODULE__{port: port}

  @doc """
  Starts the program, owned by the calling process.

  ## Options

    * `:realtime` - whether the program asks to be scheduled in real time
      (default true): the time constraint policy on macOS, which any program
      may have, and SCHED_FIFO at the lowest real-time priority on Linux,
      which takes root, CAP_SYS_NICE or an rtprio limit. Where that's refused
      it sleeps as an ordinary process, and wakes later.
  """
  @spec open(keyword) :: {:ok, t} | {:error, term}
  def open(opts \\ []) do
    path = Application.app_dir(:nanosleep, "priv/nanosleep" <> exe())
    args = if Keyword.get(opts, :realtime, true), do: [], else: ["--no-realtime"]
    options = [:binary, {:packet, 2}, :exit_status, :use_stdio, args: args]
    {:ok, %__MODULE__{port: Port.open({:spawn_executable, path}, options)}}
  rescue
    error in ErlangError -> {:error, error.original}
  end

  defp exe, do: if(match?({:win32, _}, :os.type()), do: ".exe", else: "")

  @doc """
  Asks to be woken after `nanoseconds`. The answer comes as a message for
  `message/2`: `{:woke, slept}`, with the nanoseconds the program slept.
  """
  @spec wake_after(t, integer) :: :ok | {:error, :closed}
  def wake_after(%__MODULE__{port: port}, nanoseconds) when is_integer(nanoseconds) do
    true = Port.command(port, <<nanoseconds::signed-64>>)
    :ok
  rescue
    ArgumentError -> {:error, :closed}
  end

  @doc """
  What a message means for the sleeper: `{:woke, slept}` for an answer to
  `wake_after/2`, with the nanoseconds slept; `{:closed, status}` when its
  program has ended, with its exit status; `:other` for any other message.
  """
  @spec message(t, term) :: {:woke, non_neg_integer} | {:closed, term} | :other
  def message(%__MODULE__{port: port}, {port, {:data, <<slept::signed-64>>}}), do: {:woke, slept}
  def message(%__MODULE__{port: port}, {port, {:exit_status, status}}), do: {:closed, status}
  def message(%__MODULE__{port: port}, {:EXIT, port, reason}), do: {:closed, reason}
  def message(%__MODULE__{}, _message), do: :other

  @doc """
  Sleeps for `nanoseconds` and returns the nanoseconds slept, in the calling
  process, which must own the sleeper. `timeout` is how many milliseconds to
  wait for the answer at most.
  """
  @spec sleep(t, integer, timeout) :: {:ok, non_neg_integer} | {:error, :closed | :timeout}
  def sleep(%__MODULE__{port: port} = sleeper, nanoseconds, timeout \\ :infinity) do
    with :ok <- wake_after(sleeper, nanoseconds) do
      receive do
        {^port, {:data, <<slept::signed-64>>}} -> {:ok, slept}
        {^port, {:exit_status, _}} -> {:error, :closed}
      after
        timeout -> {:error, :timeout}
      end
    end
  end

  @doc """
  Asks to be woken at `deadline`, a `System.monotonic_time(:nanosecond)`: the
  answer comes as for `wake_after/2`.

  With `spin: nanoseconds`, it asks to be woken that much earlier, and the
  owner then waits out the rest with `spin_until/1`. The program wakes within
  microseconds, but its answer reaches the owner only when the BEAM gets round
  to it, which takes tens of microseconds and sometimes far more; waiting busy
  takes that out of the timing, for as much CPU as `spin` each time.
  """
  @spec wake_at(t, integer, keyword) :: :ok | {:error, :closed}
  def wake_at(sleeper, deadline, opts \\ []) do
    spin = Keyword.get(opts, :spin, 0)
    wake_after(sleeper, deadline - spin - System.monotonic_time(:nanosecond))
  end

  @doc """
  Waits busy until `deadline`, a `System.monotonic_time(:nanosecond)`, for the
  last stretch after `wake_at/3` with `spin:`. The process stays runnable, so
  the scheduler may still run others in between; it returns at once for a
  deadline that has passed.
  """
  @spec spin_until(integer) :: :ok
  def spin_until(deadline) do
    if System.monotonic_time(:nanosecond) < deadline, do: spin_until(deadline), else: :ok
  end

  @doc """
  Sleeps until `deadline`, a `System.monotonic_time(:nanosecond)`, in the
  calling process, which must own the sleeper, and returns how late it woke, in
  nanoseconds.

  ## Options

    * `:spin` - nanoseconds to wait busy at the end, as for `wake_at/3`
      (default 0)
    * `:timeout` - milliseconds to wait for the program's answer at most
      (default `:infinity`)
  """
  @spec sleep_until(t, integer, keyword) :: {:ok, non_neg_integer} | {:error, :closed | :timeout}
  def sleep_until(%__MODULE__{port: port} = sleeper, deadline, opts \\ []) do
    with :ok <- wake_at(sleeper, deadline, opts) do
      receive do
        {^port, {:data, <<_slept::signed-64>>}} ->
          spin_until(deadline)
          {:ok, System.monotonic_time(:nanosecond) - deadline}

        {^port, {:exit_status, _}} ->
          {:error, :closed}
      after
        Keyword.get(opts, :timeout, :infinity) -> {:error, :timeout}
      end
    end
  end

  @doc "The operating system's process id of the program, or nil once it has ended."
  @spec os_pid(t) :: non_neg_integer | nil
  def os_pid(%__MODULE__{port: port}) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  end

  @doc "Closes the port, which ends the program."
  @spec close(t) :: :ok
  def close(%__MODULE__{port: port}) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
