defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration
  import Ecto.Query

  # Frozen schema snapshots and arithmetic keep upgrades independent of future
  # application schema and accounting changes.
  defmodule Group do
    use Ecto.Schema
    @primary_key {:group_id, :string, autogenerate: false}
    schema "groups" do
      field(:guest_id, :string)
      field(:property_id, :string)
      field(:booked_on, :date)
      field(:arrival_on, :date)
      field(:departure_on, :date)
      field(:rate_plan, :string)
      field(:policy_version, :string)
      field(:credit_paid_cents, :integer, default: 0)
      field(:cash_converted_to_credit_cents, :integer, default: 0)
      field(:status, :string, default: "active")
      field(:revision, :integer, default: 1)
      field(:rooms, {:array, :map})
      field(:lodging_total_cents, :integer)
      field(:deposit_due_cents, :integer)
      field(:deposit_paid_cents, :integer, default: 0)
      field(:cash_reduced_cents, :integer, default: 0)
      field(:cash_charged_back_cents, :integer, default: 0)
      field(:refunded_cents, :integer, default: 0)
      field(:retained_cents, :integer, default: 0)
    end
  end

  defmodule Record do
    use Ecto.Schema

    schema "operations" do
      field(:operation_id, :string)
      field(:type, :string)
      field(:submission, :map)
      field(:result, :map)
    end
  end

  defmodule Allocation do
    use Ecto.Schema

    schema "credit_allocations" do
      field(:group_id, :string)
      field(:room_id, :string)
      field(:credit_lot_id, :id)
      field(:amount_cents, :integer)
    end
  end

  defmodule Lot do
    use Ecto.Schema

    schema "credit_lots" do
      field(:unrecovered_clawback_cents, :integer, default: 0)
      field(:guest_id, :string)
      field(:source_operation_id, :string)
      field(:remaining_cents, :integer)
      field(:expires_on, :date)
    end
  end

  defmodule CashAllocation do
    use Ecto.Schema

    schema "cash_allocations" do
      field(:group_id, :string)
      field(:room_id, :string)
      field(:payment_operation_id, :string)
      field(:amount_cents, :integer)
      field(:disposition, :string, default: "held")
      field(:credit_lot_id, :id)
      field(:entitlement_cents, :integer, default: 0)
    end
  end

  def up do
    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :room_id, :string
    end

    create table(:cash_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, :string
      # Legacy cash deliberately has no durable operation identity.
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false
      add :credit_lot_id, references(:credit_lots)
      add :entitlement_cents, :integer, null: false, default: 0
    end

    create index(:cash_allocations, [:payment_operation_id])
    create index(:cash_allocations, [:group_id, :disposition])
    flush()
    backfill()
  end

  def down do
    drop table(:cash_allocations)
    alter table(:credit_allocations), do: remove(:room_id)
    alter table(:credit_lots), do: remove(:unrecovered_clawback_cents)

    alter table(:groups) do
      remove :cash_reduced_cents
      remove :cash_charged_back_cents
    end
  end

  # This upgrade reconstructs order from retained types and commit sequence, never
  # from business dates. Unrecorded funding is a single senior block, cash first.
  defp backfill do
    records = repo().all(from(r in Record, order_by: r.id))

    for group <- repo().all(Group) do
      funding =
        Enum.filter(records, fn record ->
          record.type in ["record_cash_payment", "apply_hotel_credit"] and
            record.result["status"] == "applied" and record.result["group_id"] == group.group_id
        end)

      rooms =
        initialize_rooms(
          group.rooms,
          Date.diff(group.departure_on, group.arrival_on),
          group.rate_plan
        )

      if group.status == "active" do
        credit =
          repo().all(from(a in Allocation, where: a.group_id == ^group.group_id, order_by: a.id))

        repo().delete_all(from(a in Allocation, where: a.group_id == ^group.group_id))
        recorded_cash = funding_total(funding, "record_cash_payment")
        recorded_credit = funding_total(funding, "apply_hotel_credit")
        legacy_cash = group.deposit_paid_cents - group.credit_paid_cents - recorded_cash
        legacy_credit = group.credit_paid_cents - recorded_credit
        rooms = allocate_cash(group, rooms, nil, legacy_cash)
        {rooms, credit} = allocate_credit(group, rooms, credit, legacy_credit)

        {rooms, []} =
          Enum.reduce(funding, {rooms, credit}, fn record, {rooms, credit} ->
            amount = record.result["amount_cents"]

            if record.type == "record_cash_payment" do
              {allocate_cash(group, rooms, record.operation_id, amount), credit}
            else
              allocate_credit(group, rooms, credit, amount)
            end
          end)

        repo().update!(Ecto.Changeset.change(group, rooms: rooms))
      else
        backfill_settlement(group, rooms, funding, records)
      end
    end
  end

  defp funding_total(records, type) do
    records
    |> Enum.filter(&(&1.type == type))
    |> Enum.map(& &1.result["amount_cents"])
    |> Enum.sum()
  end

  defp allocate_cash(group, rooms, payment_id, amount) do
    fund_rooms(rooms, amount, :cash, fn room_id, used ->
      repo().insert!(%CashAllocation{
        group_id: group.group_id,
        room_id: room_id,
        payment_operation_id: payment_id,
        amount_cents: used
      })
    end)
  end

  defp allocate_credit(_group, rooms, credit, 0), do: {rooms, credit}

  defp allocate_credit(group, rooms, [allocation | rest], amount) do
    used = min(amount, allocation.amount_cents)

    rooms =
      fund_rooms(rooms, used, :credit, fn room_id, cents ->
        repo().insert!(%Allocation{
          group_id: group.group_id,
          room_id: room_id,
          credit_lot_id: allocation.credit_lot_id,
          amount_cents: cents
        })
      end)

    credit =
      if used == allocation.amount_cents,
        do: rest,
        else: [%{allocation | amount_cents: allocation.amount_cents - used} | rest]

    allocate_credit(group, rooms, credit, amount - used)
  end

  defp backfill_settlement(group, rooms, funding, records) do
    total = group.refunded_cents + group.retained_cents + group.cash_converted_to_credit_cents

    disposition =
      cond do
        group.cash_converted_to_credit_cents > 0 -> "converted"
        group.retained_cents > 0 -> "retained"
        true -> "refunded"
      end

    cancellation =
      Enum.find(
        records,
        &(&1.type == "cancel_group" and
            &1.result["status"] == "applied" and &1.result["group_id"] == group.group_id)
      )

    lot =
      if cancellation,
        do: repo().get_by(Lot, source_operation_id: cancellation.operation_id)

    payments = Enum.filter(funding, &(&1.type == "record_cash_payment"))
    legacy = total - funding_total(payments, "record_cash_payment")
    sources = [{nil, legacy} | Enum.map(payments, &{&1.operation_id, &1.result["amount_cents"]})]

    slices =
      for {id, amount} <- sources, amount > 0 do
        repo().insert!(%CashAllocation{
          group_id: group.group_id,
          payment_operation_id: id,
          amount_cents: amount,
          disposition: disposition
        })
      end

    if lot do
      Enum.reduce(slices, 0, fn slice, principal ->
        next = principal + slice.amount_cents
        entitlement = next + div(next * 10 + 50, 100) - principal - div(principal * 10 + 50, 100)

        repo().update!(
          Ecto.Changeset.change(slice, credit_lot_id: lot.id, entitlement_cents: entitlement)
        )

        next
      end)
    end

    rooms = Enum.map(rooms, &Map.put(&1, "status", "cancelled"))
    repo().update!(Ecto.Changeset.change(group, rooms: rooms, lodging_total_cents: 0))
  end

  defp initialize_rooms(rooms, nights, plan) do
    Enum.map(rooms, fn room ->
      lodging = nights * room["nightly_rate_cents"]
      due = if plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

      Map.merge(room, %{
        "status" => "active",
        "lodging_total_cents" => lodging,
        "deposit_due_cents" => due,
        "cash_paid_cents" => 0,
        "credit_paid_cents" => 0
      })
    end)
  end

  defp fund_rooms(rooms, amount, kind, insert) do
    field = if kind == :cash, do: "cash_paid_cents", else: "credit_paid_cents"

    {rooms, 0} =
      Enum.map_reduce(rooms, amount, fn room, remaining ->
        outstanding =
          room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"]

        used = if room["status"] == "active", do: min(remaining, outstanding), else: 0
        if used > 0, do: insert.(room["room_id"], used)
        {Map.update!(room, field, &(&1 + used)), remaining - used}
      end)

    rooms
  end
end
