defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  import Ecto.Query

  alias GroupStay.Repo

  alias GroupStay.Reservations.{
    CashPayment,
    CreditLotCashContribution,
    GroupCreditPayment,
    GroupReservation,
    GroupRoom,
    HotelCreditLot,
    PartnerOperation,
    RoomFundingAllocation
  }

  @active "active"
  @cancelled "cancelled"

  def up do
    alter table(:group_reservations) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:group_rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:hotel_credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_payments) do
      add :payment_operation_id, :string, null: false

      add :group_reservation_id,
          references(:group_reservations, on_delete: :restrict),
          null: false

      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cash_payments, [:payment_operation_id])
    create index(:cash_payments, [:group_reservation_id])

    create table(:room_funding_allocations) do
      add :group_room_id, references(:group_rooms, on_delete: :delete_all), null: false
      add :funding_type, :string, null: false
      add :amount_cents, :integer, null: false
      add :cash_payment_id, references(:cash_payments, on_delete: :restrict)

      add :group_credit_payment_id,
          references(:group_credit_payments, on_delete: :restrict)

      timestamps(type: :utc_datetime)
    end

    create index(:room_funding_allocations, [:group_room_id])
    create index(:room_funding_allocations, [:cash_payment_id])
    create index(:room_funding_allocations, [:group_credit_payment_id])

    create table(:credit_lot_cash_contributions) do
      add :hotel_credit_lot_id, references(:hotel_credit_lots, on_delete: :delete_all),
        null: false

      add :cash_payment_id, references(:cash_payments, on_delete: :restrict)
      add :amount_cents, :integer, null: false
      add :funding_position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lot_cash_contributions, [:hotel_credit_lot_id, :funding_position])
    create index(:credit_lot_cash_contributions, [:cash_payment_id])

    flush()
    populate_room_accounting()
  end

  def down do
    drop table(:credit_lot_cash_contributions)
    drop table(:room_funding_allocations)
    drop table(:cash_payments)

    alter table(:hotel_credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:group_rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end

    alter table(:group_reservations) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end
  end

  # The previous releases stored only group-level funding. The release boundary is where that
  # history becomes room-level: a pre-idempotency remainder is deliberately one senior block,
  # then durable cash operations and existing credit consumptions keep their original order.
  defp populate_room_accounting do
    Repo.all(from(group in GroupReservation, order_by: [asc: group.id]))
    |> Enum.each(&populate_group/1)
  end

  defp populate_group(group) do
    rooms =
      Repo.all(
        from(room in GroupRoom,
          where: room.group_reservation_id == ^group.id,
          order_by: [asc: room.position]
        )
      )

    rooms = Enum.map(rooms, &initialize_room(&1, group))

    cash_payments = durable_cash_payments(group)

    if group.status == @active do
      legacy_cash =
        max(group.deposit_paid_cents - Enum.sum_by(cash_payments, & &1.recorded_cents), 0)

      credit_payments =
        Repo.all(
          from(payment in GroupCreditPayment,
            where: payment.group_reservation_id == ^group.id,
            order_by: [asc: payment.id]
          )
        )

      durable_funding = durable_funding_operations(group, cash_payments)

      legacy_credit =
        max(group.credit_paid_cents - Enum.sum_by(durable_funding, & &1.credit_cents), 0)

      {rooms, remaining_credit_payments} =
        rooms
        |> allocate_cash(legacy_cash, nil)
        |> allocate_legacy_credit(credit_payments, legacy_credit)

      _rooms = allocate_durable_funding(rooms, durable_funding, remaining_credit_payments)
    else
      settle_historic_payments(group, cash_payments)

      Repo.update!(
        Ecto.Changeset.change(group,
          lodging_total_cents: 0,
          deposit_due_cents: 0,
          deposit_paid_cents: 0,
          credit_paid_cents: 0,
          outstanding_deposit_cents: 0
        )
      )
    end
  end

  defp initialize_room(room, group) do
    nights = Date.diff(group.departure_on, group.arrival_on)
    lodging_total_cents = room.nightly_rate_cents * nights

    deposit_due_cents =
      case group.rate_plan do
        "flexible" -> div(lodging_total_cents * 20 + 50, 100)
        "advance_purchase" -> lodging_total_cents
      end

    status = if group.status == @active, do: @active, else: @cancelled

    Repo.update!(
      Ecto.Changeset.change(room,
        status: status,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents
      )
    )
  end

  defp durable_cash_payments(group) do
    Repo.all(
      from(operation in PartnerOperation,
        where: operation.operation_type == "record_cash_payment",
        order_by: [asc: operation.id]
      )
    )
    |> Enum.filter(&applied_cash_payment_for_group?(&1, group.partner_group_id))
    |> Enum.map(fn operation ->
      amount_cents = operation.result["amount_cents"]

      {:ok, payment} =
        Repo.insert(%CashPayment{
          payment_operation_id: operation.operation_id,
          group_reservation_id: group.id,
          recorded_cents: amount_cents
        })

      payment
    end)
  end

  defp applied_cash_payment_for_group?(operation, group_id) do
    is_map(operation.result) and operation.result["status"] == "applied" and
      operation.result["group_id"] == group_id and is_integer(operation.result["amount_cents"])
  end

  defp durable_funding_operations(group, cash_payments) do
    cash_by_operation_id = Map.new(cash_payments, &{&1.payment_operation_id, &1})

    Repo.all(from(operation in PartnerOperation, order_by: [asc: operation.id]))
    |> Enum.flat_map(fn operation ->
      result = operation.result

      if is_map(result) and result["status"] == "applied" and
           result["group_id"] == group.partner_group_id do
        case operation.operation_type do
          "record_cash_payment" ->
            case Map.fetch(cash_by_operation_id, operation.operation_id) do
              {:ok, payment} -> [%{type: :cash, payment: payment, credit_cents: 0}]
              :error -> []
            end

          "apply_hotel_credit" ->
            if is_integer(result["amount_cents"]),
              do: [%{type: :credit, credit_cents: result["amount_cents"]}],
              else: []

          _ ->
            []
        end
      else
        []
      end
    end)
  end

  defp allocate_legacy_credit(rooms, credit_payments, amount_cents) do
    allocate_credit_payments(rooms, credit_payments, amount_cents)
  end

  defp allocate_durable_funding(rooms, durable_funding, credit_payments) do
    {rooms, _credit_payments} =
      Enum.reduce(durable_funding, {rooms, credit_payments}, fn funding,
                                                                {allocated_rooms, credits} ->
        case funding do
          %{type: :cash, payment: payment} ->
            Repo.update!(Ecto.Changeset.change(payment, held_cents: payment.recorded_cents))
            {allocate_cash(allocated_rooms, payment.recorded_cents, payment.id), credits}

          %{type: :credit, credit_cents: amount_cents} ->
            allocate_credit_payments(allocated_rooms, credits, amount_cents)
        end
      end)

    rooms
  end

  defp allocate_credit_payments(rooms, credit_payments, amount_cents) do
    allocate_credit_stream(rooms, credit_payments, amount_cents)
  end

  defp allocate_credit_stream(rooms, credit_payments, 0),
    do: {rooms, credit_payments}

  defp allocate_credit_stream(_rooms, [], amount_cents) do
    raise "could not map #{amount_cents} cents of durable hotel credit to existing credit payments"
  end

  defp allocate_credit_stream(rooms, [payment | rest], amount_cents) do
    amount = min(payment.amount_cents, amount_cents)
    rooms = allocate_credit(rooms, amount, payment.id)
    remaining = amount_cents - amount

    if amount == payment.amount_cents do
      allocate_credit_stream(rooms, rest, remaining)
    else
      # A payment can span a prior (legacy) and durable operation. Preserve only its unconsumed
      # tail for the next operation; allocations still point at the original payment record.
      {rooms, [%{payment | amount_cents: payment.amount_cents - amount} | rest]}
    end
  end

  defp allocate_cash(rooms, amount_cents, cash_payment_id) do
    allocate(rooms, amount_cents, fn room, amount ->
      Repo.insert!(%RoomFundingAllocation{
        group_room_id: room.id,
        funding_type: "cash",
        amount_cents: amount,
        cash_payment_id: cash_payment_id
      })

      Repo.update!(Ecto.Changeset.change(room, cash_paid_cents: room.cash_paid_cents + amount))
    end)
  end

  defp allocate_credit(rooms, amount_cents, group_credit_payment_id) do
    allocate(rooms, amount_cents, fn room, amount ->
      Repo.insert!(%RoomFundingAllocation{
        group_room_id: room.id,
        funding_type: "credit",
        amount_cents: amount,
        group_credit_payment_id: group_credit_payment_id
      })

      Repo.update!(
        Ecto.Changeset.change(room, credit_paid_cents: room.credit_paid_cents + amount)
      )
    end)
  end

  defp allocate(rooms, amount_cents, callback) do
    {updated_rooms, remaining_cents} =
      Enum.map_reduce(rooms, amount_cents, fn room, remaining ->
        available = room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
        amount = min(max(available, 0), remaining)

        if amount > 0, do: callback.(room, amount)
        # Allocation type is encoded by its callback; fetch the persisted values so a following
        # funding block sees the room capacity left by this one.
        {if(amount > 0, do: Repo.get!(GroupRoom, room.id), else: room), remaining - amount}
      end)

    if remaining_cents == 0 do
      updated_rooms
    else
      raise "could not allocate #{remaining_cents} cents of pre-existing room funding"
    end
  end

  defp settle_historic_payments(group, cash_payments) do
    buckets = [
      refunded_cents: group.cash_refunded_cents,
      retained_cents: group.cash_retained_cents,
      converted_to_credit_cents: group.cash_converted_to_credit_cents
    ]

    {payment_buckets, remaining_buckets} =
      Enum.map_reduce(cash_payments, buckets, fn payment, remaining_buckets ->
        {payment_buckets, next_buckets} = take_buckets(payment.recorded_cents, remaining_buckets)
        {Map.put(payment_buckets, :payment, payment), next_buckets}
      end)

    Enum.each(payment_buckets, fn buckets_for_payment ->
      payment = buckets_for_payment.payment

      Repo.update!(
        Ecto.Changeset.change(payment,
          refunded_cents: buckets_for_payment.refunded_cents,
          retained_cents: buckets_for_payment.retained_cents,
          converted_to_credit_cents: buckets_for_payment.converted_to_credit_cents
        )
      )
    end)

    add_historic_credit_contributions(
      group,
      payment_buckets,
      Keyword.fetch!(remaining_buckets, :converted_to_credit_cents)
    )
  end

  defp take_buckets(amount_cents, buckets) do
    Enum.map_reduce(buckets, amount_cents, fn {bucket, available}, remaining ->
      amount = min(available, remaining)
      {{bucket, amount}, remaining - amount}
    end)
    |> then(fn {entries, _remaining} ->
      {Map.new(entries), subtract_buckets(buckets, Map.new(entries))}
    end)
  end

  defp subtract_buckets(buckets, taken) do
    Enum.map(buckets, fn {bucket, amount} -> {bucket, amount - Map.fetch!(taken, bucket)} end)
  end

  defp add_historic_credit_contributions(group, payment_buckets, legacy_converted_cents) do
    case historic_credit_source(group) do
      nil ->
        :ok

      operation_id ->
        case Repo.get_by(HotelCreditLot, source_operation_id: operation_id) do
          nil ->
            :ok

          lot ->
            contributions =
              if(legacy_converted_cents > 0,
                do: [{nil, legacy_converted_cents}],
                else: []
              ) ++
                (payment_buckets
                 |> Enum.map(&{&1.payment, &1.converted_to_credit_cents})
                 |> Enum.filter(fn {_payment, amount} -> amount > 0 end))

            contributions
            |> Enum.with_index()
            |> Enum.each(fn {{payment, amount}, position} ->
              Repo.insert!(%CreditLotCashContribution{
                hotel_credit_lot_id: lot.id,
                cash_payment_id: if(payment, do: payment.id),
                amount_cents: amount,
                funding_position: position
              })
            end)
        end
    end
  end

  defp historic_credit_source(group) do
    Repo.all(
      from(operation in PartnerOperation,
        where: operation.operation_type == "cancel_group",
        order_by: [desc: operation.id]
      )
    )
    |> Enum.find_value(fn operation ->
      result = operation.result

      if is_map(result) and result["status"] == "applied" and
           result["group_id"] == group.partner_group_id and
           is_integer(result["credit_issued_cents"]) and result["credit_issued_cents"] > 0 do
        operation.operation_id
      end
    end)
  end
end
