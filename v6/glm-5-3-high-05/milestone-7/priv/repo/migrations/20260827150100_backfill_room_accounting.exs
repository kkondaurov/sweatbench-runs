defmodule GroupStay.Repo.Migrations.BackfillRoomAccounting do
  use Ecto.Migration

  # Data migration for the room-accounting release. All statements run inline
  # (not through the migration command queue) so reads observe earlier writes.
  #
  # A database created by an earlier release can contain funding for groups.
  # Funding represented by a durable operation record (applied cash payments
  # and hotel-credit applications) is classified by its retained operation
  # type and allocated in durable-record commit order, regardless of
  # occurred_on. Funding with no durable record is brought forward as one
  # unattributed senior block per group: its aggregate cash first, then its
  # hotel-credit lots in original consumption order. Room allocations are
  # created without changing any aggregate cash, credit, or liability balance.

  def up do
    mark_rooms_of_cancelled_groups()
    stamp_operation_keys()
    materialize_allocations()
    attribute_settled_dispositions()
    materialize_lot_entitlements()
    :ok
  end

  def down do
    sql!("DELETE FROM room_allocations")
    sql!("DELETE FROM credit_entitlements")
    sql!("UPDATE ledger_entries SET operation_key = NULL, payment_entry_id = NULL")
    sql!("UPDATE credit_applications SET operation_key = NULL")
    sql!("UPDATE rooms SET status = 'active'")

    :ok
  end

  defp mark_rooms_of_cancelled_groups do
    sql!("""
    UPDATE rooms SET status = 'cancelled'
    WHERE group_id IN (SELECT id FROM groups WHERE status = 'cancelled')
    """)
  end

  # Matches durable operation records to the funding they created and stamps
  # the funding with the record's operation key. Unmatched funding is legacy
  # funding with no durable record.
  defp stamp_operation_keys do
    groups = groups_by_partner_id()
    payment_records = applied_records("record_cash_payment")
    credit_records = applied_records("apply_hotel_credit")

    for {group_pk, _group} <- groups do
      entries =
        rows!(
          "SELECT id, amount_cents FROM ledger_entries WHERE kind = 'cash_payment' AND group_id = '#{group_pk}' ORDER BY inserted_at, id"
        )
        |> Enum.map(fn [id, amount] -> %{id: id, amount: amount} end)

      # Recorded payments match their ledger entry by amount, in commit order.
      {matched, _unmatched_entries} =
        payment_records
        |> Enum.filter(&(&1.group_pk == group_pk))
        |> Enum.reduce({[], entries}, fn record, {acc, available} ->
          case Enum.split_with(available, &(&1.amount == record.amount)) do
            {[], _} ->
              {acc, available}

            {[entry | rest], others} ->
              {[{entry.id, record.operation_key} | acc], rest ++ others}
          end
        end)

      for {entry_pk, operation_key} <- matched do
        sql!(
          "UPDATE ledger_entries SET operation_key = '#{escape(operation_key)}' WHERE id = '#{entry_pk}'"
        )
      end

      # A recorded credit application may consume several lots; the
      # applications it created are matched contiguously, in consumption
      # order, by the operation's amount.
      applications =
        rows!(
          "SELECT id, amount_cents FROM credit_applications WHERE group_id = '#{group_pk}' ORDER BY inserted_at, id"
        )
        |> Enum.map(fn [id, amount] -> %{id: id, amount: amount} end)

      walk_credit_records(
        Enum.filter(credit_records, &(&1.group_pk == group_pk)),
        applications
      )
    end
  end

  defp walk_credit_records([], _applications), do: :ok

  defp walk_credit_records([record | rest], applications) do
    case take_application_chunks(applications, record.amount, []) do
      {chunks, remaining} when chunks != [] ->
        for app_pk <- chunks do
          sql!(
            "UPDATE credit_applications SET operation_key = '#{escape(record.operation_key)}' WHERE id = '#{app_pk}'"
          )
        end

        walk_credit_records(rest, remaining)

      _ ->
        walk_credit_records(rest, applications)
    end
  end

  defp take_application_chunks([], _amount, acc), do: {Enum.reverse(acc), []}

  defp take_application_chunks([app | rest], amount, acc) when amount >= app.amount,
    do: take_application_chunks(rest, amount - app.amount, [app.id | acc])

  defp take_application_chunks(_applications, _amount, _acc), do: {[], []}

  # Creates the room allocations for each group's existing funding. Rooms are
  # filled in their original order, one room's deposit before the next. The
  # events are ordered: the unattributed senior block first (aggregate cash,
  # then credit applications in original consumption order), then recorded
  # funding in durable-record commit order.
  defp materialize_allocations do
    for {group_pk, group} <- groups_by_partner_id() do
      rooms =
        rows!(
          "SELECT id, nightly_rate_cents FROM rooms WHERE group_id = '#{group_pk}' ORDER BY position"
        )
        |> Enum.map(fn [pk, rate] -> %{pk: pk, rate: rate} end)

      if rooms != [] do
        legacy_cash_total =
          scalar!(
            "SELECT COALESCE(SUM(amount_cents), 0) FROM ledger_entries WHERE kind = 'cash_payment' AND group_id = '#{group_pk}' AND operation_key IS NULL"
          )

        legacy_applications =
          rows!(
            "SELECT id, amount_cents FROM credit_applications WHERE group_id = '#{group_pk}' AND operation_key IS NULL ORDER BY inserted_at, id"
          )
          |> Enum.map(fn [pk, amount] -> {:credit, pk, amount} end)

        recorded =
          rows!("""
          SELECT 'cash' AS kind, e.id, e.amount_cents, (
            SELECT o.id FROM operation_records o WHERE o.operation_key = e.operation_key
          ) AS record_id
          FROM ledger_entries e
          WHERE e.group_id = '#{group_pk}' AND e.kind = 'cash_payment' AND e.operation_key IS NOT NULL
          UNION ALL
          SELECT 'credit' AS kind, a.id, a.amount_cents, (
            SELECT o.id FROM operation_records o WHERE o.operation_key = a.operation_key
          ) AS record_id
          FROM credit_applications a
          WHERE a.group_id = '#{group_pk}' AND a.operation_key IS NOT NULL
          ORDER BY record_id
          """)
          |> Enum.map(fn [kind, pk, amount, _record_id] ->
            {String.to_existing_atom(kind), pk, amount}
          end)

        events =
          [{:cash, :legacy, legacy_cash_total}] ++ legacy_applications ++ recorded

        cancelled? = group.status == "cancelled"

        {allocations, _deposits} =
          Enum.reduce(
            Enum.reject(events, fn {_kind, _ref, amount} -> amount == 0 end),
            {[], initial_deposits(group, rooms)},
            fn {kind, ref, amount}, {acc, deposits} ->
              {chunks, deposits} = fill_rooms(rooms, deposits, amount, kind, ref)
              {acc ++ chunks, deposits}
            end
          )

        insert_allocations(allocations, group_pk, cancelled?)
      end
    end

    :ok
  end

  defp initial_deposits(group, rooms) do
    Map.new(rooms, fn room -> {room.pk, room_deposit(group, room.rate)} end)
  end

  defp fill_rooms(rooms, deposits, amount, kind, ref) do
    rooms
    |> Enum.reduce_while({[], deposits, amount}, fn room, {acc, deposits, remaining} ->
      gap = Map.get(deposits, room.pk, 0)

      cond do
        remaining == 0 ->
          {:halt, {acc, deposits, 0}}

        gap == 0 ->
          {:cont, {acc, deposits, remaining}}

        true ->
          chunk = min(gap, remaining)
          acc = [{room.pk, kind, ref, chunk} | acc]
          deposits = Map.put(deposits, room.pk, gap - chunk)
          remaining = remaining - chunk

          if remaining == 0,
            do: {:halt, {acc, deposits, 0}},
            else: {:cont, {acc, deposits, remaining}}
      end
    end)
    |> case do
      {acc, deposits, _remaining} -> {Enum.reverse(acc), deposits}
    end
  end

  defp insert_allocations(allocations, group_pk, cancelled?) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    for {room_pk, kind, ref, amount} <- allocations do
      {payment_ref, application_ref} =
        case kind do
          :cash when ref == :legacy -> {"NULL", "NULL"}
          :cash -> {"'" <> ref <> "'", "NULL"}
          :credit -> {"NULL", "'" <> ref <> "'"}
        end

      remaining = if cancelled?, do: 0, else: amount
      settled = if cancelled?, do: amount, else: 0

      sql!("""
      INSERT INTO room_allocations
        (group_id, room_id, kind, amount_cents, remaining_cents, settled_cents,
         payment_entry_id, credit_application_id, inserted_at, updated_at)
      VALUES
        ('#{group_pk}', '#{room_pk}', '#{kind}', #{amount}, #{remaining}, #{settled},
         #{payment_ref}, #{application_ref}, '#{now}', '#{now}')
      """)
    end

    :ok
  end

  # Groups that were already cancelled hold refund, retention, and conversion
  # entries with no payment attribution. Those entries are replaced with
  # per-payment entries (plus one unattributed entry for the legacy block) so
  # each payment's dispositions remain readable. Aggregate ledger totals are
  # preserved exactly.
  defp attribute_settled_dispositions do
    for {group_pk, _group} <- groups_by_partner_id() do
      cancelled? =
        scalar!("SELECT COUNT(*) FROM groups WHERE id = '#{group_pk}' AND status = 'cancelled'") ==
          1

      if cancelled? do
        dispositions =
          rows!(
            "SELECT kind, amount_cents, occurred_on FROM ledger_entries WHERE group_id = '#{group_pk}' AND kind IN ('refund', 'retention', 'cash_converted_to_credit') ORDER BY inserted_at, id"
          )

        if dispositions != [] do
          attribute_group_dispositions(group_pk, dispositions)
        end
      end
    end

    :ok
  end

  defp attribute_group_dispositions(group_pk, dispositions) do
    totals =
      dispositions
      |> Enum.group_by(&Enum.at(&1, 0), &Enum.at(&1, 1))
      |> Map.new(fn {kind, amounts} -> {kind, Enum.sum(amounts)} end)

    occurred_on = dispositions |> Enum.map(&Enum.at(&1, 2)) |> Enum.min()

    # Payments in funding order (the earliest room allocation each funded).
    payments =
      rows!("""
      SELECT e.id, (
        SELECT COALESCE(SUM(a.settled_cents), 0) FROM room_allocations a
        WHERE a.payment_entry_id = e.id
      ) AS settled
      FROM ledger_entries e
      WHERE e.group_id = '#{group_pk}' AND e.kind = 'cash_payment' AND e.operation_key IS NOT NULL
      ORDER BY (SELECT COALESCE(MIN(a.id), 0) FROM room_allocations a WHERE a.payment_entry_id = e.id)
      """)

    kinds = ["refund", "retention", "cash_converted_to_credit"]

    {payment_attribution, remaining} =
      Enum.reduce(payments, {%{}, totals}, fn [entry_pk, settled], {acc, totals} ->
        {taken, totals} = take_from_totals(settled || 0, kinds, totals)
        {Map.put(acc, entry_pk, taken), totals}
      end)

    # The unattributed block absorbs whatever remains so the aggregate
    # dispositions never change.
    {legacy_attribution, _} = take_from_totals(:all, kinds, remaining)

    sql!(
      "DELETE FROM ledger_entries WHERE group_id = '#{group_pk}' AND kind IN ('refund', 'retention', 'cash_converted_to_credit')"
    )

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    for {entry_pk, kinds_amounts} <- payment_attribution,
        {kind, amount} <- kinds_amounts,
        amount > 0 do
      insert_disposition_entry(group_pk, kind, amount, occurred_on, entry_pk, now)
    end

    for {kind, amount} <- legacy_attribution, amount > 0 do
      insert_disposition_entry(group_pk, kind, amount, occurred_on, nil, now)
    end

    :ok
  end

  defp take_from_totals(0, _kinds, totals), do: {%{}, totals}

  defp take_from_totals(_amount, [], totals), do: {%{}, totals}

  defp take_from_totals(:all, kinds, totals) do
    Enum.reduce(kinds, {%{}, totals}, fn kind, {acc, totals} ->
      amount = Map.get(totals, kind, 0)
      {Map.put(acc, kind, amount), Map.put(totals, kind, 0)}
    end)
  end

  defp take_from_totals(amount, [kind | rest], totals) do
    available = Map.get(totals, kind, 0)
    take = min(available, amount)
    totals = Map.put(totals, kind, available - take)
    amount = amount - take

    if amount > 0 do
      {rest_taken, totals} = take_from_totals(amount, rest, totals)
      {Map.merge(%{kind => take}, rest_taken), totals}
    else
      {%{kind => take}, totals}
    end
  end

  defp insert_disposition_entry(group_pk, kind, amount, occurred_on, payment_entry_pk, now) do
    payment_ref =
      if payment_entry_pk, do: "'" <> payment_entry_pk <> "'", else: "NULL"

    sql!("""
    INSERT INTO ledger_entries
      (id, group_id, kind, amount_cents, occurred_on, operation_key, payment_entry_id,
       inserted_at, updated_at)
    VALUES
      ('#{Ecto.UUID.generate()}', '#{group_pk}', '#{kind}', #{amount}, '#{occurred_on}',
       NULL, #{payment_ref}, '#{now}', '#{now}')
    """)
  end

  # Credit lots issued by earlier releases recorded no per-payment
  # entitlement. Entitlements are reconstructed from the attributed conversion
  # entries of the group the lot was issued from, in funding order with the
  # unattributed block first.
  defp materialize_lot_entitlements do
    group_pks = group_pks_by_partner_id()

    rows!("SELECT id, source_operation_id FROM credit_lots")
    |> Enum.each(fn [lot_pk, source_operation_id] ->
      record =
        rows!(
          "SELECT payload FROM operation_records WHERE type = 'cancel_group' AND status = 'applied' AND operation_key = '#{escape(Jason.encode!(source_operation_id))}' ORDER BY id LIMIT 1"
        )
        |> case do
          [[payload]] -> payload
          [] -> nil
        end

      with {:ok, decoded} <- (record && Jason.decode(record)) || {:error, :none},
           group_pk when not is_nil(group_pk) <-
             Map.get(group_pks, decoded["group_id"]) do
        legacy =
          scalar!(
            "SELECT COALESCE(SUM(amount_cents), 0) FROM ledger_entries WHERE group_id = '#{group_pk}' AND kind = 'cash_converted_to_credit' AND payment_entry_id IS NULL"
          )

        per_payment =
          rows!("""
          SELECT e.payment_entry_id, e.amount_cents FROM ledger_entries e
          WHERE e.group_id = '#{group_pk}'
            AND e.kind = 'cash_converted_to_credit'
            AND e.payment_entry_id IS NOT NULL
          ORDER BY (SELECT COALESCE(MIN(a.id), 0) FROM room_allocations a WHERE a.payment_entry_id = e.id)
          """)
          |> Enum.map(fn [entry_pk, amount] -> {entry_pk, amount} end)

        contributions =
          if legacy > 0, do: [{nil, legacy} | per_payment], else: per_payment

        insert_entitlements(lot_pk, contributions)
      end
    end)

    :ok
  end

  defp insert_entitlements(lot_pk, contributions) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Enum.reduce(contributions, 0, fn {entry_pk, amount}, cumulative ->
      before_cents = lot_value(cumulative)
      cumulative = cumulative + amount
      after_cents = lot_value(cumulative)
      entitlement = after_cents - before_cents

      if entitlement > 0 do
        entry_ref = if entry_pk, do: "'" <> entry_pk <> "'", else: "NULL"

        sql!("""
        INSERT INTO credit_entitlements
          (id, lot_id, payment_entry_id, entitlement_cents, inserted_at, updated_at)
        VALUES
          ('#{Ecto.UUID.generate()}', '#{lot_pk}', #{entry_ref}, #{entitlement}, '#{now}', '#{now}')
        """)
      end

      cumulative
    end)

    :ok
  end

  ## Helpers

  defp groups_by_partner_id do
    rows!("SELECT id, guest_id, rate_plan, arrival_on, departure_on, status FROM groups")
    |> Map.new(fn [pk, guest_id, rate_plan, arrival, departure, status] ->
      {pk,
       %{
         guest_id: guest_id,
         rate_plan: rate_plan,
         arrival_on: to_date(arrival),
         departure_on: to_date(departure),
         status: status
       }}
    end)
  end

  defp applied_records(type) do
    by_partner = group_pks_by_partner_id()

    rows!(
      "SELECT id, operation_key, payload FROM operation_records WHERE type = '" <>
        type <> "' AND status = 'applied' ORDER BY id"
    )
    |> Enum.map(fn [id, operation_key, payload] ->
      {:ok, decoded} = Jason.decode(payload)

      %{
        id: id,
        operation_key: operation_key,
        group_pk: Map.get(by_partner, decoded["group_id"]),
        amount: decoded["amount_cents"]
      }
    end)
    |> Enum.reject(&is_nil(&1.group_pk))
  end

  defp group_pks_by_partner_id do
    rows!("SELECT id, group_id FROM groups")
    |> Map.new(fn [pk, group_id] -> {group_id, pk} end)
  end

  defp room_deposit(group, nightly_rate_cents) do
    nights = Date.diff(group.departure_on, group.arrival_on)
    lodging = nights * nightly_rate_cents

    case group.rate_plan do
      "advance_purchase" -> lodging
      _ -> div(lodging * 20 + 50, 100)
    end
  end

  defp lot_value(cash_cents), do: div(cash_cents * 110 + 50, 100)

  defp to_date(%Date{} = date), do: date

  defp to_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> parsed
      {:error, _} -> Date.from_iso8601!(String.slice(date, 0, 10))
    end
  end

  defp rows!(sql) do
    case Ecto.Adapters.SQL.query(GroupStay.Repo, sql, []) do
      {:ok, %{rows: rows}} -> rows
      {:error, error} -> raise error
    end
  end

  defp scalar!(sql) do
    [[value]] = rows!(sql)
    value
  end

  defp sql!(sql) do
    case Ecto.Adapters.SQL.query(GroupStay.Repo, sql, []) do
      {:ok, _result} -> :ok
      {:error, error} -> raise error
    end
  end

  defp escape(value) when is_binary(value), do: String.replace(value, "'", "''")
end
