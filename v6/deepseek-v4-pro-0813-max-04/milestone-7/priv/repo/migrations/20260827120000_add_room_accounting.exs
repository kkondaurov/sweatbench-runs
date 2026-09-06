defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :deposit_due_cents, :integer
    end

    create table(:cash_allocations) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :disposed, :string

      timestamps()
    end

    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:room_id])
    create index(:cash_allocations, [:payment_operation_id])

    alter table(:credit_applications) do
      add :room_id, references(:rooms, on_delete: :delete_all)
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:credit_lot_funding) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :cash_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false

      timestamps()
    end

    create index(:credit_lot_funding, [:credit_lot_id])
    create index(:credit_lot_funding, [:payment_operation_id])

    execute(fn -> backfill_legacy_groups() end)

    # Group money totals are now derived from the room-level allocation rows;
    # the pre-allocation aggregate columns are no longer needed.
    alter table(:groups) do
      remove :lodging_total_cents
      remove :deposit_due_cents
      remove :deposit_paid_cents
      remove :outstanding_deposit_cents
      remove :refunded_cents
      remove :retained_cents
      remove :cash_paid_cents
      remove :credit_paid_cents
      remove :cash_converted_to_credit_cents
    end
  end

  def down do
    alter table(:groups) do
      add :lodging_total_cents, :integer
      add :deposit_due_cents, :integer
      add :deposit_paid_cents, :integer
      add :outstanding_deposit_cents, :integer
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
      add :cash_converted_to_credit_cents, :integer, null: false, default: 0
    end

    drop index(:credit_lot_funding, [:payment_operation_id])
    drop index(:credit_lot_funding, [:credit_lot_id])
    drop table(:credit_lot_funding)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:credit_applications) do
      remove :room_id
    end

    drop index(:cash_allocations, [:payment_operation_id])
    drop index(:cash_allocations, [:room_id])
    drop index(:cash_allocations, [:group_id])
    drop table(:cash_allocations)

    alter table(:rooms) do
      remove :deposit_due_cents
      remove :status
    end
  end

  # Groups built by earlier releases have no room-level allocations. Their
  # existing funding becomes one unattributed senior block per group: the
  # aggregate cash first, then hotel-credit lots in original consumption
  # order. Cancelled groups already settled their cash, so only their
  # settled dispositions are reconstructed. No aggregate balance changes.
  defp backfill_legacy_groups do
    repo = repo()

    repo.query!(
      "UPDATE rooms SET status = 'cancelled' " <>
        "WHERE group_id IN (SELECT id FROM groups WHERE status <> 'active')"
    )

    groups =
      repo.query!(
        "SELECT id, status, rate_plan, arrival_on, departure_on, cash_paid_cents, " <>
          "refunded_cents, retained_cents, cash_converted_to_credit_cents " <>
          "FROM groups ORDER BY id"
      )

    Enum.each(groups.rows, fn [
                                gid,
                                status,
                                rate_plan,
                                arrival,
                                departure,
                                cash,
                                refunded,
                                retained,
                                converted
                              ] ->
      {:ok, arrival_date} = Date.from_iso8601(arrival)
      {:ok, departure_date} = Date.from_iso8601(departure)
      nights = Date.diff(departure_date, arrival_date)

      rooms =
        repo.query!(
          "SELECT id, room_id, nightly_rate_cents FROM rooms WHERE group_id = ? ORDER BY id",
          [gid]
        ).rows

      due_by =
        Map.new(rooms, fn [rid, _name, rate] ->
          due = room_deposit_due(nights, rate, rate_plan)
          repo.query!("UPDATE rooms SET deposit_due_cents = ? WHERE id = ?", [due, rid])
          {rid, due}
        end)

      case status do
        "active" ->
          {paid_by_room, _left} =
            allocate(rooms, due_by, cash, %{}, repo, fn rid, take ->
              repo.query!(
                "INSERT INTO cash_allocations " <>
                  "(group_id, room_id, payment_operation_id, amount_cents, disposed, " <>
                  "inserted_at, updated_at) " <>
                  "VALUES (?, ?, NULL, ?, NULL, datetime('now'), datetime('now'))",
                [gid, rid, take]
              )
            end)

          split_credit_applications(repo, gid, rooms, due_by, paid_by_room)

        _ ->
          [[first_room | _] | _] = rooms

          if refunded > 0 do
            insert_disposed(repo, gid, first_room, refunded, "refunded")
          end

          if retained > 0 do
            insert_disposed(repo, gid, first_room, retained, "retained")
          end

          if converted > 0 do
            insert_disposed(repo, gid, first_room, converted, "converted")
          end

          split_credit_applications(repo, gid, rooms, due_by, %{})
      end
    end)
  end

  defp split_credit_applications(repo, gid, rooms, due_by, paid_by_room) do
    applications =
      repo.query!(
        "SELECT id, credit_lot_id, amount_cents FROM credit_applications " <>
          "WHERE group_id = ? ORDER BY id",
        [gid]
      ).rows

    Enum.each(applications, fn [app_id, lot_id, amount] ->
      {_paid, _left} =
        allocate(rooms, due_by, amount, paid_by_room, repo, fn rid, take ->
          repo.query!(
            "INSERT INTO credit_applications " <>
              "(group_id, credit_lot_id, room_id, amount_cents, inserted_at, updated_at) " <>
              "VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))",
            [gid, lot_id, rid, take]
          )
        end)

      repo.query!("DELETE FROM credit_applications WHERE id = ?", [app_id])
    end)
  end

  defp insert_disposed(repo, gid, room_id, amount, disposition) do
    repo.query!(
      "INSERT INTO cash_allocations " <>
        "(group_id, room_id, payment_operation_id, amount_cents, disposed, " <>
        "inserted_at, updated_at) " <>
        "VALUES (?, ?, NULL, ?, ?, datetime('now'), datetime('now'))",
      [gid, room_id, amount, disposition]
    )
  end

  # Fills each room's deposit entirely before moving to the next room.
  defp allocate(rooms, due_by, amount, paid_by_room, repo, insert) do
    rooms
    |> Enum.reduce({paid_by_room, amount}, fn [rid, _name, _rate], {paid, remaining} ->
      if remaining <= 0 do
        {paid, remaining}
      else
        due = Map.fetch!(due_by, rid)
        current = Map.get(paid, rid, 0)
        cap = max(due - current, 0)
        take = min(cap, remaining)

        if take > 0 do
          insert.(rid, take)
        end

        {Map.put(paid, rid, current + take), remaining - take}
      end
    end)
  end

  defp room_deposit_due(nights, rate, "advance_purchase"), do: nights * rate
  defp room_deposit_due(nights, rate, "flexible"), do: div(nights * rate * 20 + 50, 100)
end
