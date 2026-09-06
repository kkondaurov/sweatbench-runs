defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string,
        null: false,
        default: "active",
        check: %{name: "rooms_valid_status", expr: "status IN ('active', 'cancelled')"}

      add :lodging_total_cents, :integer,
        null: false,
        default: 0,
        check: %{name: "rooms_nonnegative_lodging", expr: "lodging_total_cents >= 0"}

      add :deposit_due_cents, :integer,
        null: false,
        default: 0,
        check: %{name: "rooms_nonnegative_deposit_due", expr: "deposit_due_cents >= 0"}

      add :cash_paid_cents, :integer,
        null: false,
        default: 0,
        check: %{name: "rooms_nonnegative_cash_paid", expr: "cash_paid_cents >= 0"}

      add :credit_paid_cents, :integer,
        null: false,
        default: 0,
        check: %{name: "rooms_nonnegative_credit_paid", expr: "credit_paid_cents >= 0"}
    end

    alter table(:groups) do
      add :cash_reduced_cents, :integer,
        null: false,
        default: 0,
        check: %{name: "groups_nonnegative_cash_reduced", expr: "cash_reduced_cents >= 0"}

      add :cash_charged_back_cents, :integer,
        null: false,
        default: 0,
        check: %{
          name: "groups_nonnegative_cash_charged_back",
          expr: "cash_charged_back_cents >= 0"
        }
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer,
        null: false,
        default: 0,
        check: %{
          name: "credit_lots_nonnegative_clawback",
          expr: "unrecovered_clawback_cents >= 0"
        }
    end

    alter table(:credit_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all)
    end

    create index(:credit_allocations, [:room_id])

    create table(:cash_payments, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true

      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :restrict),
          null: false

      add :recorded_cents, :integer,
        null: false,
        check: %{name: "cash_payments_positive_recorded", expr: "recorded_cents > 0"}

      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create index(:cash_payments, [:group_id])

    create table(:cash_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false

      add :payment_operation_id,
          references(:cash_payments, column: :payment_operation_id, type: :string)

      add :amount_cents, :integer,
        null: false,
        check: %{name: "cash_allocations_positive_amount", expr: "amount_cents > 0"}
    end

    create index(:cash_allocations, [:room_id])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false

      add :payment_operation_id,
          references(:cash_payments, column: :payment_operation_id, type: :string)

      add :amount_cents, :integer,
        null: false,
        check: %{name: "credit_entitlements_positive_amount", expr: "amount_cents > 0"}

      add :revoked, :boolean, null: false, default: false
    end

    create index(:credit_entitlements, [:credit_lot_id])
    create index(:credit_entitlements, [:payment_operation_id])

    flush()
    backfill()
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:cash_allocations)
    drop table(:cash_payments)
    drop index(:credit_allocations, [:room_id])

    alter table(:credit_allocations), do: remove(:room_id)
    alter table(:credit_lots), do: remove(:unrecovered_clawback_cents)

    alter table(:groups) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end

    alter table(:rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end

  defp backfill do
    repository = repo()

    groups =
      repository.query!(
        "SELECT group_id, arrival_on, departure_on, rate_plan, status, cash_held_cents, credit_paid_cents, cash_refunded_cents, cash_retained_cents, cash_converted_to_credit_cents FROM groups ORDER BY group_id",
        []
      ).rows

    Enum.each(groups, fn [
                           group_id,
                           arrival,
                           departure,
                           rate_plan,
                           status,
                           held,
                           credit_paid,
                           refunded,
                           retained,
                           converted
                         ] ->
      nights = Date.diff(Date.from_iso8601!(departure), Date.from_iso8601!(arrival))

      rooms =
        repository.query!(
          "SELECT id, nightly_rate_cents FROM rooms WHERE group_id = ? ORDER BY position",
          [group_id]
        ).rows

      Enum.each(rooms, fn [room_id, rate] ->
        lodging = nights * rate
        due = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging
        room_status = if status == "active", do: "active", else: "cancelled"

        repository.query!(
          "UPDATE rooms SET status = ?, lodging_total_cents = ?, deposit_due_cents = ? WHERE id = ?",
          [room_status, lodging, due, room_id]
        )
      end)

      payments = durable_funding(repository, group_id, "record_cash_payment")

      Enum.each(payments, fn {operation_id, amount, _commit_id} ->
        {pheld, prefunded, pretained, pconverted} =
          payment_disposition(
            amount,
            status,
            held,
            refunded,
            retained,
            converted,
            payments,
            operation_id
          )

        repository.query!(
          "INSERT INTO cash_payments (payment_operation_id, group_id, recorded_cents, held_cents, refunded_cents, retained_cents, converted_to_credit_cents) VALUES (?, ?, ?, ?, ?, ?, ?)",
          [operation_id, group_id, amount, pheld, prefunded, pretained, pconverted]
        )
      end)

      if status == "active" do
        durable_cash = Enum.sum(Enum.map(payments, &elem(&1, 1)))
        durable_credit_ops = durable_funding(repository, group_id, "apply_hotel_credit")
        durable_credit = Enum.sum(Enum.map(durable_credit_ops, &elem(&1, 1)))

        funding =
          [
            {:cash, nil, max(held - durable_cash, 0)},
            {:credit, nil, max(credit_paid - durable_credit, 0)}
          ] ++
            Enum.sort_by(
              Enum.map(payments, fn {id, amount, commit} -> {:cash, id, amount, commit} end) ++
                Enum.map(durable_credit_ops, fn {id, amount, commit} ->
                  {:credit, id, amount, commit}
                end),
              &elem(&1, 3)
            )

        allocate_funding(repository, rooms, group_id, funding)
      end
    end)

    backfill_entitlements(repository)
  end

  defp durable_funding(repository, group_id, type) do
    repository.query!(
      "SELECT id, operation_id, result FROM partner_operations WHERE operation_type = ? ORDER BY id",
      [type]
    ).rows
    |> Enum.flat_map(fn [id, operation_id, raw_result] ->
      result = decode_json(raw_result)

      if result["status"] == "applied" and result["group_id"] == group_id,
        do: [{operation_id, result["amount_cents"], id}],
        else: []
    end)
  end

  defp decode_json(value) when is_map(value), do: value
  defp decode_json(value), do: Jason.decode!(value)

  defp payment_disposition(
         amount,
         "active",
         _held,
         _refunded,
         _retained,
         _converted,
         _payments,
         _id
       ),
       do: {amount, 0, 0, 0}

  defp payment_disposition(amount, _status, held, refunded, retained, converted, payments, id) do
    legacy =
      max(held + refunded + retained + converted - Enum.sum(Enum.map(payments, &elem(&1, 1))), 0)

    preceding =
      legacy +
        (payments
         |> Enum.take_while(&(elem(&1, 0) != id))
         |> Enum.map(&elem(&1, 1))
         |> Enum.sum())

    {
      overlap(preceding, amount, 0, held),
      overlap(preceding, amount, held, refunded),
      overlap(preceding, amount, held + refunded, retained),
      overlap(preceding, amount, held + refunded + retained, converted)
    }
  end

  defp overlap(start, amount, bucket_start, bucket_size) do
    max(min(start + amount, bucket_start + bucket_size) - max(start, bucket_start), 0)
  end

  defp allocate_funding(repository, rooms, group_id, funding) do
    dues = Enum.map(rooms, fn [id, rate] -> {id, rate, room_due(repository, id)} end)

    credit_rows =
      repository.query!(
        "SELECT id, credit_lot_id, amount_cents FROM credit_allocations WHERE group_id = ? ORDER BY id",
        [group_id]
      ).rows

    repository.query!("DELETE FROM credit_allocations WHERE group_id = ?", [group_id])

    {_room_paid, _credit_rows} =
      Enum.reduce(funding, {%{}, credit_rows}, fn entry, {paid, lot_rows} ->
        {kind, source, amount} = funding_entry(entry)

        {paid, lot_rows} =
          allocate_one(repository, dues, paid, lot_rows, kind, source, amount, group_id)

        {paid, lot_rows}
      end)
  end

  defp funding_entry({kind, source, amount}), do: {kind, source, amount}
  defp funding_entry({kind, source, amount, _commit}), do: {kind, source, amount}

  defp room_due(repository, id),
    do:
      repository.query!("SELECT deposit_due_cents FROM rooms WHERE id = ?", [id]).rows
      |> hd()
      |> hd()

  defp allocate_one(repository, dues, paid, lot_rows, kind, source, amount, group_id) do
    Enum.reduce_while(dues, {amount, paid, lot_rows}, fn {room_id, _rate, due},
                                                         {left, paid, lots} ->
      capacity = due - Map.get(paid, room_id, 0)
      take = min(left, max(capacity, 0))

      lots =
        if take > 0 do
          case kind do
            :cash ->
              repository.query!(
                "INSERT INTO cash_allocations (room_id, payment_operation_id, amount_cents) VALUES (?, ?, ?)",
                [room_id, source, take]
              )

              lots

            :credit ->
              {remaining_lots, 0} =
                insert_credit_chunks(repository, lots, room_id, group_id, take)

              remaining_lots
          end
        else
          lots
        end

      if take > 0 do
        field = if kind == :cash, do: "cash_paid_cents", else: "credit_paid_cents"

        repository.query!("UPDATE rooms SET #{field} = #{field} + ? WHERE id = ?", [take, room_id])
      end

      state = {left - take, Map.update(paid, room_id, take, &(&1 + take)), lots}
      if left - take == 0, do: {:halt, state}, else: {:cont, state}
    end)
    |> then(fn {_left, next_paid, next_lots} -> {next_paid, next_lots} end)
  end

  defp insert_credit_chunks(repository, rows, room_id, group_id, amount) do
    do_insert_credit_chunks(repository, rows, room_id, group_id, amount)
  end

  defp do_insert_credit_chunks(_repository, rows, _room_id, _group_id, 0), do: {rows, 0}
  defp do_insert_credit_chunks(_repository, [], _room_id, _group_id, amount), do: {[], amount}

  defp do_insert_credit_chunks(
         repository,
         [[allocation_id, lot_id, available] | rest],
         room_id,
         group_id,
         amount
       ) do
    take = min(available, amount)

    repository.query!(
      "INSERT INTO credit_allocations (group_id, credit_lot_id, room_id, amount_cents) VALUES (?, ?, ?, ?)",
      [group_id, lot_id, room_id, take]
    )

    rows =
      if take == available,
        do: rest,
        else: [[allocation_id, lot_id, available - take] | rest]

    do_insert_credit_chunks(repository, rows, room_id, group_id, amount - take)
  end

  defp backfill_entitlements(repository) do
    lots =
      repository.query!("SELECT id, source_operation_id FROM credit_lots ORDER BY id", []).rows

    Enum.each(lots, fn [lot_id, source_id] ->
      case repository.query!(
             "SELECT submitted_payload FROM partner_operations WHERE operation_id = ? AND operation_type = 'cancel_group'",
             [source_id]
           ).rows do
        [[payload]] ->
          group_id = decode_json(payload)["group_id"]

          payments =
            repository.query!(
              "SELECT payment_operation_id, converted_to_credit_cents FROM cash_payments WHERE group_id = ? AND converted_to_credit_cents > 0 ORDER BY rowid",
              [group_id]
            ).rows

          total =
            repository.query!(
              "SELECT cash_converted_to_credit_cents FROM groups WHERE group_id = ?",
              [group_id]
            ).rows
            |> hd()
            |> hd()

          legacy = max(total - Enum.sum(Enum.map(payments, &Enum.at(&1, 1))), 0)

          contributions =
            [{nil, legacy} | Enum.map(payments, fn [id, amount] -> {id, amount} end)]
            |> Enum.reject(&(elem(&1, 1) == 0))

          Enum.reduce(contributions, 0, fn {payment_id, principal}, running ->
            entitlement = credit_value(running + principal) - credit_value(running)

            repository.query!(
              "INSERT INTO credit_entitlements (credit_lot_id, payment_operation_id, amount_cents, revoked) VALUES (?, ?, ?, 0)",
              [lot_id, payment_id, entitlement]
            )

            running + principal
          end)

        _ ->
          :ok
      end
    end)
  end

  defp credit_value(cash), do: cash + div(cash * 10 + 50, 100)
end
