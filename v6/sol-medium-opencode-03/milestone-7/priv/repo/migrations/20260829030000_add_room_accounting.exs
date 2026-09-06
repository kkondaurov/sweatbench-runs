defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
    end

    execute """
    UPDATE rooms
    SET status = (SELECT status FROM groups WHERE groups.id = rooms.group_record_id),
        lodging_total_cents = nightly_rate_cents * CAST(
          julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_record_id)) -
          julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_record_id)) AS INTEGER
        )
    """

    execute """
    UPDATE rooms
    SET deposit_due_cents = CASE
      WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_record_id) = 'flexible'
        THEN CAST((lodging_total_cents * 20 + 50) / 100 AS INTEGER)
      ELSE lodging_total_cents
    END
    """

    create table(:cash_payments) do
      add :payment_operation_id, :string, null: false
      add :group_record_id, references(:groups, on_delete: :delete_all), null: false
      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payments, [:payment_operation_id])
    create index(:cash_payments, [:group_record_id])

    create table(:cash_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :cash_payment_id, references(:cash_payments, on_delete: :delete_all)
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:room_id])
    create index(:cash_allocations, [:cash_payment_id])

    alter table(:credit_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all)
      add :funding_operation_id, :string
    end

    create index(:credit_allocations, [:room_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :cash_payment_id, references(:cash_payments, on_delete: :delete_all)
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
      add :revoked_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:credit_lot_id])
    create index(:credit_entitlements, [:cash_payment_id])

    flush()
    backfill_existing_accounting()
  end

  def down do
    drop table(:credit_entitlements)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    drop index(:credit_allocations, [:room_id])

    alter table(:credit_allocations) do
      remove :room_id
      remove :funding_operation_id
    end

    drop table(:cash_allocations)
    drop table(:cash_payments)

    alter table(:rooms) do
      remove :status
      remove :lodging_total_cents
      remove :deposit_due_cents
    end
  end

  defp backfill_existing_accounting do
    repo = repo()
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    operations =
      rows(
        repo,
        "SELECT id, operation_id, operation_type, result FROM operation_records ORDER BY id"
      )
      |> Enum.map(fn [id, operation_id, type, result] ->
        %{id: id, operation_id: operation_id, type: type, result: decode_json(result)}
      end)

    old_credit =
      rows(
        repo,
        "SELECT group_record_id, credit_lot_id, amount_cents FROM credit_allocations ORDER BY id"
      )

    repo.query!("DELETE FROM credit_allocations", [])

    groups =
      rows(
        repo,
        """
        SELECT id, group_id, status, cash_paid_cents, credit_paid_cents,
               refunded_cents, retained_cents, cash_converted_to_credit_cents
        FROM groups ORDER BY id
        """
      )

    Enum.each(groups, fn [
                           group_id,
                           partner_id,
                           status,
                           cash,
                           credit,
                           refunded,
                           retained,
                           converted
                         ] ->
      funding =
        Enum.filter(operations, fn operation ->
          operation.result["status"] == "applied" and operation.result["group_id"] == partner_id and
            operation.type in ["record_cash_payment", "apply_hotel_credit"]
        end)

      payments =
        funding
        |> Enum.filter(&(&1.type == "record_cash_payment"))
        |> Enum.map(fn operation ->
          amount = operation.result["amount_cents"]

          payment_id =
            insert_returning_id(
              repo,
              """
              INSERT INTO cash_payments
                (payment_operation_id, group_record_id, recorded_cents, inserted_at, updated_at)
              VALUES (?, ?, ?, ?, ?) RETURNING id
              """,
              [operation.operation_id, group_id, amount, now, now]
            )

          {operation.id, %{id: payment_id, operation_id: operation.operation_id, amount: amount}}
        end)
        |> Map.new()

      durable_cash = payments |> Map.values() |> Enum.sum_by(& &1.amount)

      durable_credit =
        funding
        |> Enum.filter(&(&1.type == "apply_hotel_credit"))
        |> Enum.sum_by(& &1.result["amount_cents"])

      legacy_cash = cash - durable_cash
      legacy_credit = credit - durable_credit

      if legacy_cash < 0 or legacy_credit < 0 do
        raise "durable funding exceeds stored group totals for #{partner_id}"
      end

      if status == "active" do
        credit_stream =
          old_credit
          |> Enum.filter(fn [allocation_group_id, _, _] -> allocation_group_id == group_id end)
          |> Enum.map(fn [_, lot_id, amount] -> {lot_id, amount} end)

        {legacy_credit_chunks, credit_stream} = take_credit(credit_stream, legacy_credit)

        {events, remaining_credit} =
          Enum.reduce(
            funding,
            {legacy_events(legacy_cash, legacy_credit_chunks), credit_stream},
            fn
              %{type: "record_cash_payment", id: operation_id}, {events, stream} ->
                payment = Map.fetch!(payments, operation_id)
                {events ++ [{:cash, payment.id, payment.amount}], stream}

              %{type: "apply_hotel_credit"} = operation, {events, stream} ->
                {chunks, stream} = take_credit(stream, operation.result["amount_cents"])

                {events ++
                   Enum.map(chunks, fn {lot_id, amount} ->
                     {:credit, lot_id, operation.operation_id, amount}
                   end), stream}
            end
          )

        if remaining_credit != [], do: raise("unmatched credit allocations for #{partner_id}")
        allocate_events(repo, group_id, events, now)
      else
        backfill_settled_payments(repo, payments, refunded, retained, converted, now)
        backfill_entitlements(repo, operations, partner_id, legacy_cash, payments, converted, now)
      end
    end)
  end

  defp legacy_events(cash, credit_chunks) do
    cash_events = if cash > 0, do: [{:cash, nil, cash}], else: []

    cash_events ++
      Enum.map(credit_chunks, fn {lot_id, amount} -> {:credit, lot_id, nil, amount} end)
  end

  defp allocate_events(repo, group_id, events, now) do
    rooms =
      rows(
        repo,
        "SELECT id, deposit_due_cents FROM rooms WHERE group_record_id = ? AND status = 'active' ORDER BY position",
        [group_id]
      )
      |> Enum.map(fn [id, due] -> %{id: id, remaining: due} end)

    Enum.reduce(events, rooms, fn event, rooms -> allocate_event(repo, rooms, event, now) end)
  end

  defp allocate_event(repo, rooms, event, now) do
    amount = elem(event, tuple_size(event) - 1)

    {rooms, remaining} =
      Enum.map_reduce(rooms, amount, fn room, left ->
        used = min(room.remaining, left)

        if used > 0 do
          case event do
            {:cash, payment_id, _} ->
              repo.query!(
                "INSERT INTO cash_allocations (room_id, cash_payment_id, amount_cents, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                [room.id, payment_id, used, now, now]
              )

            {:credit, lot_id, operation_id, _} ->
              repo.query!(
                "INSERT INTO credit_allocations (credit_lot_id, group_record_id, room_id, funding_operation_id, amount_cents, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [lot_id, group_id_for_room(repo, room.id), room.id, operation_id, used, now, now]
              )
          end
        end

        {%{room | remaining: room.remaining - used}, left - used}
      end)

    if remaining != 0, do: raise("funding exceeds room capacity during accounting backfill")
    rooms
  end

  defp backfill_settled_payments(repo, payments, refunded, retained, converted, now) do
    field =
      cond do
        refunded > 0 -> "refunded_cents"
        retained > 0 -> "retained_cents"
        converted > 0 -> "converted_to_credit_cents"
        true -> nil
      end

    if field do
      Enum.each(payments, fn {_operation_id, payment} ->
        repo.query!("UPDATE cash_payments SET #{field} = ?, updated_at = ? WHERE id = ?", [
          payment.amount,
          now,
          payment.id
        ])
      end)
    end
  end

  defp backfill_entitlements(_repo, _operations, _group_id, _legacy, _payments, 0, _now), do: :ok

  defp backfill_entitlements(repo, operations, group_id, legacy, payments, converted, now) do
    cancellation =
      Enum.find(operations, fn operation ->
        operation.type == "cancel_group" and operation.result["status"] == "applied" and
          operation.result["group_id"] == group_id and operation.result["credit_issued_cents"] > 0
      end)

    if cancellation do
      [[lot_id]] =
        rows(repo, "SELECT id FROM credit_lots WHERE source_operation_id = ?", [
          cancellation.operation_id
        ])

      contributions =
        if(legacy > 0, do: [{nil, legacy}], else: []) ++
          (payments
           |> Enum.sort_by(&elem(&1, 0))
           |> Enum.map(fn {_, payment} -> {payment.id, payment.amount} end))

      total = Enum.sum_by(contributions, &elem(&1, 1))
      if total != converted, do: raise("converted cash provenance mismatch for #{group_id}")

      Enum.reduce(contributions, 0, fn {payment_id, principal}, preceding ->
        cumulative = preceding + principal
        entitlement = bonus_value(cumulative) - bonus_value(preceding)

        repo.query!(
          "INSERT INTO credit_entitlements (credit_lot_id, cash_payment_id, principal_cents, entitlement_cents, revoked_cents, inserted_at, updated_at) VALUES (?, ?, ?, ?, 0, ?, ?)",
          [lot_id, payment_id, principal, entitlement, now, now]
        )

        cumulative
      end)
    end
  end

  defp take_credit(stream, amount), do: take_credit(stream, amount, [])
  defp take_credit(stream, 0, taken), do: {Enum.reverse(taken), stream}

  defp take_credit([], amount, _taken),
    do: raise("missing #{amount} cents of legacy credit allocation")

  defp take_credit([{lot_id, available} | rest], amount, taken) do
    used = min(available, amount)
    rest = if used == available, do: rest, else: [{lot_id, available - used} | rest]
    take_credit(rest, amount - used, [{lot_id, used} | taken])
  end

  defp group_id_for_room(repo, room_id) do
    [[group_id]] = rows(repo, "SELECT group_record_id FROM rooms WHERE id = ?", [room_id])
    group_id
  end

  defp bonus_value(principal), do: principal + div(principal * 10 + 50, 100)
  defp insert_returning_id(repo, sql, params), do: repo.query!(sql, params).rows |> hd() |> hd()
  defp rows(repo, sql, params \\ []), do: repo.query!(sql, params).rows
  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
  defp decode_json(value) when is_map(value), do: value
end
