defmodule GroupStay.WriteLockTest do
  # Uses the application-wide lock, so it must not overlap other tests that write.
  use ExUnit.Case, async: false

  alias GroupStay.WriteLock

  test "admits one holder at a time, in arrival order" do
    parent = self()
    blocker = hold_until_released()

    holders =
      for n <- 1..5 do
        task =
          Task.async(fn ->
            WriteLock.run(fn ->
              send(parent, {:enter, n})
              Process.sleep(2)
              send(parent, {:leave, n})
            end)
          end)

        wait_until_queued(n)
        task
      end

    send(blocker, :release)
    Task.await_many(holders)

    events = for _ <- 1..10, do: receive(do: ({_, _} = event -> event))
    assert events == Enum.flat_map(1..5, &[{:enter, &1}, {:leave, &1}])
  end

  test "releases the lock when the holder exits or raises" do
    holder = hold_until_released()
    waiter = Task.async(fn -> WriteLock.run(fn -> :granted end) end)
    refute Task.yield(waiter, 20)

    Process.exit(holder, :kill)
    assert Task.await(waiter) == :granted

    assert_raise RuntimeError, fn -> WriteLock.run(fn -> raise "boom" end) end
    assert WriteLock.run(fn -> :granted end) == :granted
  end

  defp hold_until_released do
    parent = self()

    holder =
      spawn(fn ->
        WriteLock.run(fn ->
          send(parent, :holding)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :holding
    holder
  end

  defp wait_until_queued(count) do
    unless :queue.len(:sys.get_state(WriteLock).waiting) == count do
      Process.sleep(1)
      wait_until_queued(count)
    end
  end
end
