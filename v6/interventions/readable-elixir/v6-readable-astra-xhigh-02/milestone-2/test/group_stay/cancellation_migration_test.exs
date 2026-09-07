defmodule GroupStay.CancellationMigrationTest do
  use ExUnit.Case, async: false

  import GroupStay.PartnerOperations
  import GroupStay.MigrationHelpers

  alias GroupStay.{PartnerBatches, Repo, Reservations}

  @repo_name __MODULE__.Repo

  test "upgrading an earlier database backfills booking policies without changing existing accounts" do
    directory = Path.expand("tmp/migration-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)

    {:ok, pid} =
      Repo.start_link(
        name: @repo_name,
        database: Path.join(directory, "legacy.db"),
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    Process.unlink(pid)
    previous_repo = Repo.put_dynamic_repo(@repo_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Supervisor.stop(pid)
      File.rm_rf!(directory)
    end)

    try do
      assert Ecto.Migrator.run(Repo, migrations(), :up, to: 20_260_907_000_000, log: false) == [
               20_260_907_000_000
             ]

      for {id, booked, plan, status} <- [
            {"legacy", "2026-12-31", "flexible", "active"},
            {"new-date", "2027-01-01", "flexible", "active"},
            {"advance", "2027-01-01", "advance_purchase", "active"},
            {"cancelled", "2026-12-31", "flexible", "cancelled"}
          ] do
        deposit = if plan == "advance_purchase", do: 97_500, else: 19_500
        due = if status == "active", do: deposit, else: 0
        refunded = if status == "cancelled", do: 1_000, else: 0

        Repo.query!(
          """
          INSERT INTO groups
            (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
             rate_plan, status, revision, lodging_total_cents, deposit_due_cents,
             deposit_paid_cents, refunded_cents, retained_cents, inserted_at, updated_at)
          VALUES (?, 'guest-22', 'ams-canal', ?, '2028-06-01', '2028-06-04', ?, ?,
                  3, 97500, ?, 1000, ?, 0, '2026-12-31 00:00:00', '2027-02-01 00:00:00')
          """,
          [id, booked, plan, status, due, refunded]
        )

        for {room, position, rate} <- [{"room-b", 0, 15_000}, {"room-a", 1, 17_500}] do
          Repo.query!(
            "INSERT INTO rooms (group_id, room_id, position, nightly_rate_cents) VALUES (?, ?, ?, ?)",
            [id, room, position, rate]
          )
        end
      end

      original_groups = table_rows("groups")
      original_rooms = table_rows("rooms")

      assert Ecto.Migrator.run(Repo, migrations(), :up, all: true, log: false) == [
               20_260_907_000_001
             ]

      assert Enum.map(table_rows("groups"), fn row ->
               Map.drop(row, [
                 "policy_version",
                 "credit_paid_cents",
                 "cash_converted_to_credit_cents"
               ])
             end) == original_groups

      assert table_rows("rooms") == original_rooms

      for {id, policy, deadline} <- [
            {"legacy", "flex-14", ~D[2028-05-18]},
            {"new-date", "flex-30", ~D[2028-05-02]},
            {"advance", "advance-nonrefundable", nil},
            {"cancelled", "flex-14", ~D[2028-05-18]}
          ] do
        group = Reservations.get_group(id)
        %{data: data} = GroupStayWeb.GroupJSON.show(%{group: group})
        assert data.policy_version == policy
        assert data.refundable_until == deadline
        assert data.cash_paid_cents == 1_000
        assert data.credit_paid_cents == 0
        assert data.revision == 3
        assert Enum.map(data.rooms, & &1.room_id) == ["room-b", "room-a"]
      end

      assert Reservations.ledger() == %{
               cash_held_cents: 3_000,
               cash_refunded_cents: 1_000,
               cash_retained_cents: 0,
               cash_converted_to_credit_cents: 0,
               credit_liability_cents: 0
             }

      assert {:ok, [%{status: "applied", policy_version: "flex-14", revision: 4}]} =
               PartnerBatches.submit(%{
                 "operations" => [
                   reschedule(%{
                     "group_id" => "legacy",
                     "occurred_on" => "2028-01-01",
                     "new_arrival_on" => "2028-07-01",
                     "expected_revision" => 3
                   })
                 ]
               })

      assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
    after
      Repo.put_dynamic_repo(previous_repo)
    end
  end

  defp table_rows(table) do
    %{columns: columns, rows: rows} = Repo.query!("SELECT * FROM #{table} ORDER BY group_id")
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
