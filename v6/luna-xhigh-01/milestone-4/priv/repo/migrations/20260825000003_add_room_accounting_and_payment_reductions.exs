defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:group_rooms) do
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :status, :string, null: false, default: "active"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_applications) do
      add :funding_operation_id, :string
    end

    create table(:room_funding_allocations) do
      add :group_id, :string, null: false
      add :room_id, :string, null: false
      add :funding_type, :string, null: false
      add :source_type, :string, null: false
      add :source_id, :string
      add :credit_application_id, :integer
      add :amount_cents, :integer, null: false
    end

    create index(:room_funding_allocations, [:group_id, :room_id, :id])
    create index(:room_funding_allocations, [:source_type, :source_id])
    create index(:room_funding_allocations, [:credit_application_id])

    create table(:payment_accountings) do
      add :payment_operation_id, :string, null: false
      add :group_id, :string, null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create unique_index(:payment_accountings, [:payment_operation_id])
    create index(:payment_accountings, [:group_id])

    create table(:credit_lot_entitlements) do
      add :credit_lot_id,
          references(:hotel_credit_lots, column: :id, on_delete: :delete_all),
          null: false

      add :payment_operation_id, :string
      add :entitlement_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0
    end

    create index(:credit_lot_entitlements, [:credit_lot_id])
    create index(:credit_lot_entitlements, [:payment_operation_id])

    flush()
    backfill_legacy_room_accounting()
  end

  def down do
    drop table(:credit_lot_entitlements)
    drop table(:payment_accountings)
    drop table(:room_funding_allocations)

    alter table(:hotel_credit_applications) do
      remove :funding_operation_id
    end

    alter table(:hotel_credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:group_rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :status
      remove :deposit_due_cents
      remove :lodging_total_cents
    end

    alter table(:groups) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end
  end

  defp backfill_legacy_room_accounting do
    groups =
      repo().query!("""
      SELECT group_id, rate_plan, arrival_on, departure_on, status,
             cash_paid_cents, credit_paid_cents
      FROM groups
      """).rows

    Enum.each(groups, fn [
                           group_id,
                           rate_plan,
                           arrival_on,
                           departure_on,
                           status,
                           cash_total,
                           credit_total
                         ] ->
      nights = Date.diff(Date.from_iso8601!(departure_on), Date.from_iso8601!(arrival_on))

      rooms =
        repo().query!(
          """
          SELECT id, room_id, nightly_rate_cents
          FROM group_rooms
          WHERE group_id = ?
          ORDER BY room_index, id
          """,
          [group_id]
        ).rows

      {room_states, cash_left} =
        Enum.map_reduce(rooms, cash_total, fn [room_row_id, room_id, nightly_rate], cash_left ->
          lodging = nights * nightly_rate
          due = if rate_plan == "advance_purchase", do: lodging, else: div(lodging * 20 + 50, 100)
          cash = min(cash_left, due)

          repo().query!(
            """
            UPDATE group_rooms
            SET lodging_total_cents = ?, deposit_due_cents = ?, status = ?,
                cash_paid_cents = ?
            WHERE id = ?
            """,
            [lodging, due, status, cash, room_row_id]
          )

          if status == "active" and cash > 0 do
            repo().query!(
              """
              INSERT INTO room_funding_allocations
                (group_id, room_id, funding_type, source_type, amount_cents)
              VALUES (?, ?, 'cash', 'legacy_cash', ?)
              """,
              [group_id, room_id, cash]
            )
          end

          {%{row_id: room_row_id, room_id: room_id, capacity: due - cash, credit: 0},
           cash_left - cash}
        end)

      applications =
        if status == "active" do
          repo().query!(
            """
            SELECT id, amount_cents
            FROM hotel_credit_applications
            WHERE group_id = ?
            ORDER BY id
            """,
            [group_id]
          ).rows
        else
          []
        end

      {credit_left, room_states} =
        Enum.reduce(applications, {credit_total, room_states}, fn [application_id, amount],
                                                                  {credit_left, states} ->
          {remaining, states} =
            allocate_legacy_credit_application(group_id, application_id, amount, states)

          {credit_left - (amount - remaining), states}
        end)

      {credit_left, room_states} =
        if status == "active" do
          allocate_legacy_credit_application(group_id, nil, credit_left, room_states)
        else
          {0, room_states}
        end

      Enum.each(room_states, fn state ->
        repo().query!(
          "UPDATE group_rooms SET credit_paid_cents = ? WHERE id = ?",
          [state.credit, state.row_id]
        )
      end)

      _ = cash_left
      _ = credit_left
    end)
  end

  defp allocate_legacy_credit_application(_group_id, _application_id, 0, states), do: {0, states}

  defp allocate_legacy_credit_application(group_id, application_id, amount, states) do
    {states, remaining} =
      Enum.map_reduce(states, amount, fn state, remaining ->
        allocated = min(remaining, state.capacity)

        next_state = %{
          state
          | capacity: state.capacity - allocated,
            credit: state.credit + allocated
        }

        if allocated > 0 do
          repo().query!(
            """
            INSERT INTO room_funding_allocations
              (group_id, room_id, funding_type, source_type, source_id,
               credit_application_id, amount_cents)
            VALUES (?, ?, 'credit', 'legacy_credit', ?, ?, ?)
            """,
            [
              group_id,
              state.room_id,
              to_string(application_id || "legacy"),
              application_id,
              allocated
            ]
          )
        end

        {next_state, remaining - allocated}
      end)

    {remaining, states}
  end
end
