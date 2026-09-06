defmodule GroupStay.Reservations.Backfill do
  @moduledoc """
  Brings funding recorded before room accounting existed into the room-level model.

  Groups funded under earlier releases only know what they were paid in total, so the funding is
  laid out over the rooms the way the service would lay it out today: filling the deposit of each
  room in the group's original room order.

  Funding that predates durable operation records cannot be attributed to a payment, so it becomes
  one unattributed senior block per group - its aggregate cash first, then its hotel credit in the
  order the lots were consumed. Funding a durable record does account for follows it, in the order
  the records were committed, classified by the type the gateway submitted. Nothing about a
  group's cash, credit, or liability balances changes: only where those balances sit becomes
  visible.

  This runs once, from the migration that introduces room accounting, against a database that has
  no room allocations yet.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Partner.Journal
  alias GroupStay.Partner.Record
  alias GroupStay.Repo
  alias GroupStay.Reservations.CashAllocation
  alias GroupStay.Reservations.CreditApplication
  alias GroupStay.Reservations.CreditLot
  alias GroupStay.Reservations.Funding
  alias GroupStay.Reservations.Group
  alias GroupStay.Reservations.Room

  @funding_types ~w(record_cash_payment apply_hotel_credit)

  @doc """
  Lays out every group's existing funding over its rooms.

  `dispositions` says what became of the cash of groups that were already settled, keyed by the
  group's primary key. Anything not listed is still held against its rooms.
  """
  def run(dispositions \\ %{}) do
    funding = funding_records()
    conversions = conversion_operations()

    for group <- Repo.all(from g in Group, order_by: [asc: g.id]) do
      cancel_rooms(group)

      allocate(
        group,
        Map.get(dispositions, group.id, CashAllocation.held()),
        funding,
        conversions
      )

      Funding.refresh(group)
    end

    :ok
  end

  # A group that was already cancelled holds no rooms any more.
  defp cancel_rooms(%Group{status: "cancelled"} = group) do
    Repo.update_all(from(r in Room, where: r.group_id == ^group.id), set: [status: "cancelled"])
  end

  defp cancel_rooms(%Group{}), do: {0, nil}

  defp allocate(group, disposition, funding, conversions) do
    records = Map.get(funding, group.group_id, [])
    applications = applications(group)

    {legacy_applications, recorded_applications} =
      take_amount(
        applications,
        legacy_cents(group.credit_paid_cents, records, "apply_hotel_credit")
      )

    {recorded_items, _left} = Enum.map_reduce(records, recorded_applications, &record_items/2)

    items =
      [{:cash, nil, legacy_cents(group.cash_paid_cents, records, "record_cash_payment")}]
      |> Enum.concat(credit_items(legacy_applications))
      |> Enum.concat(Enum.concat(recorded_items))
      |> Enum.reject(fn {_kind, _source, amount_cents} -> amount_cents <= 0 end)

    group
    |> capacities()
    |> fill(items)
    |> write(group, disposition, converted_lot(group, conversions, disposition))
  end

  # Whatever a group was funded that no durable record accounts for came from before the records
  # existed, and can only be brought forward as one unattributed block.
  defp legacy_cents(paid_cents, records, type) do
    recorded_cents =
      records
      |> Enum.filter(&(&1.type == type))
      |> Enum.map(& &1.amount_cents)
      |> Enum.sum()

    max(paid_cents - recorded_cents, 0)
  end

  defp record_items(%{type: "record_cash_payment"} = record, applications),
    do: {[{:cash, record.operation_id, record.amount_cents}], applications}

  defp record_items(%{type: "apply_hotel_credit"} = record, applications) do
    {taken, rest} = take_amount(applications, record.amount_cents)
    {credit_items(taken), rest}
  end

  defp credit_items(applications),
    do: Enum.map(applications, &{:credit, &1, &1.amount_cents})

  # Credit was drawn lot by lot, so a record's credit is the applications it created, taken in the
  # order they were consumed.
  defp take_amount(applications, 0), do: {[], applications}
  defp take_amount([], _amount_cents), do: {[], []}

  defp take_amount([application | rest], amount_cents) do
    {taken, remaining} = take_amount(rest, max(amount_cents - application.amount_cents, 0))
    {[application | taken], remaining}
  end

  ## Laying funding over the rooms

  defp capacities(group) do
    Repo.all(
      from r in Room,
        where: r.group_id == ^group.id,
        order_by: [asc: r.position],
        select: {r.id, r.deposit_cents}
    )
  end

  defp fill(capacities, items) do
    {parts, _capacities} =
      Enum.flat_map_reduce(items, capacities, fn {kind, source, amount_cents}, capacities ->
        {taken, capacities} = take_rooms(capacities, amount_cents, [])
        {Enum.map(taken, fn {room_id, part} -> {kind, source, room_id, part} end), capacities}
      end)

    parts
  end

  defp take_rooms(capacities, 0, taken), do: {Enum.reverse(taken), capacities}
  defp take_rooms([], _amount_cents, taken), do: {Enum.reverse(taken), []}

  defp take_rooms([{room_id, capacity} | rest], amount_cents, taken) do
    part = min(capacity, amount_cents)
    taken = if part > 0, do: [{room_id, part} | taken], else: taken
    left = capacity - part
    capacities = if left > 0, do: [{room_id, left} | rest], else: rest

    take_rooms(capacities, amount_cents - part, taken)
  end

  ## Writing the allocations

  defp write(parts, group, disposition, lot) do
    {cash, credit} =
      Enum.split_with(parts, fn {kind, _source, _room, _amount} -> kind == :cash end)

    for {:cash, payment_operation_id, room_id, amount_cents} <- cash do
      Repo.insert!(%CashAllocation{
        group_id: group.id,
        room_id: room_id,
        payment_operation_id: payment_operation_id,
        converted_lot_id: lot && lot.id,
        amount_cents: amount_cents,
        status: disposition
      })
    end

    credit
    |> Enum.chunk_by(fn {_kind, application, _room, _amount} -> application.id end)
    |> Enum.each(&write_credit/1)
  end

  # An application that funded more than one room becomes one row per room, which leaves the lot
  # it came from and the credit it represents untouched.
  defp write_credit([{_kind, application, room_id, amount_cents} | rest]) do
    application
    |> Changeset.change(room_id: room_id, amount_cents: amount_cents)
    |> Repo.update!()

    for {_kind, _application, room_id, amount_cents} <- rest do
      Repo.insert!(%CreditApplication{
        group_id: application.group_id,
        room_id: room_id,
        credit_lot_id: application.credit_lot_id,
        amount_cents: amount_cents,
        applied_on: application.applied_on,
        status: application.status
      })
    end
  end

  ## Reading what earlier releases recorded

  defp applications(group) do
    Repo.all(from a in CreditApplication, where: a.group_id == ^group.id, order_by: [asc: a.id])
  end

  defp funding_records do
    Record
    |> where([r], r.type in @funding_types)
    |> order_by([r], asc: r.id)
    |> Repo.all()
    |> Enum.flat_map(&funding_record/1)
    |> Enum.group_by(& &1.group_id)
  end

  defp funding_record(record) do
    result = Journal.decode_result(record)

    if result["status"] == "applied" and is_binary(result["group_id"]) and
         is_integer(result["amount_cents"]) do
      [
        %{
          operation_id: record.operation_id,
          type: record.type,
          group_id: result["group_id"],
          amount_cents: result["amount_cents"]
        }
      ]
    else
      []
    end
  end

  # The lot a settled group's cash was converted into is only nameable when the cancellation that
  # issued it was itself durably recorded, which is exactly when its payments could have been.
  defp conversion_operations do
    Record
    |> where([r], r.type == "cancel_group")
    |> order_by([r], asc: r.id)
    |> Repo.all()
    |> Enum.flat_map(fn record ->
      result = Journal.decode_result(record)

      if result["status"] == "applied" and (result["credit_issued_cents"] || 0) > 0 do
        [{result["group_id"], record.operation_id}]
      else
        []
      end
    end)
    |> Map.new()
  end

  defp converted_lot(group, conversions, "converted") do
    case Map.fetch(conversions, group.group_id) do
      {:ok, source_operation_id} ->
        Repo.get_by(CreditLot, source_operation_id: source_operation_id, guest_id: group.guest_id)

      :error ->
        nil
    end
  end

  defp converted_lot(_group, _conversions, _disposition), do: nil
end
