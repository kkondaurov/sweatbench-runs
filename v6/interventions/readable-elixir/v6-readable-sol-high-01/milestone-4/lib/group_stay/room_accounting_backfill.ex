defmodule GroupStay.RoomAccountingBackfill do
  @moduledoc false

  # This module is called only by the room-accounting migration. Keeping the
  # transformation in Elixir makes the allocation order explicit and, unlike a
  # one-off startup hook, guarantees that an upgraded database is immediately
  # usable by the release that migrated it.

  def run(repo) do
    calculate_room_requirements(repo)
    payments = reconstruct_cash_payments(repo)
    allocate_active_funding(repo, payments)
    reconstruct_credit_entitlements(repo, payments)
    refresh_group_totals(repo)
  end

  defp calculate_room_requirements(repo) do
    repo.query!("""
    UPDATE rooms
    SET status = (SELECT status FROM groups WHERE groups.id = rooms.group_record_id),
        lodging_total_cents = nightly_rate_cents * CAST(
          julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_record_id)) -
          julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_record_id)) AS INTEGER
        ),
        deposit_due_cents = CASE
          WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_record_id) = 'advance_purchase'
            THEN nightly_rate_cents * CAST(
              julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_record_id)) -
              julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_record_id)) AS INTEGER
            )
          ELSE CAST((nightly_rate_cents * CAST(
            julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_record_id)) -
            julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_record_id)) AS INTEGER
          ) * 20 + 50) / 100 AS INTEGER)
        END
    """)
  end

  defp reconstruct_cash_payments(repo) do
    records =
      rows(repo, """
      SELECT r.operation_id, r.commit_order, g.id, g.status,
             g.refunded_cents, g.retained_cents, g.cash_converted_to_credit_cents,
             CAST(json_extract(r.result, '$.amount_cents') AS INTEGER)
      FROM partner_operation_records r
      JOIN groups g ON g.group_id = json_extract(r.result, '$.group_id')
      WHERE r.operation_type = 'record_cash_payment'
        AND json_extract(r.result, '$.status') = 'applied'
      ORDER BY r.commit_order
      """)

    now = timestamp()

    Enum.reduce(records, %{}, fn
      [operation_id, order, group_id, status, refunded, retained, converted, amount], acc ->
        disposition = historical_disposition(status, refunded, retained, converted)
        payment_id = Ecto.UUID.generate()

        attrs =
          %{
            id: payment_id,
            payment_operation_id: operation_id,
            group_record_id: group_id,
            funding_order: order,
            recorded_cents: amount,
            held_cents: 0,
            refunded_cents: 0,
            retained_cents: 0,
            converted_to_credit_cents: 0,
            reduced_cents: 0,
            charged_back_cents: 0,
            inserted_at: now,
            updated_at: now
          }
          |> Map.put(disposition, amount)

        repo.insert_all("cash_payments", [attrs])
        Map.put(acc, operation_id, %{id: payment_id, order: order, amount: amount})
    end)
  end

  defp historical_disposition("active", _refunded, _retained, _converted), do: :held_cents

  defp historical_disposition(_status, refunded, _retained, _converted) when refunded > 0,
    do: :refunded_cents

  defp historical_disposition(_status, _refunded, retained, _converted) when retained > 0,
    do: :retained_cents

  defp historical_disposition(_status, _refunded, _retained, converted) when converted > 0,
    do: :converted_to_credit_cents

  # A cancelled zero-cash group cannot have an applied positive payment. This
  # fallback keeps a hand-edited legacy database internally reconciled.
  defp historical_disposition(_status, _refunded, _retained, _converted), do: :charged_back_cents

  defp allocate_active_funding(repo, payments) do
    groups =
      rows(repo, """
      SELECT id, cash_paid_cents, credit_paid_cents
      FROM groups
      WHERE status = 'active'
      ORDER BY inserted_at, id
      """)

    Enum.each(groups, fn [group_id, cash_total, credit_total] ->
      durable = durable_funding(repo, group_id)
      durable_cash = durable |> Enum.filter(&(&1.kind == :cash)) |> sum_amounts()
      durable_credit = durable |> Enum.filter(&(&1.kind == :credit)) |> sum_amounts()

      legacy =
        [
          block(:cash, max(cash_total - durable_cash, 0), nil, 0),
          block(:credit, max(credit_total - durable_credit, 0), nil, 0)
        ]
        |> Enum.reject(&(&1.amount == 0))

      rooms = active_rooms(repo, group_id)
      credit_segments = take_credit_segments(repo, group_id)

      {rooms, credit_segments} =
        Enum.reduce(legacy ++ durable, {rooms, credit_segments}, fn funding, state ->
          allocate_block(repo, group_id, funding, payments, state)
        end)

      if Enum.any?(credit_segments, &(&1.amount > 0)) do
        raise "credit-allocation backfill left unmatched credit for group #{group_id}"
      end

      persist_room_balances(repo, rooms)
    end)
  end

  defp durable_funding(repo, group_record_id) do
    rows(
      repo,
      """
      SELECT r.operation_id, r.operation_type, r.commit_order,
             CAST(json_extract(r.result, '$.amount_cents') AS INTEGER)
      FROM partner_operation_records r
      JOIN groups g ON g.group_id = json_extract(r.result, '$.group_id')
      WHERE g.id = ?
        AND r.operation_type IN ('record_cash_payment', 'apply_hotel_credit')
        AND json_extract(r.result, '$.status') = 'applied'
      ORDER BY r.commit_order
      """,
      [group_record_id]
    )
    |> Enum.map(fn [operation_id, type, order, amount] ->
      kind = if type == "record_cash_payment", do: :cash, else: :credit
      block(kind, amount, operation_id, order)
    end)
  end

  defp active_rooms(repo, group_id) do
    rows(
      repo,
      """
      SELECT id, position, deposit_due_cents
      FROM rooms
      WHERE group_record_id = ? AND status = 'active'
      ORDER BY position
      """,
      [group_id]
    )
    |> Enum.map(fn [id, position, due] ->
      %{id: id, position: position, due: due, cash: 0, credit: 0}
    end)
  end

  defp take_credit_segments(repo, group_id) do
    segments =
      rows(
        repo,
        """
        SELECT id, credit_lot_id, amount_cents
        FROM credit_allocations
        WHERE group_record_id = ?
        ORDER BY rowid
        """,
        [group_id]
      )
      |> Enum.map(fn [_id, lot_id, amount] -> %{lot_id: lot_id, amount: amount} end)

    repo.query!("DELETE FROM credit_allocations WHERE group_record_id = ?", [group_id])
    segments
  end

  defp allocate_block(_repo, _group_id, %{amount: 0}, _payments, state), do: state

  defp allocate_block(repo, group_id, %{kind: :cash} = funding, payments, {rooms, segments}) do
    payment_id = funding.operation_id && payments[funding.operation_id].id

    rooms =
      allocate_to_rooms(rooms, funding.amount, fn room, amount ->
        insert_cash_allocation(repo, group_id, room.id, payment_id, funding.order, amount)
        %{room | cash: room.cash + amount}
      end)

    {rooms, segments}
  end

  defp allocate_block(repo, group_id, %{kind: :credit} = funding, _payments, {rooms, segments}) do
    {rooms, segments} =
      allocate_credit_to_rooms(
        repo,
        group_id,
        rooms,
        segments,
        funding.amount,
        funding.operation_id,
        funding.order
      )

    {rooms, segments}
  end

  defp allocate_to_rooms(rooms, amount, allocator) do
    {rooms, left} =
      Enum.map_reduce(rooms, amount, fn room, left ->
        capacity = max(room.due - room.cash - room.credit, 0)
        allocated = min(capacity, left)
        room = if allocated > 0, do: allocator.(room, allocated), else: room
        {room, left - allocated}
      end)

    if left != 0, do: raise("funding exceeds room requirements during backfill")
    rooms
  end

  defp allocate_credit_to_rooms(repo, group_id, rooms, segments, amount, operation_id, order) do
    {rooms, {segments, left}} =
      Enum.map_reduce(rooms, {segments, amount}, fn room, {segments, left} ->
        capacity = max(room.due - room.cash - room.credit, 0)
        room_amount = min(capacity, left)

        {segments, pieces} = take_segments(segments, room_amount)

        Enum.each(pieces, fn {lot_id, piece} ->
          insert_credit_allocation(
            repo,
            group_id,
            room.id,
            lot_id,
            operation_id,
            order,
            piece
          )
        end)

        {%{room | credit: room.credit + room_amount}, {segments, left - room_amount}}
      end)

    if left != 0, do: raise("credit funding exceeds room requirements during backfill")
    {rooms, segments}
  end

  defp take_segments(segments, 0), do: {segments, []}

  defp take_segments([segment | rest], amount) do
    taken = min(segment.amount, amount)
    remaining = segment.amount - taken
    segments = if remaining == 0, do: rest, else: [%{segment | amount: remaining} | rest]
    {segments, pieces} = take_segments(segments, amount - taken)
    {segments, [{segment.lot_id, taken} | pieces]}
  end

  defp take_segments([], amount) when amount > 0 do
    raise "credit-allocation backfill could not match #{amount} cents to a credit lot"
  end

  defp insert_cash_allocation(repo, group_id, room_id, payment_id, order, amount) do
    now = timestamp()

    repo.insert_all("cash_allocations", [
      %{
        id: Ecto.UUID.generate(),
        group_record_id: group_id,
        room_record_id: room_id,
        cash_payment_id: payment_id,
        funding_order: order,
        amount_cents: amount,
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp insert_credit_allocation(repo, group_id, room_id, lot_id, operation_id, order, amount) do
    now = timestamp()

    repo.insert_all("credit_allocations", [
      %{
        id: Ecto.UUID.generate(),
        credit_lot_id: lot_id,
        group_record_id: group_id,
        room_record_id: room_id,
        funding_operation_id: operation_id,
        funding_order: order,
        amount_cents: amount,
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp persist_room_balances(repo, rooms) do
    Enum.each(rooms, fn room ->
      repo.query!(
        "UPDATE rooms SET cash_paid_cents = ?, credit_paid_cents = ? WHERE id = ?",
        [room.cash, room.credit, room.id]
      )
    end)
  end

  defp reconstruct_credit_entitlements(repo, payments) do
    lots =
      rows(repo, """
      SELECT lot.id, lot.source_operation_id,
             CAST(json_extract(record.result, '$.credit_issued_cents') AS INTEGER),
             json_extract(record.submission, '$.group_id')
      FROM credit_lots lot
      JOIN partner_operation_records record
        ON record.operation_id = lot.source_operation_id
      WHERE record.operation_type IN ('cancel_group', 'cancel_rooms')
        AND json_extract(record.result, '$.status') = 'applied'
      """)

    Enum.each(lots, fn [lot_id, _source_id, issued, group_partner_id] ->
      payment_parts =
        rows(
          repo,
          """
          SELECT payment_operation_id, funding_order, converted_to_credit_cents
          FROM cash_payments payment
          JOIN groups g ON g.id = payment.group_record_id
          WHERE g.group_id = ? AND converted_to_credit_cents > 0
          ORDER BY funding_order
          """,
          [group_partner_id]
        )

      durable_principal =
        Enum.reduce(payment_parts, 0, fn [_, _, amount], total -> total + amount end)

      total_principal = principal_for_issued_credit(issued)
      running = max(total_principal - durable_principal, 0)

      Enum.reduce(payment_parts, running, fn [operation_id, _order, principal], before ->
        after_payment = before + principal
        credit = bonus_value(after_payment) - bonus_value(before)
        payment_id = payments[operation_id].id
        now = timestamp()

        repo.insert_all("credit_entitlements", [
          %{
            id: Ecto.UUID.generate(),
            credit_lot_id: lot_id,
            cash_payment_id: payment_id,
            principal_cents: principal,
            credit_cents: credit,
            revoked_cents: 0,
            inserted_at: now,
            updated_at: now
          }
        ])

        after_payment
      end)
    end)
  end

  # Find the unique principal p whose standard bonus value is the stored issue.
  # Existing lots were all produced by this exact calculation.
  defp principal_for_issued_credit(issued) do
    estimate = div(issued * 10, 11)

    Enum.find(max(estimate - 2, 0)..(estimate + 2), fn principal ->
      bonus_value(principal) == issued
    end) || raise("cannot recover converted principal for #{issued}-cent credit lot")
  end

  defp refresh_group_totals(repo) do
    repo.query!("""
    UPDATE groups
    SET lodging_total_cents = COALESCE((
          SELECT SUM(lodging_total_cents) FROM rooms
          WHERE rooms.group_record_id = groups.id AND rooms.status = 'active'
        ), 0),
        deposit_due_cents = COALESCE((
          SELECT SUM(deposit_due_cents) FROM rooms
          WHERE rooms.group_record_id = groups.id AND rooms.status = 'active'
        ), 0),
        cash_paid_cents = COALESCE((
          SELECT SUM(cash_paid_cents) FROM rooms
          WHERE rooms.group_record_id = groups.id AND rooms.status = 'active'
        ), 0),
        credit_paid_cents = COALESCE((
          SELECT SUM(credit_paid_cents) FROM rooms
          WHERE rooms.group_record_id = groups.id AND rooms.status = 'active'
        ), 0),
        deposit_paid_cents = COALESCE((
          SELECT SUM(cash_paid_cents + credit_paid_cents) FROM rooms
          WHERE rooms.group_record_id = groups.id AND rooms.status = 'active'
        ), 0)
    """)
  end

  defp block(kind, amount, operation_id, order),
    do: %{kind: kind, amount: amount, operation_id: operation_id, order: order}

  defp sum_amounts(blocks), do: Enum.reduce(blocks, 0, &(&1.amount + &2))
  defp bonus_value(cents), do: cents + div(cents * 10 + 50, 100)
  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp rows(repo, sql, params \\ []) do
    repo.query!(sql, params).rows
  end
end
