defmodule GroupStay.Groups.Backfill do
  @moduledoc """
  Carries funding created before durable operation records forward into room
  allocations.

  Each group's unattributed funding becomes one senior block: its aggregate
  cash is allocated first, then its hotel-credit lots in original consumption
  order. That block is allocated before funding represented by durable
  operation records, which is classified by the retained operation type and
  allocated in durable-record commit order. Creating room allocations never
  changes any aggregate cash, credit, or liability balance.

  The migration for room accounting runs this once over existing data; at
  runtime it is applied lazily to any group a read or operation encounters,
  so databases upgraded by either path converge on the same state.
  """

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Credit.Application
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations
  alias GroupStay.Operations.Record

  @flexible_deposit_percent 20

  @doc """
  Brings every group that still predates room accounting forward. Idempotent.
  """
  def backfill_all do
    backfill_rooms()
    backfill_funding()
    :ok
  end

  ## room amounts

  defp backfill_rooms do
    Room
    |> where([r], is_nil(r.deposit_due_cents))
    |> select([r], r.group_id)
    |> distinct(true)
    |> Repo.all()
    |> Enum.each(&backfill_group_rooms/1)
  end

  defp backfill_group_rooms(group_id) do
    group = Repo.get!(Group, group_id)
    nights = Date.diff(group.departure_on, group.arrival_on)
    room_status = if group.status == "active", do: "active", else: "cancelled"

    Room
    |> where([r], r.group_id == ^group_id)
    |> Repo.all()
    |> Enum.each(fn room ->
      lodging_cents = room.nightly_rate_cents * nights

      deposit_due_cents =
        if group.rate_plan == "flexible" do
          Operations.percentage(lodging_cents, @flexible_deposit_percent)
        else
          lodging_cents
        end

      room
      |> change(
        status: room_status,
        lodging_cents: lodging_cents,
        deposit_due_cents: deposit_due_cents
      )
      |> Repo.update!()
    end)
  end

  ## funding allocations

  defp backfill_funding do
    Group
    |> where([g], g.deposit_paid_cents > 0)
    |> where([g], g.status == "active" or g.deposit_paid_cents > g.credit_paid_cents)
    |> where(
      [g],
      fragment(
        "NOT EXISTS (SELECT 1 FROM room_allocations WHERE room_allocations.group_id = ?)",
        g.group_id
      )
    )
    |> Repo.all()
    |> Enum.each(&backfill_group_funding/1)
  end

  defp backfill_group_funding(%Group{} = group) do
    rooms =
      Room
      |> where([r], r.group_id == ^group.group_id)
      |> order_by([r], asc: r.position)
      |> Repo.all()

    if rooms != [] do
      records = recorded_funding(group.group_id)
      applications = applications_for(group.group_id)

      if group.status == "active" do
        backfill_active(group, rooms, records, applications)
      else
        backfill_cancelled(group, rooms, records)
      end
    end
  end

  defp recorded_funding(group_id) do
    Record
    |> where([r], r.type in ~w(record_cash_payment apply_hotel_credit))
    |> order_by([r], asc: r.id)
    |> Repo.all()
    |> Enum.map(fn record -> {record.type, record.operation_id, Jason.decode!(record.result)} end)
    |> Enum.filter(fn {_type, _operation_id, result} ->
      result["status"] == "applied" and result["group_id"] == group_id
    end)
  end

  defp applications_for(group_id) do
    Application
    |> where([a], a.group_id == ^group_id)
    |> order_by([a], asc: a.id)
    |> Repo.all()
  end

  # An active group's funding is carried forward as held allocations: the
  # unattributed senior block (aggregate cash, then credit lots in original
  # consumption order) fills rooms first, then each durable record allocates
  # in commit order.
  defp backfill_active(group, rooms, records, applications) do
    cash_paid_cents = group.deposit_paid_cents - group.credit_paid_cents
    legacy_cash = cash_paid_cents - recorded_total(records, "record_cash_payment")
    legacy_credit = group.credit_paid_cents - recorded_total(records, "apply_hotel_credit")

    {legacy_applications, remaining_applications} = split_prefix(applications, legacy_credit)

    legacy_chunks =
      [
        {nil, nil, legacy_cash}
        | Enum.map(legacy_applications, &{nil, &1.lot_id, &1.amount_cents})
      ]

    chunks = legacy_chunks ++ recorded_chunks(records, remaining_applications)

    Groups.fill_allocations(group.group_id, rooms, %{}, chunks, "held")
  end

  # A cancelled group's funding was settled whole when the group was
  # cancelled: every cash allocation receives the group's settlement
  # disposition, and its recorded payments keep their operation identity so
  # they can later be reconciled, reduced, or charged back. Applied credit
  # was already restored or consumed at cancellation.
  defp backfill_cancelled(group, rooms, records) do
    disposition =
      cond do
        group.refunded_cents > 0 -> "refunded"
        group.retained_cents > 0 -> "retained"
        group.converted_to_credit_cents > 0 -> "converted"
        true -> "held"
      end

    legacy_cash =
      group.deposit_paid_cents - group.credit_paid_cents -
        recorded_total(records, "record_cash_payment")

    chunks =
      [{nil, nil, legacy_cash} | recorded_chunks(records, [])]

    Groups.fill_allocations(group.group_id, rooms, %{}, chunks, disposition)

    group
    |> change(
      lodging_total_cents: 0,
      deposit_due_cents: 0,
      deposit_paid_cents: 0,
      credit_paid_cents: 0
    )
    |> Repo.update!()
  end

  defp recorded_total(records, type) do
    records
    |> Enum.filter(fn {record_type, _operation_id, _result} -> record_type == type end)
    |> Enum.reduce(0, fn {_type, _operation_id, result}, sum -> sum + result["amount_cents"] end)
  end

  # One funding chunk per durable record, in commit order: cash payments
  # become a single cash chunk; credit applications take their lot splits
  # from the next application rows in original consumption order.
  defp recorded_chunks(records, applications) do
    {chunks, _applications} =
      Enum.reduce(records, {[], applications}, fn
        {"record_cash_payment", operation_id, result}, {chunks, apps} ->
          {[{operation_id, nil, result["amount_cents"]} | chunks], apps}

        {"apply_hotel_credit", operation_id, result}, {chunks, apps} ->
          {taken, rest} = split_prefix(apps, result["amount_cents"])

          lot_chunks =
            taken
            |> Enum.map(&{operation_id, &1.lot_id, &1.amount_cents})
            |> Enum.reverse()

          {lot_chunks ++ chunks, rest}
      end)

    Enum.reverse(chunks)
  end

  defp split_prefix(apps, target), do: split_prefix(apps, target, [])
  defp split_prefix(rest, target, acc) when target <= 0, do: {Enum.reverse(acc), rest}

  defp split_prefix([app | rest], target, acc),
    do: split_prefix(rest, target - app.amount_cents, [app | acc])

  defp split_prefix([], _target, acc), do: {Enum.reverse(acc), []}
end
