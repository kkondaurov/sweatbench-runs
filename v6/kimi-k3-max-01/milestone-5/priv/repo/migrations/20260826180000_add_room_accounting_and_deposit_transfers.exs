defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndDepositTransfers do
  use Ecto.Migration

  alias GroupStay.Repo

  # Room-level accounting, payment dispositions, and credit entitlements.
  #
  # Existing funding is brought forward without changing any aggregate cash,
  # credit, or liability balance: funding not explained by durable operation
  # records becomes one unattributed senior block per group (aggregate cash
  # first, then hotel-credit lots in original consumption order); funding
  # represented by durable operation records is classified by the retained
  # operation type and allocated afterward in durable-record commit order.

  def up do
    alter table(:group_rooms) do
      add :status, :string, null: false, default: "active"
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    create table(:room_allocations) do
      add :room_id, references(:group_rooms, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      # Null for cash from the unattributed senior block.
      add :payment_operation_id, :string
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all)
      add :transferred, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:room_allocations, [:group_id])
    create index(:room_allocations, [:room_id])
    create index(:room_allocations, [:payment_operation_id])
    create index(:room_allocations, [:credit_lot_id])

    create table(:payment_dispositions) do
      add :payment_operation_id, :string, null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :participated_in_transfer, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payment_dispositions, [:payment_operation_id, :kind])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      # Null for the unattributed senior block.
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :unrecovered_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:credit_lot_id])

    # Migration commands are queued and flushed in order; the backfill below
    # queries the new tables directly, so they must exist first.
    flush()

    backfill()

    drop table(:credit_applications)
  end

  def down do
    create table(:credit_applications) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_applications, [:credit_lot_id])
    create index(:credit_applications, [:group_id])

    drop table(:credit_entitlements)
    drop table(:payment_dispositions)
    drop table(:room_allocations)

    alter table(:group_rooms) do
      remove :status
      remove :deposit_due_cents
      remove :cash_paid_cents
      remove :credit_paid_cents
    end
  end

  ## Backfill

  defp backfill do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_naive()
    records = operation_records()

    for group <- rows("SELECT * FROM groups ORDER BY id") do
      rooms =
        rows("SELECT * FROM group_rooms WHERE group_id = ? ORDER BY position", [group["id"]])

      nights = Date.diff(from_iso8601(group["departure_on"]), from_iso8601(group["arrival_on"]))

      for room <- rooms do
        lodging = room["nightly_rate_cents"] * nights

        due =
          if group["rate_plan"] == "flexible",
            do: round_half_up(lodging * 20, 100),
            else: lodging

        exec_sql("UPDATE group_rooms SET deposit_due_cents = ? WHERE id = ?", [due, room["id"]])
      end

      # The due values just written are needed to allocate funding below.
      rooms =
        rows("SELECT * FROM group_rooms WHERE group_id = ? ORDER BY position", [group["id"]])

      if group["deposit_paid_cents"] > 0 do
        payments = recorded_funding(records, group["group_id"], "record_cash_payment")
        credit_ops = recorded_funding(records, group["group_id"], "apply_hotel_credit")
        legacy_cash = max(group["cash_paid_cents"] - sum_amounts(payments), 0)
        legacy_credit = max(group["credit_paid_cents"] - sum_amounts(credit_ops), 0)

        applications =
          rows("SELECT * FROM credit_applications WHERE group_id = ? ORDER BY id", [group["id"]])

        if group["status"] == "active" do
          backfill_active(
            group,
            rooms,
            payments,
            credit_ops,
            legacy_cash,
            legacy_credit,
            applications,
            now
          )
        else
          backfill_cancelled(group, payments, legacy_cash, records, now)
        end
      end
    end

    backfill_orphan_lot_entitlements(now)
  end

  # Active groups still hold their funding: allocate it to rooms in their
  # original order, filling one room's deposit before moving to the next.
  defp backfill_active(
         group,
         rooms,
         payments,
         credit_ops,
         legacy_cash,
         legacy_credit,
         applications,
         now
       ) do
    {senior_credit, recorded_credit} = split_applications(applications, legacy_credit)

    streams =
      [{:cash, nil, nil, legacy_cash} | senior_credit] ++
        expand_recorded(payments, credit_ops, recorded_credit)

    room_ids = Enum.map(rooms, & &1["id"])
    dues = Map.new(rooms, fn room -> {room["id"], room["deposit_due_cents"]} end)
    initial_paid = Map.new(room_ids, &{&1, %{cash: 0, credit: 0}})

    paid =
      Enum.reduce(streams, initial_paid, fn
        {_kind, _lot_id, _operation_id, 0}, paid ->
          paid

        {kind, lot_id, operation_id, amount}, paid ->
          allocate_backfill(
            group["id"],
            room_ids,
            dues,
            paid,
            kind,
            lot_id,
            operation_id,
            amount,
            now
          )
      end)

    for room_id <- room_ids do
      %{cash: cash, credit: credit} = paid[room_id]

      exec_sql("UPDATE group_rooms SET cash_paid_cents = ?, credit_paid_cents = ? WHERE id = ?", [
        cash,
        credit,
        room_id
      ])
    end

    for {_record_id, operation_id, amount} <- payments do
      insert_all("payment_dispositions", [
        %{
          payment_operation_id: operation_id,
          kind: "held",
          amount_cents: amount,
          inserted_at: now,
          updated_at: now
        }
      ])
    end
  end

  # Cancelled groups settled their funding: classify it per payment from the
  # recorded ledger outcome, and build credit entitlements for converted cash.
  defp backfill_cancelled(group, payments, legacy_cash, records, now) do
    refunded = ledger_sum(group["id"], "cash_refunded")
    retained = ledger_sum(group["id"], "cash_retained")
    converted = ledger_sum(group["id"], "cash_converted_to_credit")

    bucket =
      Enum.find(
        [{"refunded", refunded}, {"retained", retained}, {"converted_to_credit", converted}],
        {nil, 0},
        fn {_kind, amount} -> amount > 0 end
      )

    case bucket do
      {nil, _} ->
        :ok

      {kind, total} ->
        # Legacy cash is the senior-most funding and settles first.
        legacy_settled = min(legacy_cash, total)
        left = total - legacy_settled

        {_left, settled} =
          Enum.map_reduce(payments, left, fn {_record_id, operation_id, amount}, left ->
            covered = min(amount, max(left, 0))
            {left - covered, {operation_id, covered}}
          end)

        for {operation_id, covered} <- settled, covered > 0 do
          insert_all("payment_dispositions", [
            %{
              payment_operation_id: operation_id,
              kind: kind,
              amount_cents: covered,
              inserted_at: now,
              updated_at: now
            }
          ])
        end

        if kind == "converted_to_credit" do
          funding = [{nil, legacy_settled} | settled]
          record_entitlements_for_lot(group, funding, records, now)
        end
    end
  end

  # Reconstructs the per-payment entitlements of a lot issued by a recorded
  # cancellation. Entitlements telescope over the funding order: the senior
  # block first, then payments in durable-record commit order.
  defp record_entitlements_for_lot(group, funding, records, now) do
    cancel =
      Enum.find(records, fn record ->
        record.type == "cancel_group" and record.payload["group_id"] == group["group_id"] and
          record.result["status"] == "applied"
      end)

    with %{} <- cancel,
         %{} = lot <-
           first_row("SELECT * FROM credit_lots WHERE source_operation_id = ?", [
             cancel.operation_id
           ]) do
      Enum.reduce(funding, {0, 0}, fn
        {_payer, 0}, acc ->
          acc

        {payer, amount}, {running, bonus_running} ->
          running = running + amount
          bonus_total = bonus_cents(running)
          entitlement = bonus_total - bonus_running

          insert_all("credit_entitlements", [
            %{
              credit_lot_id: lot["id"],
              payment_operation_id: payer,
              amount_cents: entitlement,
              inserted_at: now,
              updated_at: now
            }
          ])

          {running, bonus_total}
      end)

      :ok
    else
      _other -> :ok
    end
  end

  # Lots without attributable funding (issued before durable records) carry a
  # single unattributed entitlement so clawback accounting stays total.
  defp backfill_orphan_lot_entitlements(now) do
    lots =
      rows("""
      SELECT credit_lots.* FROM credit_lots
      LEFT JOIN credit_entitlements ON credit_entitlements.credit_lot_id = credit_lots.id
      WHERE credit_entitlements.id IS NULL
      """)

    for lot <- lots do
      applied =
        scalar(
          "SELECT COALESCE(SUM(amount_cents), 0) FROM room_allocations WHERE credit_lot_id = ?",
          [lot["id"]]
        )

      insert_all("credit_entitlements", [
        %{
          credit_lot_id: lot["id"],
          payment_operation_id: nil,
          amount_cents: lot["remaining_cents"] + applied,
          inserted_at: now,
          updated_at: now
        }
      ])
    end
  end

  ## Backfill helpers

  defp operation_records do
    "SELECT * FROM operation_records ORDER BY id"
    |> rows()
    |> Enum.map(fn row ->
      %{
        id: row["id"],
        operation_id: row["operation_id"],
        type: row["type"],
        payload: Jason.decode!(row["payload"]),
        result: Jason.decode!(row["result"])
      }
    end)
  end

  defp recorded_funding(records, group_id, type) do
    for record <- records,
        record.type == type,
        record.payload["group_id"] == group_id,
        record.result["status"] == "applied" do
      {record.id, record.operation_id, record.result["amount_cents"]}
    end
  end

  # Recorded funding in durable-record commit order, regardless of
  # `occurred_on`. Credit applications fund from their original lots.
  defp expand_recorded(payments, credit_ops, recorded_credit) do
    operations =
      (Enum.map(payments, fn {record_id, operation_id, amount} ->
         {record_id, {:cash, nil, operation_id, amount}}
       end) ++
         Enum.map(credit_ops, fn {record_id, _operation_id, amount} ->
           {record_id, {:credit_op, amount}}
         end))
      |> Enum.sort_by(&elem(&1, 0))

    {expanded, _remaining_slices} =
      Enum.map_reduce(operations, recorded_credit, fn
        {_record_id, {:cash, nil, operation_id, amount}}, slices ->
          {[{:cash, nil, operation_id, amount}], slices}

        {_record_id, {:credit_op, amount}}, slices ->
          {taken, rest} = take_slices(slices, amount)
          {taken, rest}
      end)

    List.flatten(expanded)
  end

  # Splits credit applications (already in original consumption order) into
  # the senior block and slices attributed to recorded applications.
  defp split_applications(applications, legacy_credit) do
    {senior, recorded, _left} =
      Enum.reduce(applications, {[], [], legacy_credit}, fn application,
                                                            {senior, recorded, left} ->
        amount = application["amount_cents"]
        senior_take = min(amount, max(left, 0))
        recorded_take = amount - senior_take

        senior =
          if senior_take > 0,
            do: [{:credit, application["credit_lot_id"], nil, senior_take} | senior],
            else: senior

        recorded =
          if recorded_take > 0,
            do: [{:credit, application["credit_lot_id"], nil, recorded_take} | recorded],
            else: recorded

        {senior, recorded, left - senior_take}
      end)

    {Enum.reverse(senior), Enum.reverse(recorded)}
  end

  defp take_slices(slices, 0), do: {[], slices}
  defp take_slices([], _amount), do: {[], []}

  defp take_slices([{:credit, lot_id, nil, available} | rest], amount) do
    take = min(available, amount)
    taken = if take > 0, do: [{:credit, lot_id, nil, take}], else: []
    rest = if take < available, do: [{:credit, lot_id, nil, available - take} | rest], else: rest
    {more_taken, remaining} = take_slices(rest, amount - take)
    {taken ++ more_taken, remaining}
  end

  defp allocate_backfill(group_id, room_ids, dues, paid, kind, lot_id, operation_id, amount, now) do
    {paid, _left} =
      Enum.reduce_while(room_ids, {paid, amount}, fn room_id, {paid, left} ->
        if left == 0 do
          {:halt, {paid, 0}}
        else
          room = paid[room_id]
          capacity = dues[room_id] - room.cash - room.credit

          if capacity <= 0 do
            {:cont, {paid, left}}
          else
            take = min(capacity, left)

            insert_all("room_allocations", [
              %{
                room_id: room_id,
                group_id: group_id,
                kind: Atom.to_string(kind),
                amount_cents: take,
                payment_operation_id: operation_id,
                credit_lot_id: lot_id,
                inserted_at: now,
                updated_at: now
              }
            ])

            room =
              if kind == :cash,
                do: %{room | cash: room.cash + take},
                else: %{room | credit: room.credit + take}

            {:cont, {Map.put(paid, room_id, room), left - take}}
          end
        end
      end)

    paid
  end

  defp ledger_sum(group_id, kind) do
    scalar(
      "SELECT COALESCE(SUM(amount_cents), 0) FROM ledger_entries WHERE group_id = ? AND kind = ?",
      [group_id, kind]
    )
  end

  defp bonus_cents(cash_cents), do: cash_cents + round_half_up(cash_cents * 10, 100)

  defp round_half_up(numerator, denominator),
    do: div(2 * numerator + denominator, 2 * denominator)

  defp sum_amounts(list),
    do: Enum.sum(Enum.map(list, fn {_record_id, _operation_id, amount} -> amount end))

  defp from_iso8601(value) when is_binary(value), do: Date.from_iso8601!(value)

  defp rows(sql, params \\ []) do
    %{columns: columns, rows: result_rows} = Repo.query!(sql, params)
    Enum.map(result_rows, fn row -> Map.new(Enum.zip(columns, row)) end)
  end

  defp first_row(sql, params) do
    case rows(sql, params) do
      [row | _] -> row
      [] -> nil
    end
  end

  defp scalar(sql, params) do
    %{rows: [[value]]} = Repo.query!(sql, params)
    value
  end

  defp exec_sql(sql, params), do: Repo.query!(sql, params)

  defp insert_all(table, entries), do: Repo.insert_all(table, entries)
end
