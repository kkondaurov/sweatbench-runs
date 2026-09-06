defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all)
    end

    create index(:credit_allocations, [:room_id])

    create table(:cash_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :reservation_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_allocations, [:reservation_id, :position])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:cash_payment_dispositions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :reservation_id, references(:groups, type: :binary_id, on_delete: :delete_all),
        null: false

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict)
      add :payment_operation_id, :string, null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cash_payment_dispositions, [:payment_operation_id, :kind])
    create index(:cash_payment_dispositions, [:credit_lot_id])

    create table(:credit_entitlements, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all),
        null: false

      add :payment_operation_id, :string, null: false
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_entitlements, [:payment_operation_id])
    create index(:credit_entitlements, [:credit_lot_id])

    flush()
    backfill_room_accounting()
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:cash_payment_dispositions)
    drop table(:cash_allocations)
    drop index(:credit_allocations, [:room_id])

    alter table(:credit_allocations) do
      remove :room_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end

    alter table(:groups) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end
  end

  # Releases before durable operation records only retained group-level balances. Allocate that
  # senior balance first, then replay durable funding in commit order. This creates no new value:
  # it only records which active room already carries each existing balance.
  defp backfill_room_accounting do
    operations = durable_funding_operations()

    query_rows("SELECT * FROM groups")
    |> Enum.each(fn group ->
      rooms = group_rooms(group["id"])
      rooms = update_room_amounts(group, rooms)
      group_operations = Map.get(operations, group["group_id"], [])

      if group["status"] == "active" do
        cash_paid = integer(group["cash_paid_cents"])
        credit_paid = integer(group["credit_paid_cents"])

        durable_cash =
          group_operations
          |> Enum.filter(&(&1.kind == :cash))
          |> Enum.sum_by(& &1.amount)

        durable_credit =
          group_operations
          |> Enum.filter(&(&1.kind == :credit))
          |> Enum.sum_by(& &1.amount)

        legacy_cash = max(cash_paid - durable_cash, 0)
        legacy_credit = max(credit_paid - durable_credit, 0)

        original_credit = original_credit_funding(group["id"])

        senior_funding =
          [
            %{kind: :cash, payment_operation_id: nil, amount: legacy_cash},
            %{kind: :credit, payment_operation_id: nil, amount: legacy_credit}
          ]
          |> Enum.reject(&(&1.amount == 0))

        {rooms_after_funding, cash_allocations, credit_allocations} =
          replay_funding(rooms, original_credit, senior_funding ++ group_operations)

        insert_cash_allocations(group["id"], cash_allocations)
        replace_credit_allocations(group["id"], credit_allocations)
        update_room_paid_amounts(rooms_after_funding)
      else
        backfill_cancelled_payment_history(group, group_operations)

        # Earlier full cancellations retained the original lodging total. Group totals now
        # deliberately describe active rooms only, so a fully cancelled group has no current
        # lodging, due, or applied funding.
        query!(
          """
          UPDATE groups
          SET lodging_total_cents = 0, deposit_due_cents = 0, deposit_paid_cents = 0,
              cash_paid_cents = 0, credit_paid_cents = 0
          WHERE id = ?
          """,
          [group["id"]]
        )
      end
    end)
  end

  # A group cancelled before this release has no held room funding, but its durable cash payments
  # must still be reconcilable and chargeable. Earlier releases only settled a whole group, so
  # split the recorded settlement across the senior legacy block and durable payments in the same
  # funding order used for active-group backfill.
  defp backfill_cancelled_payment_history(group, group_operations) do
    categories =
      [
        {"refunded", integer(group["refunded_cents"])},
        {"retained", integer(group["retained_cents"])},
        {"converted", integer(group["cash_converted_to_credit_cents"])}
      ]
      |> Enum.reject(fn {_kind, amount} -> amount == 0 end)

    durable_cash =
      group_operations
      |> Enum.filter(&(&1.kind == :cash))

    settled_cents = Enum.sum(Enum.map(categories, fn {_kind, amount} -> amount end))
    legacy_cash = max(settled_cents - Enum.sum(Enum.map(durable_cash, & &1.amount)), 0)

    funding =
      [%{payment_operation_id: nil, amount: legacy_cash} | durable_cash]
      |> Enum.reject(&(&1.amount == 0))

    dispositions = allocate_dispositions(funding, categories)
    credit_lot_id = cancellation_credit_lot_id(group["group_id"])

    Enum.each(dispositions, fn {payment_operation_id, kind, amount} ->
      if payment_operation_id do
        query!(
          """
          INSERT INTO cash_payment_dispositions
            (id, reservation_id, credit_lot_id, payment_operation_id, kind, amount_cents, inserted_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
          """,
          [
            Ecto.UUID.generate(),
            group["id"],
            if(kind == "converted", do: credit_lot_id),
            payment_operation_id,
            kind,
            amount
          ]
        )
      end
    end)

    if credit_lot_id do
      record_cancelled_credit_entitlements(credit_lot_id, dispositions)
    end
  end

  defp allocate_dispositions(funding, categories) do
    {_categories, dispositions} =
      Enum.reduce(funding, {categories, []}, fn funding, {categories, dispositions} ->
        {categories, funding_dispositions} =
          take_dispositions(categories, funding.amount, funding.payment_operation_id, [])

        {categories, dispositions ++ funding_dispositions}
      end)

    dispositions
  end

  defp take_dispositions(categories, 0, _payment_operation_id, dispositions),
    do: {categories, Enum.reverse(dispositions)}

  defp take_dispositions([], _amount, _payment_operation_id, dispositions),
    do: {[], Enum.reverse(dispositions)}

  defp take_dispositions(
         [{kind, available} | categories],
         amount,
         payment_operation_id,
         dispositions
       ) do
    used = min(available, amount)
    remaining = available - used
    categories = if remaining == 0, do: categories, else: [{kind, remaining} | categories]

    take_dispositions(
      categories,
      amount - used,
      payment_operation_id,
      if(used == 0, do: dispositions, else: [{payment_operation_id, kind, used} | dispositions])
    )
  end

  defp cancellation_credit_lot_id(group_id) do
    source_operation_id =
      query_rows(
        "SELECT operation_id, result_json FROM partner_operations WHERE operation_type = 'cancel_group' ORDER BY id ASC"
      )
      |> Enum.find_value(fn operation ->
        result = Jason.decode!(operation["result_json"])

        if result["status"] == "applied" and result["group_id"] == group_id and
             integer(result["credit_issued_cents"]) > 0 do
          operation["operation_id"]
        end
      end)

    case source_operation_id do
      nil ->
        nil

      source_operation_id ->
        query_rows("SELECT id FROM credit_lots WHERE source_operation_id = ?", [
          source_operation_id
        ])
        |> List.first()
        |> case do
          nil -> nil
          lot -> lot["id"]
        end
    end
  end

  defp record_cancelled_credit_entitlements(credit_lot_id, dispositions) do
    dispositions
    |> Enum.filter(fn {_payment_operation_id, kind, _amount} -> kind == "converted" end)
    |> Enum.reduce(0, fn {payment_operation_id, _kind, amount}, settled_before ->
      settled_through = settled_before + amount
      entitlement = credit_value(settled_through) - credit_value(settled_before)

      if payment_operation_id do
        query!(
          """
          INSERT INTO credit_entitlements
            (id, credit_lot_id, payment_operation_id, amount_cents, inserted_at, updated_at)
          VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
          """,
          [Ecto.UUID.generate(), credit_lot_id, payment_operation_id, entitlement]
        )
      end

      settled_through
    end)
  end

  defp durable_funding_operations do
    query_rows("""
    SELECT id, operation_id, operation_type, result_json
    FROM partner_operations
    WHERE operation_type IN ('record_cash_payment', 'apply_hotel_credit')
    ORDER BY id ASC
    """)
    |> Enum.reduce(%{}, fn operation, grouped ->
      result = Jason.decode!(operation["result_json"])

      if result["status"] == "applied" and is_binary(result["group_id"]) and
           is_integer(result["amount_cents"]) do
        kind = if operation["operation_type"] == "record_cash_payment", do: :cash, else: :credit

        funding = %{
          kind: kind,
          payment_operation_id: if(kind == :cash, do: operation["operation_id"], else: nil),
          amount: result["amount_cents"]
        }

        Map.update(grouped, result["group_id"], [funding], &(&1 ++ [funding]))
      else
        grouped
      end
    end)
  end

  defp group_rooms(reservation_id) do
    query_rows(
      "SELECT id, nightly_rate_cents, position FROM rooms WHERE reservation_id = ? ORDER BY position ASC",
      [reservation_id]
    )
    |> Enum.map(fn room ->
      Map.merge(room, %{
        "cash_paid_cents" => 0,
        "credit_paid_cents" => 0,
        "deposit_due_cents" => 0
      })
    end)
  end

  defp update_room_amounts(group, rooms) do
    arrival = Date.from_iso8601!(group["arrival_on"])
    departure = Date.from_iso8601!(group["departure_on"])
    nights = Date.diff(departure, arrival)

    Enum.map(rooms, fn room ->
      lodging_total = integer(room["nightly_rate_cents"]) * nights

      deposit_due =
        if group["rate_plan"] == "advance_purchase" do
          lodging_total
        else
          round_percentage(lodging_total, 20)
        end

      query!(
        """
        UPDATE rooms
        SET status = ?, lodging_total_cents = ?, deposit_due_cents = ?,
            cash_paid_cents = 0, credit_paid_cents = 0
        WHERE id = ?
        """,
        [group["status"], lodging_total, deposit_due, room["id"]]
      )

      Map.merge(room, %{
        "status" => group["status"],
        "lodging_total_cents" => lodging_total,
        "deposit_due_cents" => deposit_due
      })
    end)
  end

  defp original_credit_funding(reservation_id) do
    query_rows(
      """
      SELECT credit_lot_id, amount_cents
      FROM credit_allocations
      WHERE reservation_id = ?
      ORDER BY inserted_at ASC, id ASC
      """,
      [reservation_id]
    )
    |> Enum.map(fn allocation ->
      {allocation["credit_lot_id"], integer(allocation["amount_cents"])}
    end)
  end

  defp replay_funding(rooms, credit_chunks, funding) do
    {rooms, _credit_chunks, cash_allocations, credit_allocations, _cash_position} =
      Enum.reduce(funding, {rooms, credit_chunks, [], [], 0}, fn
        %{kind: :cash, payment_operation_id: payment_operation_id, amount: amount},
        {rooms, credit_chunks, cash_allocations, credit_allocations, cash_position} ->
          {rooms, allocations} = allocate_amount(rooms, amount, :cash)

          allocations =
            allocations
            |> Enum.with_index(cash_position)
            |> Enum.map(fn {{room_id, cents}, position} ->
              {room_id, payment_operation_id, cents, position}
            end)

          {
            rooms,
            credit_chunks,
            cash_allocations ++ allocations,
            credit_allocations,
            cash_position + length(allocations)
          }

        %{kind: :credit, amount: amount},
        {rooms, credit_chunks, cash_allocations, credit_allocations, cash_position} ->
          {used_credit, remaining_credit} = take_credit(credit_chunks, amount)

          {rooms, allocations} =
            Enum.reduce(used_credit, {rooms, []}, fn {lot_id, cents}, {rooms, allocations} ->
              {rooms, room_allocations} = allocate_amount(rooms, cents, :credit)

              room_allocations =
                Enum.map(room_allocations, fn {room_id, used} -> {room_id, lot_id, used} end)

              {rooms, allocations ++ room_allocations}
            end)

          {rooms, remaining_credit, cash_allocations, credit_allocations ++ allocations,
           cash_position}
      end)

    {rooms, cash_allocations, credit_allocations}
  end

  defp take_credit(chunks, amount), do: take_credit(chunks, amount, [])

  defp take_credit(chunks, 0, taken), do: {Enum.reverse(taken), chunks}
  defp take_credit([], _amount, taken), do: {Enum.reverse(taken), []}

  defp take_credit([{lot_id, available} | chunks], amount, taken) do
    used = min(available, amount)
    rest = available - used
    remaining = if rest == 0, do: chunks, else: [{lot_id, rest} | chunks]
    take_credit(remaining, amount - used, [{lot_id, used} | taken])
  end

  defp allocate_amount(rooms, amount, kind) do
    paid_field = if kind == :cash, do: "cash_paid_cents", else: "credit_paid_cents"

    {updated_rooms, _remaining, allocations} =
      Enum.reduce(rooms, {[], amount, []}, fn room, {updated_rooms, remaining, allocations} ->
        available =
          max(
            integer(room["deposit_due_cents"]) - integer(room["cash_paid_cents"]) -
              integer(room["credit_paid_cents"]),
            0
          )

        used = min(available, remaining)
        updated_room = Map.update!(room, paid_field, &(&1 + used))

        {
          [updated_room | updated_rooms],
          remaining - used,
          if(used == 0, do: allocations, else: [{room["id"], used} | allocations])
        }
      end)

    {Enum.reverse(updated_rooms), Enum.reverse(allocations)}
  end

  defp insert_cash_allocations(reservation_id, allocations) do
    allocations
    |> Enum.each(fn {room_id, payment_operation_id, amount, position} ->
      query!(
        """
        INSERT INTO cash_allocations
          (id, reservation_id, room_id, payment_operation_id, amount_cents, position, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """,
        [Ecto.UUID.generate(), reservation_id, room_id, payment_operation_id, amount, position]
      )
    end)
  end

  defp replace_credit_allocations(reservation_id, allocations) do
    query!("DELETE FROM credit_allocations WHERE reservation_id = ?", [reservation_id])

    Enum.each(allocations, fn {room_id, credit_lot_id, amount} ->
      query!(
        """
        INSERT INTO credit_allocations
          (id, reservation_id, credit_lot_id, room_id, amount_cents, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        """,
        [Ecto.UUID.generate(), reservation_id, credit_lot_id, room_id, amount]
      )
    end)
  end

  defp update_room_paid_amounts(rooms) do
    Enum.each(rooms, fn room ->
      query!(
        "UPDATE rooms SET cash_paid_cents = ?, credit_paid_cents = ? WHERE id = ?",
        [room["cash_paid_cents"], room["credit_paid_cents"], room["id"]]
      )
    end)
  end

  defp query_rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp query!(sql, params), do: repo().query!(sql, params)
  defp integer(nil), do: 0
  defp integer(value) when is_integer(value), do: value
  defp integer(value), do: String.to_integer(value)
  defp round_percentage(amount, percentage), do: div(amount * percentage + 50, 100)
  defp credit_value(cash), do: cash + round_percentage(cash, 10)
end
