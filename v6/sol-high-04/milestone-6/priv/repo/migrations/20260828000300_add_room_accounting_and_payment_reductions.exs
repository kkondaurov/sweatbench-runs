defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_fundings) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false

      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :kind, :string, null: false
      add :payment_operation_id, :string
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict)
      add :amount_cents, :integer, null: false
      add :funding_order, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create table(:payment_accountings, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
      add :original_group_id, :string, null: false
      add :recorded_cents, :integer, null: false
      add :funding_order, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0
      add :funding_order, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:room_fundings, [:group_id, :room_id])
    create index(:room_fundings, [:payment_operation_id])
    create index(:room_fundings, [:credit_lot_id])
    create index(:payment_accountings, [:original_group_id])
    create index(:credit_entitlements, [:payment_operation_id])
    create index(:credit_entitlements, [:credit_lot_id])

    flush()
    backfill_rooms_and_funding()
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:payment_accountings)
    drop table(:room_fundings)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:groups) do
      remove :cash_reduced_cents
      remove :cash_charged_back_cents
    end

    alter table(:rooms) do
      remove :status
      remove :lodging_total_cents
      remove :deposit_due_cents
      remove :cash_paid_cents
      remove :credit_paid_cents
    end
  end

  # This release is the first one that can identify room-level funding. Reconstruct the senior
  # unattributed block first, then replay durable funding in partner-operation commit order.
  defp backfill_rooms_and_funding do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    groups =
      rows(
        "SELECT group_id, status, arrival_on, departure_on, rate_plan, cash_paid_cents, credit_paid_cents, cash_refunded_cents, cash_retained_cents, cash_converted_to_credit_cents FROM groups ORDER BY group_id"
      )

    operations =
      rows("SELECT id, operation_id, operation_type, result FROM partner_operations ORDER BY id")
      |> Enum.map(fn [id, operation_id, type, result] ->
        decoded = decode_json(result)
        %{id: id, operation_id: operation_id, type: type, result: decoded}
      end)

    Enum.each(groups, fn [
                           group_id,
                           status,
                           arrival,
                           departure,
                           rate_plan,
                           cash_paid,
                           credit_paid,
                           refunded,
                           retained,
                           converted
                         ] ->
      rooms =
        rows("SELECT id, nightly_rate_cents FROM rooms WHERE group_id = ? ORDER BY position", [
          group_id
        ])
        |> Enum.map(fn [id, rate] ->
          lodging = rate * date_diff(departure, arrival)
          due = if rate_plan == "advance_purchase", do: lodging, else: div(lodging * 20 + 50, 100)
          room_status = if status == "active", do: "active", else: "cancelled"

          query!(
            "UPDATE rooms SET status = ?, lodging_total_cents = ?, deposit_due_cents = ? WHERE id = ?",
            [room_status, lodging, due, id]
          )

          %{id: id, due: due, cash: 0, credit: 0}
        end)

      group_ops =
        Enum.filter(
          operations,
          &(&1.result["group_id"] == group_id and &1.result["status"] == "applied")
        )

      cash_ops = Enum.filter(group_ops, &(&1.type == "record_cash_payment"))
      credit_ops = Enum.filter(group_ops, &(&1.type == "apply_hotel_credit"))

      payment_dispositions(
        group_id,
        status,
        cash_paid,
        refunded,
        retained,
        converted,
        cash_ops,
        now
      )

      if status == "active" do
        legacy_cash =
          max(cash_paid - Enum.sum(Enum.map(cash_ops, & &1.result["amount_cents"])), 0)

        legacy_credit =
          max(credit_paid - Enum.sum(Enum.map(credit_ops, & &1.result["amount_cents"])), 0)

        credit_stream = credit_stream(group_id)
        {legacy_credit_chunks, durable_credit_stream} = take_stream(credit_stream, legacy_credit)

        events =
          if(legacy_cash > 0,
            do: [%{order: 0, kind: "cash", amount: legacy_cash, payment: nil}],
            else: []
          ) ++
            Enum.map(legacy_credit_chunks, fn {lot_id, amount} ->
              %{order: 0, kind: "credit", amount: amount, lot_id: lot_id}
            end) ++
            durable_events(group_ops, durable_credit_stream)

        funded_rooms = Enum.reduce(events, rooms, &allocate_event(&1, &2, group_id, now))

        Enum.each(funded_rooms, fn room ->
          query!("UPDATE rooms SET cash_paid_cents = ?, credit_paid_cents = ? WHERE id = ?", [
            room.cash,
            room.credit,
            room.id
          ])
        end)
      else
        query!(
          "UPDATE groups SET lodging_total_cents = 0, deposit_due_cents = 0, deposit_paid_cents = 0, cash_paid_cents = 0, credit_paid_cents = 0 WHERE group_id = ?",
          [group_id]
        )
      end
    end)

    backfill_entitlements(operations, now)
  end

  defp durable_events(group_ops, credit_stream) do
    {events, _stream} =
      Enum.reduce(group_ops, {[], credit_stream}, fn operation, {events, stream} ->
        case operation.type do
          "record_cash_payment" ->
            event = %{
              order: operation.id,
              kind: "cash",
              amount: operation.result["amount_cents"],
              payment: operation.operation_id
            }

            {events ++ [event], stream}

          "apply_hotel_credit" ->
            {chunks, rest} = take_stream(stream, operation.result["amount_cents"])

            new_events =
              Enum.map(chunks, fn {lot_id, amount} ->
                %{order: operation.id, kind: "credit", amount: amount, lot_id: lot_id}
              end)

            {events ++ new_events, rest}

          _ ->
            {events, stream}
        end
      end)

    events
  end

  defp allocate_event(event, rooms, group_id, now) do
    {_remaining, reversed} =
      Enum.reduce(rooms, {event.amount, []}, fn room, {remaining, acc} ->
        capacity = max(room.due - room.cash - room.credit, 0)
        used = min(capacity, remaining)

        if used > 0 do
          query!(
            "INSERT INTO room_fundings (room_id, group_id, kind, payment_operation_id, credit_lot_id, amount_cents, funding_order, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
              room.id,
              group_id,
              event.kind,
              Map.get(event, :payment),
              Map.get(event, :lot_id),
              used,
              event.order,
              now,
              now
            ]
          )
        end

        updated =
          if event.kind == "cash",
            do: %{room | cash: room.cash + used},
            else: %{room | credit: room.credit + used}

        {remaining - used, [updated | acc]}
      end)

    Enum.reverse(reversed)
  end

  defp payment_dispositions(
         group_id,
         status,
         cash_paid,
         refunded,
         retained,
         converted,
         cash_ops,
         now
       ) do
    durable_total = Enum.sum(Enum.map(cash_ops, & &1.result["amount_cents"]))
    legacy = max(cash_paid - durable_total, 0)

    buckets =
      if status == "active",
        do: [{:held, cash_paid}],
        else: [{:refunded, refunded}, {:retained, retained}, {:converted, converted}]

    Enum.reduce(cash_ops, {elem(consume_buckets(buckets, legacy), 0), legacy}, fn operation,
                                                                                  {remaining_buckets,
                                                                                   offset} ->
      amount = operation.result["amount_cents"]
      {parts, next_buckets} = disposition_parts(remaining_buckets, amount)
      values = Map.merge(%{held: 0, refunded: 0, retained: 0, converted: 0}, parts)

      query!(
        "INSERT INTO payment_accountings (payment_operation_id, original_group_id, recorded_cents, funding_order, held_cents, refunded_cents, retained_cents, converted_to_credit_cents, reduced_cents, charged_back_cents, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?)",
        [
          operation.operation_id,
          group_id,
          amount,
          operation.id,
          values.held,
          values.refunded,
          values.retained,
          values.converted,
          now,
          now
        ]
      )

      {next_buckets, offset + amount}
    end)
  end

  defp disposition_parts(buckets, amount), do: disposition_parts(buckets, amount, %{})
  defp disposition_parts(buckets, 0, parts), do: {parts, buckets}
  defp disposition_parts([], _amount, parts), do: {parts, []}

  defp disposition_parts([{kind, available} | rest], amount, parts) do
    used = min(available, amount)
    next = if used == available, do: rest, else: [{kind, available - used} | rest]
    disposition_parts(next, amount - used, Map.update(parts, kind, used, &(&1 + used)))
  end

  defp consume_buckets(buckets, amount) do
    {_parts, remaining} = disposition_parts(buckets, amount)
    {remaining, amount}
  end

  defp credit_stream(group_id) do
    rows(
      "SELECT credit_lot_id, amount_cents FROM credit_applications WHERE group_id = ? ORDER BY id",
      [group_id]
    )
    |> Enum.map(fn [lot_id, amount] -> {lot_id, amount} end)
  end

  defp take_stream(stream, amount), do: take_stream(stream, amount, [])
  defp take_stream(stream, 0, acc), do: {Enum.reverse(acc), stream}
  defp take_stream([], _amount, acc), do: {Enum.reverse(acc), []}

  defp take_stream([{lot_id, available} | rest], amount, acc) do
    used = min(available, amount)
    next = if used == available, do: rest, else: [{lot_id, available - used} | rest]
    take_stream(next, amount - used, [{lot_id, used} | acc])
  end

  defp backfill_entitlements(operations, now) do
    rows("SELECT id, source_operation_id FROM credit_lots ORDER BY id")
    |> Enum.each(fn [lot_id, source_operation_id] ->
      with operation when not is_nil(operation) <-
             Enum.find(operations, &(&1.operation_id == source_operation_id)),
           group_id when is_binary(group_id) <- operation.result["group_id"] do
        contributors =
          rows(
            "SELECT payment_operation_id, converted_to_credit_cents FROM payment_accountings WHERE original_group_id = ? AND converted_to_credit_cents > 0 ORDER BY funding_order",
            [group_id]
          )

        converted =
          rows("SELECT cash_converted_to_credit_cents FROM groups WHERE group_id = ?", [group_id])
          |> List.first()
          |> List.first()

        durable = Enum.sum(Enum.map(contributors, fn [_id, amount] -> amount end))
        all = if(converted > durable, do: [[nil, converted - durable]], else: []) ++ contributors

        Enum.reduce(Enum.with_index(all), 0, fn {[payment_id, principal], index}, running ->
          next = running + principal
          entitlement = bonus_value(next) - bonus_value(running)

          query!(
            "INSERT INTO credit_entitlements (credit_lot_id, payment_operation_id, principal_cents, entitlement_cents, revoked_cents, funding_order, inserted_at, updated_at) VALUES (?, ?, ?, ?, 0, ?, ?, ?)",
            [lot_id, payment_id, principal, entitlement, index, now, now]
          )

          next
        end)
      else
        _ -> :ok
      end
    end)
  end

  defp bonus_value(principal), do: principal + div(principal * 10 + 50, 100)

  defp date_diff(departure, arrival) do
    Date.diff(to_date(departure), to_date(arrival))
  end

  defp to_date(%Date{} = date), do: date
  defp to_date(value), do: Date.from_iso8601!(value)

  defp decode_json(value) when is_map(value), do: value
  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)

  defp rows(sql, params \\ []), do: query!(sql, params).rows
  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(repo(), sql, params)
end
