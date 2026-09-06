defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  @flexible_deposit_percent 20

  def up do
    alter table(:group_rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer
      add :deposit_due_cents, :integer
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    create table(:cash_allocations) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :room_id, references(:group_rooms, on_delete: :delete_all), null: false
      # The durable operation that recorded the payment; nil marks the
      # unattributed senior block of funding from before durable records.
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :status, :string, null: false, default: "held"

      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:room_id])
    create index(:cash_allocations, [:payment_operation_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_applications) do
      add :room_id, references(:group_rooms, on_delete: :delete_all)
    end

    create index(:credit_applications, [:room_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      # nil marks the unattributed senior block, which can never be clawed back.
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:credit_lot_id])
    create index(:credit_entitlements, [:payment_operation_id])

    flush()

    backfill_rooms()
    backfill_legacy_cash()
    backfill_legacy_credit()
  end

  def down do
    drop index(:credit_entitlements, [:payment_operation_id])
    drop index(:credit_entitlements, [:credit_lot_id])
    drop table(:credit_entitlements)

    drop index(:credit_applications, [:room_id])

    alter table(:credit_applications) do
      remove :room_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    drop index(:cash_allocations, [:payment_operation_id])
    drop index(:cash_allocations, [:room_id])
    drop index(:cash_allocations, [:group_id])
    drop table(:cash_allocations)

    alter table(:group_rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end

  # Per-room lodging and deposit amounts, and the cancelled status of rooms
  # belonging to cancelled groups.
  defp backfill_rooms do
    groups =
      repo().query!("SELECT id, rate_plan, status, arrival_on, departure_on FROM groups").rows

    Enum.each(groups, fn [group_id, rate_plan, group_status, arrival_on, departure_on] ->
      nights = Date.diff(Date.from_iso8601!(departure_on), Date.from_iso8601!(arrival_on))
      room_status = if group_status == "cancelled", do: "cancelled", else: "active"

      rooms =
        repo().query!(
          "SELECT id, nightly_rate_cents FROM group_rooms WHERE group_id = ?1 ORDER BY position",
          [group_id]
        ).rows

      Enum.each(rooms, fn [room_id, nightly_rate_cents] ->
        lodging = nights * nightly_rate_cents
        deposit = room_deposit(lodging, rate_plan)

        repo().query!(
          "UPDATE group_rooms SET lodging_total_cents = ?1, deposit_due_cents = ?2, status = ?3 WHERE id = ?4",
          [lodging, deposit, room_status, room_id]
        )
      end)
    end)
  end

  # Funding from before durable operation records becomes one unattributed
  # senior block per group: its aggregate cash fills the rooms first, in their
  # original order. Settled cash keeps the disposition the group recorded.
  defp backfill_legacy_cash do
    groups =
      repo().query!(
        "SELECT id, status, cash_paid_cents, refunded_cents, retained_cents, cash_converted_to_credit_cents FROM groups WHERE cash_paid_cents > 0"
      ).rows

    Enum.each(groups, fn [group_id, group_status, cash_paid, refunded, retained, converted] ->
      status = legacy_cash_status(group_status, cash_paid, refunded, retained, converted)
      rooms = rooms_with_deposits(group_id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Enum.reduce(rooms, cash_paid, fn [room_id, deposit], remaining ->
        take = min(remaining, deposit)

        if take > 0 do
          repo().query!(
            "INSERT INTO cash_allocations (group_id, room_id, payment_operation_id, amount_cents, status, inserted_at, updated_at) VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6)",
            [group_id, room_id, take, status, now, now]
          )

          if status == "held" do
            repo().query!(
              "UPDATE group_rooms SET cash_paid_cents = cash_paid_cents + ?1 WHERE id = ?2",
              [take, room_id]
            )
          end
        end

        remaining - take
      end)
    end)
  end

  # The senior block's hotel-credit lots fill what the cash left, in original
  # consumption order (the credit application insertion order).
  defp backfill_legacy_credit do
    groups =
      repo().query!("SELECT DISTINCT group_id FROM credit_applications ORDER BY group_id").rows

    Enum.each(groups, fn [group_id] ->
      filled = filled_by_room(group_id)

      applications =
        repo().query!(
          "SELECT id, credit_lot_id, amount_cents FROM credit_applications WHERE group_id = ?1 ORDER BY id",
          [group_id]
        ).rows

      rooms = rooms_with_deposits(group_id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Enum.reduce(applications, filled, fn [application_id, credit_lot_id, amount], filled ->
        {filled, _remaining} =
          Enum.map_reduce(rooms, amount, fn [room_id, deposit], remaining ->
            take = min(remaining, max(deposit - Map.get(filled, room_id, 0), 0))

            if take > 0 do
              assign_credit(
                application_id,
                credit_lot_id,
                group_id,
                room_id,
                take,
                remaining == amount,
                now
              )

              {Map.update(filled, room_id, take, &(&1 + take)), remaining - take}
            else
              {filled, remaining}
            end
          end)

        filled
      end)
    end)
  end

  # Splits a credit application across the rooms it funds: the first share
  # keeps the original row, later shares insert new rows for the same lot.
  defp assign_credit(application_id, credit_lot_id, group_id, room_id, take, first?, now) do
    if first? do
      repo().query!(
        "UPDATE credit_applications SET room_id = ?1, amount_cents = ?2 WHERE id = ?3",
        [room_id, take, application_id]
      )
    else
      repo().query!(
        "INSERT INTO credit_applications (credit_lot_id, group_id, room_id, amount_cents, inserted_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        [credit_lot_id, group_id, room_id, take, now, now]
      )
    end

    repo().query!(
      "UPDATE group_rooms SET credit_paid_cents = credit_paid_cents + ?1 WHERE id = ?2",
      [take, room_id]
    )
  end

  defp rooms_with_deposits(group_id) do
    repo().query!(
      "SELECT id, deposit_due_cents FROM group_rooms WHERE group_id = ?1 ORDER BY position",
      [group_id]
    ).rows
  end

  defp filled_by_room(group_id) do
    repo().query!(
      "SELECT room_id, amount_cents FROM cash_allocations WHERE group_id = ?1",
      [group_id]
    ).rows
    |> Enum.reduce(%{}, fn [room_id, amount], filled ->
      Map.update(filled, room_id, amount, &(&1 + amount))
    end)
  end

  defp legacy_cash_status("active", _cash, _refunded, _retained, _converted), do: "held"

  defp legacy_cash_status("cancelled", cash, refunded, retained, converted) do
    cond do
      refunded == cash -> "refunded"
      retained == cash -> "retained"
      converted == cash -> "converted"
      true -> "retained"
    end
  end

  defp room_deposit(lodging, "advance_purchase"), do: lodging

  defp room_deposit(lodging, "flexible") do
    # the standard half-up rounding of the flexible percentage
    div(lodging * @flexible_deposit_percent + 50, 100)
  end
end
