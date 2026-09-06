defmodule GroupStay.Reservations.DurableOperationsTest do
  use ExUnit.Case, async: false

  alias GroupStay.Repo
  alias GroupStay.Reservations
  alias GroupStay.Reservations.{Group, Operation}

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    clear_records()

    on_exit(fn ->
      clear_records()
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)
  end

  test "concurrent equivalent deliveries have one effect and return the same result" do
    operation = open_operation("concurrent-open", "concurrent-group")
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :process -> Reservations.process(operation)
          end
        end)
      end

    task_pids =
      for _ <- tasks do
        assert_receive {:ready, task_pid}
        task_pid
      end

    Enum.each(task_pids, &send(&1, :process))

    assert [result, result] = Task.await_many(tasks)
    assert result["status"] == "applied"
    assert Repo.aggregate(Group, :count) == 1
    assert Repo.aggregate(Operation, :count) == 1
  end

  test "a fault while storing the result rolls back domain changes and can be retried" do
    Ecto.Adapters.SQL.query!(Repo, """
    CREATE TRIGGER fail_operation_audit
    BEFORE INSERT ON partner_operations
    WHEN NEW.operation_id = 'faulted-open'
    BEGIN
      SELECT RAISE(FAIL, 'forced operation audit failure');
    END
    """)

    operation = open_operation("faulted-open", "faulted-group")

    assert_raise Exqlite.Error, fn -> Reservations.process(operation) end
    assert Repo.get_by(Group, group_id: "faulted-group") == nil
    assert Repo.get_by(Operation, operation_id: "faulted-open") == nil

    Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER fail_operation_audit")

    assert %{"status" => "applied"} = Reservations.process(operation)
    assert Repo.get_by(Group, group_id: "faulted-group")
    assert Repo.get_by(Operation, operation_id: "faulted-open")
  end

  defp clear_records do
    Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER IF EXISTS fail_operation_audit")
    Repo.delete_all(Operation)
    Repo.delete_all(Group)
  end

  defp open_operation(operation_id, group_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
    }
  end
end
