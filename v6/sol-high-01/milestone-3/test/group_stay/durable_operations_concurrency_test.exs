defmodule GroupStay.DurableOperationsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias GroupStay.Bookings
  alias GroupStay.Bookings.{Group, PartnerOperation, Room}
  alias GroupStay.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    clear_domain_data()

    on_exit(fn ->
      clear_domain_data()
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "concurrent retries have one effect and return one exact result" do
    operation = open_operation()
    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :apply -> Bookings.apply_batch([operation])
          end
        end)
      end

    task_pids =
      for _ <- tasks do
        assert_receive {:ready, task_pid}
        task_pid
      end

    Enum.each(task_pids, &send(&1, :apply))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert length(Enum.uniq(results)) == 1

    assert Repo.aggregate(
             from(group in Group, where: group.group_id == "concurrent-group"),
             :count
           ) ==
             1

    assert Repo.aggregate(from(room in Room, where: room.group_id == "concurrent-group"), :count) ==
             1

    assert Repo.aggregate(
             from(operation in PartnerOperation,
               where: operation.operation_id == "concurrent-open"
             ),
             :count
           ) == 1

    assert [%{"status" => "applied", "revision" => 1}] = hd(results)

    assert :ok = Supervisor.terminate_child(GroupStay.Supervisor, Repo)
    assert {:ok, _repo} = Supervisor.restart_child(GroupStay.Supervisor, Repo)
    Sandbox.mode(Repo, :auto)

    assert Bookings.apply_batch([operation]) == hd(results)
    assert {:ok, hd_result} = Bookings.get_operation("concurrent-open")
    assert hd_result == hd(hd(results))
  end

  defp clear_domain_data do
    Repo.delete_all(
      from operation in PartnerOperation, where: operation.operation_id == "concurrent-open"
    )

    Repo.delete_all(from group in Group, where: group.group_id == "concurrent-group")
  end

  defp open_operation do
    %{
      "operation_id" => "concurrent-open",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "concurrent-group",
      "guest_id" => "guest",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-11",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room", "nightly_rate_cents" => 10_000}]
    }
  end
end
