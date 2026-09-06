defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration
  import Ecto.Query

  # Freeze the schema and allocation rules used by this upgrade. Future runtime
  # schema changes must not make an earlier database impossible to migrate.

  defmodule GroupRow do
    use Ecto.Schema

    @primary_key {:group_id, :string, autogenerate: false}
    schema "groups" do
      field(:funding_allocations, {:array, :map}, default: [])
      field(:guest_id, :string)
      field(:property_id, :string)
      field(:booked_on, :date)
      field(:arrival_on, :date)
      field(:departure_on, :date)
      field(:rate_plan, :string)
      field(:policy_version, :string)
      field(:cash_paid_cents, :integer, default: 0)
      field(:credit_paid_cents, :integer, default: 0)
      field(:converted_cents, :integer, default: 0)
      field(:credit_allocations, {:array, :map}, default: [])
      field(:status, :string, default: "active")
      field(:revision, :integer, default: 1)
      field(:rooms, {:array, :map})
      field(:lodging_total_cents, :integer)
      field(:deposit_due_cents, :integer)
      field(:deposit_paid_cents, :integer, default: 0)
      field(:refunded_cents, :integer, default: 0)
      field(:retained_cents, :integer, default: 0)
    end
  end

  defmodule LotRow do
    use Ecto.Schema

    schema "credit_lots" do
      field(:unrecovered_clawback_cents, :integer, default: 0)
      field(:entitlements, :map, default: %{})
      field(:guest_id, :string)
      field(:source_operation_id, :string)
      field(:remaining_cents, :integer)
      field(:expires_on, :date)
    end
  end

  defmodule OperationRow do
    use Ecto.Schema

    schema "operations" do
      field(:operation_id, :string)
      field(:type, :string)
      field(:submission, :map)
      field(:result, :map)
    end
  end

  defmodule Accounting do
    @moduledoc "Ordered funding slices and their current cash dispositions."

    def rooms(group) do
      nights = Date.diff(group.departure_on, group.arrival_on)

      Enum.map(group.rooms, fn room ->
        lodging = room["nightly_rate_cents"] * nights
        due = if group.rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

        Map.merge(room, %{
          "status" => group.status,
          "lodging_total_cents" => lodging,
          "deposit_due_cents" => due,
          "cash_paid_cents" => 0,
          "credit_paid_cents" => 0
        })
      end)
    end

    def allocate(rooms, slices, kind, amount, payment \\ nil, lot \\ nil) do
      {0, added} =
        Enum.reduce(rooms, {amount, []}, fn room, {left, added} ->
          used =
            Enum.sum(
              for s <- slices ++ added,
                  s["room_id"] == room["room_id"] and s["disposition"] == "held",
                  do: s["amount_cents"]
            )

          take =
            if room["status"] == "active",
              do: min(left, room["deposit_due_cents"] - used),
              else: 0

          entry = %{
            "room_id" => room["room_id"],
            "kind" => kind,
            "amount_cents" => take,
            "payment_operation_id" => payment,
            "lot_id" => lot,
            "disposition" => "held"
          }

          {left - take, if(take > 0, do: added ++ [entry], else: added)}
        end)

      slices ++ added
    end

    def totals(rooms, slices) do
      rooms =
        Enum.map(rooms, fn room ->
          active = room["status"] == "active"

          held =
            Enum.filter(
              slices,
              &(&1["room_id"] == room["room_id"] and &1["disposition"] == "held")
            )

          Map.merge(room, %{
            "deposit_due_cents" => if(active, do: room["deposit_due_cents"], else: 0),
            "cash_paid_cents" => sum(held, "cash"),
            "credit_paid_cents" => sum(held, "credit")
          })
        end)

      active = Enum.filter(rooms, &(&1["status"] == "active"))
      cash = Enum.sum(Enum.map(active, & &1["cash_paid_cents"]))
      credit = Enum.sum(Enum.map(active, & &1["credit_paid_cents"]))

      %{
        rooms: rooms,
        funding_allocations: slices,
        cash_paid_cents: cash,
        credit_paid_cents: credit,
        deposit_paid_cents: cash + credit,
        deposit_due_cents: Enum.sum(Enum.map(active, & &1["deposit_due_cents"])),
        lodging_total_cents: Enum.sum(Enum.map(active, & &1["lodging_total_cents"])),
        credit_allocations:
          for(
            s <- slices,
            s["kind"] == "credit" and s["disposition"] == "held",
            do: Map.take(s, ~w(lot_id amount_cents))
          ),
        status: if(active == [], do: "cancelled", else: "active")
      }
    end

    defp sum(slices, kind),
      do: Enum.sum(for s <- slices, s["kind"] == kind, do: s["amount_cents"])
  end

  def up do
    alter table(:groups) do
      add :funding_allocations, {:array, :map}, null: false, default: []
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
      add :entitlements, :map, null: false, default: %{}
    end

    flush()
    # The old release retained consumption order; generated audit keys order commits.
    records_by_group =
      repo().all(from(o in OperationRow, order_by: o.id))
      |> Enum.filter(&(&1.result["status"] == "applied"))
      |> Enum.group_by(& &1.result["group_id"])

    for group <- repo().all(GroupRow), group.rooms != [] do
      records = Map.get(records_by_group, group.group_id, [])

      funding = Enum.filter(records, &(&1.type in ["record_cash_payment", "apply_hotel_credit"]))

      cash =
        if group.status == "active",
          do: group.cash_paid_cents,
          else: group.refunded_cents + group.retained_cents + group.converted_cents

      recorded_cash =
        Enum.sum(for o <- funding, o.type == "record_cash_payment", do: o.result["amount_cents"])

      recorded_credit =
        Enum.sum(for o <- funding, o.type == "apply_hotel_credit", do: o.result["amount_cents"])

      rooms = Accounting.rooms(%{group | status: "active"})
      slices = Accounting.allocate(rooms, [], "cash", max(0, cash - recorded_cash))

      {senior, remaining} =
        split_credit(group.credit_allocations, max(0, group.credit_paid_cents - recorded_credit))

      slices = allocate_credit(rooms, slices, senior)

      {slices, _} =
        Enum.reduce(funding, {slices, remaining}, fn o, {slices, remaining} ->
          if o.type == "record_cash_payment" do
            {Accounting.allocate(
               rooms,
               slices,
               "cash",
               o.result["amount_cents"],
               o.operation_id
             ), remaining}
          else
            {used, remaining} = split_credit(remaining, o.result["amount_cents"])
            {allocate_credit(rooms, slices, used), remaining}
          end
        end)

      slices =
        if group.status == "cancelled" do
          disposition =
            cond do
              group.converted_cents > 0 -> "converted_to_credit"
              group.refunded_cents > 0 -> "refunded"
              true -> "retained"
            end

          slices = Enum.map(slices, &Map.put(&1, "disposition", disposition))

          if disposition == "converted_to_credit" do
            cancellation = Enum.find(records, &(&1.type == "cancel_group"))

            lot =
              cancellation &&
                repo().get_by(LotRow, source_operation_id: cancellation.operation_id)

            if lot do
              repo().update!(Ecto.Changeset.change(lot, entitlements: entitlements(slices)))
            end
          end

          slices
        else
          slices
        end

      rooms =
        if group.status == "cancelled",
          do: Enum.map(rooms, &Map.put(&1, "status", "cancelled")),
          else: rooms

      changes = Accounting.totals(rooms, slices)
      repo().update!(Ecto.Changeset.change(group, changes))
    end
  end

  defp allocate_credit(rooms, slices, lots) do
    Enum.reduce(lots, slices, fn a, acc ->
      Accounting.allocate(rooms, acc, "credit", a["amount_cents"], nil, a["lot_id"])
    end)
  end

  defp split_credit(lots, amount) do
    {_, used, rest} =
      Enum.reduce(lots, {amount, [], []}, fn a, {left, used, rest} ->
        take = min(left, a["amount_cents"])

        {left - take, if(take > 0, do: used ++ [Map.put(a, "amount_cents", take)], else: used),
         if(take < a["amount_cents"],
           do: rest ++ [Map.put(a, "amount_cents", a["amount_cents"] - take)],
           else: rest
         )}
      end)

    {used, rest}
  end

  defp entitlements(slices) do
    {_, values} =
      Enum.reduce(slices, {0, %{}}, fn s, {total, values} ->
        amount = s["amount_cents"]
        value = bonus(total + amount) - bonus(total)
        key = s["payment_operation_id"] || ""
        {total + amount, Map.update(values, key, value, &(&1 + value))}
      end)

    values
  end

  defp bonus(n), do: n + div(n * 10 + 50, 100)

  def down do
    alter table(:groups), do: remove(:funding_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
      remove :entitlements
    end
  end
end
