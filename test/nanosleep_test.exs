defmodule NanosleepTest do
  use ExUnit.Case, async: true

  doctest Nanosleep

  # The tests check what it does, not how punctually: CI machines are busy, and wake late. A
  # second late is a broken sleep, not a slow one.
  @slack 1_000_000_000

  setup do
    {:ok, sleeper} = Nanosleep.open()
    %{sleeper: sleeper}
  end

  defp alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))

  defp gone?(os_pid, tries \\ 100) do
    cond do
      not alive?(os_pid) -> true
      tries == 0 -> false
      true -> Process.sleep(10) && gone?(os_pid, tries - 1)
    end
  end

  test "sleeps at least as long as asked, and answers", %{sleeper: sleeper} do
    for ns <- [1, 1_000, 100_000, 1_000_000, 5_000_000] do
      assert {:ok, slept} = Nanosleep.sleep(sleeper, ns)
      assert slept >= ns
      assert slept - ns < @slack
    end
  end

  test "a sleep of zero or less answers at once", %{sleeper: sleeper} do
    assert {:ok, slept} = Nanosleep.sleep(sleeper, 0)
    assert slept < @slack
    assert {:ok, _} = Nanosleep.sleep(sleeper, -1_000_000_000)
  end

  test "sleeps one after another", %{sleeper: sleeper} do
    started = System.monotonic_time(:nanosecond)
    for _ <- 1..200, do: assert({:ok, _} = Nanosleep.sleep(sleeper, 100_000))
    assert System.monotonic_time(:nanosecond) - started >= 200 * 100_000
  end

  test "sleeps until a deadline, never waking early, with or without spinning", %{
    sleeper: sleeper
  } do
    for spin <- [0, 250_000, 5_000_000] do
      deadline = System.monotonic_time(:nanosecond) + 1_000_000
      assert {:ok, late} = Nanosleep.sleep_until(sleeper, deadline, spin: spin)
      assert late >= 0
      assert System.monotonic_time(:nanosecond) >= deadline
    end

    # A deadline that has passed answers at once.
    assert {:ok, _} = Nanosleep.sleep_until(sleeper, System.monotonic_time(:nanosecond) - 1)
  end

  test "wake_at asks to be woken early by spin, and spin_until waits out the rest", %{
    sleeper: sleeper
  } do
    deadline = System.monotonic_time(:nanosecond) + 3_000_000
    :ok = Nanosleep.wake_at(sleeper, deadline, spin: 2_000_000)
    assert_receive message, 1000
    assert {:woke, slept} = Nanosleep.message(sleeper, message)
    assert slept < 3_000_000
    assert Nanosleep.spin_until(deadline) == :ok
    assert System.monotonic_time(:nanosecond) >= deadline
  end

  test "sleep_until can time out, and fails on a closed sleeper", %{sleeper: sleeper} do
    far = System.monotonic_time(:nanosecond) + 10_000_000_000
    assert Nanosleep.sleep_until(sleeper, far, timeout: 10) == {:error, :timeout}
    {:ok, other} = Nanosleep.open()
    Nanosleep.close(other)
    assert Nanosleep.sleep_until(other, far) == {:error, :closed}
  end

  test "answers come as messages, for message/2", %{sleeper: sleeper} do
    :ok = Nanosleep.wake_after(sleeper, 200_000)
    assert_receive message, 1000
    assert {:woke, slept} = Nanosleep.message(sleeper, message)
    assert slept >= 200_000
    assert Nanosleep.message(sleeper, :something_else) == :other
  end

  test "without real time, it sleeps all the same" do
    {:ok, sleeper} = Nanosleep.open(realtime: false)
    assert {:ok, slept} = Nanosleep.sleep(sleeper, 1_000_000)
    assert slept >= 1_000_000
  end

  test "a priority is a number from 1 to 99, and goes with real time" do
    assert_raise ArgumentError, ~r/from 1 to 99, got: 0/, fn -> Nanosleep.open(priority: 0) end

    assert_raise ArgumentError, ~r/from 1 to 99, got: 100/, fn ->
      Nanosleep.open(priority: 100)
    end

    assert_raise ArgumentError, ~r/from 1 to 99, got: "2"/, fn ->
      Nanosleep.open(priority: "2")
    end

    assert_raise ArgumentError, ~r/realtime: false turns off/, fn ->
      Nanosleep.open(realtime: false, priority: 2)
    end
  end

  # With root, CAP_SYS_NICE or an rtprio limit it gets the priority; without, as on CI, it
  # ends rather than sleep as an ordinary process.
  @tag :linux
  test "the program takes the priority asked for, or ends with status 3 where it's refused" do
    Process.flag(:trap_exit, true)
    {:ok, sleeper} = Nanosleep.open(priority: 2)

    receive do
      message -> assert Nanosleep.message(sleeper, message) == {:closed, 3}
    after
      500 ->
        assert {:ok, _slept} = Nanosleep.sleep(sleeper, 1000)
        [_pid, stat] = String.split(File.read!("/proc/#{Nanosleep.os_pid(sleeper)}/stat"), ") ")
        fields = String.split(stat)
        assert {Enum.at(fields, 38), Enum.at(fields, 37)} == {"1", "2"}
    end
  end

  # These look at the program from outside, with kill.
  @tag :unix
  test "closing ends the program", %{sleeper: sleeper} do
    os_pid = Nanosleep.os_pid(sleeper)
    assert alive?(os_pid)
    assert :ok = Nanosleep.close(sleeper)
    assert gone?(os_pid)
    assert Nanosleep.close(sleeper) == :ok
    assert Nanosleep.wake_after(sleeper, 1) == {:error, :closed}
    assert Nanosleep.os_pid(sleeper) == nil
  end

  @tag :unix
  test "the program ends with its owner" do
    test = self()

    owner =
      spawn(fn ->
        {:ok, sleeper} = Nanosleep.open()
        send(test, {:os_pid, Nanosleep.os_pid(sleeper)})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:os_pid, os_pid}
    send(owner, :stop)
    assert gone?(os_pid)
  end

  @tag :unix
  test "a killed program closes the port, and its owner carries on", %{sleeper: sleeper} do
    System.cmd("kill", ["-9", "#{Nanosleep.os_pid(sleeper)}"])
    assert_receive message, 1000
    assert {:closed, status} = Nanosleep.message(sleeper, message)
    assert status != 0
    assert Nanosleep.wake_after(sleeper, 1) == {:error, :closed}
    assert Nanosleep.sleep(sleeper, 1) == {:error, :closed}

    # And a new one may be opened.
    {:ok, again} = Nanosleep.open()
    assert {:ok, _} = Nanosleep.sleep(again, 1_000)
  end

  @tag :unix
  test "an owner that traps exits survives its program dying under a stream of requests" do
    Process.flag(:trap_exit, true)
    {:ok, sleeper} = Nanosleep.open()
    os_pid = Nanosleep.os_pid(sleeper)
    spawn(fn -> Process.sleep(20) && System.cmd("kill", ["-9", "#{os_pid}"]) end)
    assert closed(sleeper) != nil
  end

  # Sleeps until the program is gone; the reason it gave.
  defp closed(sleeper) do
    case Nanosleep.wake_after(sleeper, 1_000) do
      :ok ->
        receive do
          message ->
            case Nanosleep.message(sleeper, message) do
              {:closed, reason} -> reason
              _ -> closed(sleeper)
            end
        end

      {:error, :closed} ->
        :closed
    end
  end

  @tag :unix
  test "a killed program ends a sleep with an error", %{sleeper: sleeper} do
    os_pid = Nanosleep.os_pid(sleeper)
    spawn(fn -> Process.sleep(50) && System.cmd("kill", ["-9", "#{os_pid}"]) end)
    assert Nanosleep.sleep(sleeper, 10_000_000_000) == {:error, :closed}
  end

  test "a sleep can time out", %{sleeper: sleeper} do
    assert Nanosleep.sleep(sleeper, 1_000_000_000, 10) == {:error, :timeout}
  end

  test "a request it doesn't understand ends the program", %{sleeper: sleeper} do
    # The program may end as the request is still being written: :epipe, as the docs say.
    Process.flag(:trap_exit, true)
    %{port: port} = sleeper
    Port.command(port, <<1, 2, 3>>)
    assert_receive message, 1000
    assert {:closed, reason} = Nanosleep.message(sleeper, message)
    assert reason in [2, :epipe]
  end
end
