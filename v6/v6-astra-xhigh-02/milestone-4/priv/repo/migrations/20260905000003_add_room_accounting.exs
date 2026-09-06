defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, :string, null: false
      # The audit record is inserted after domain application in the same transaction.
      # Legacy allocations deliberately have no payment identity.
      add :payment_operation_id, :string
      add :credit_lot_id, references(:credit_lots)
      add :funding_order, :integer, null: false
      add :amount_cents, :integer, null: false
      add :disposition, :string, null: false
    end

    create index(:room_allocations, [:group_id, :disposition])
    create index(:room_allocations, [:payment_operation_id])
    create index(:room_allocations, [:credit_lot_id, :disposition])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots), null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
    end

    create index(:credit_entitlements, [:payment_operation_id])
    flush()

    # Keep this upgrade independent of application schemas and future business logic.
    records =
      rows("SELECT * FROM partner_operations ORDER BY id")
      |> Enum.map(fn row -> Map.update!(row, "result", &decode/1) end)
      |> Enum.filter(&(&1["result"]["status"] == "applied"))
      |> Enum.group_by(& &1["result"]["group_id"])

    for group <- rows("SELECT * FROM groups ORDER BY group_id") do
      backfill(group, Map.get(records, group["group_id"], []))
    end
  end

  defp backfill(group, records) do
    rooms = decode(group["rooms"])

    nights =
      Date.diff(
        Date.from_iso8601!(group["departure_on"]),
        Date.from_iso8601!(group["arrival_on"])
      )

    rooms =
      Enum.map(rooms, fn room ->
        lodging = room["nightly_rate_cents"] * nights
        due = if group["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

        Map.merge(room, %{
          "status" => "active",
          "lodging_total_cents" => lodging,
          "deposit_due_cents" => due,
          "cash_paid_cents" => 0,
          "credit_paid_cents" => 0
        })
      end)

    funding = Enum.filter(records, &(&1["type"] in ["record_cash_payment", "apply_hotel_credit"]))
    cash_records = Enum.filter(funding, &(&1["type"] == "record_cash_payment"))
    credit_records = Enum.filter(funding, &(&1["type"] == "apply_hotel_credit"))

    cash_total =
      group["cash_paid_cents"] + group["cash_refunded_cents"] + group["cash_retained_cents"] +
        group["cash_converted_to_credit_cents"]

    legacy_cash = cash_total - Enum.sum(Enum.map(cash_records, & &1["result"]["amount_cents"]))

    credit =
      rows("SELECT * FROM credit_allocations WHERE group_id = ? ORDER BY id", [group["group_id"]])

    legacy_credit =
      Enum.sum(Enum.map(credit, & &1["amount_cents"])) -
        Enum.sum(Enum.map(credit_records, & &1["result"]["amount_cents"]))

    {senior_credit, credit} = take_credit(credit, legacy_credit)

    senior =
      [%{amount_cents: legacy_cash, payment_operation_id: nil, credit_lot_id: nil}] ++
        senior_credit

    {recorded, []} =
      Enum.map_reduce(funding, credit, fn record, credit ->
        if record["type"] == "record_cash_payment" do
          {[
             %{
               amount_cents: record["result"]["amount_cents"],
               payment_operation_id: record["operation_id"],
               credit_lot_id: nil
             }
           ], credit}
        else
          take_credit(credit, record["result"]["amount_cents"])
        end
      end)

    {rooms, allocations} =
      (senior ++ List.flatten(recorded))
      |> Enum.with_index(1)
      |> Enum.reduce({rooms, []}, fn {chunk, order}, {rooms, allocations} ->
        {rooms, {0, added}} =
          Enum.map_reduce(rooms, {chunk.amount_cents, []}, fn room, {needed, added} ->
            available =
              room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"]

            used = min(needed, available)
            field = if chunk.credit_lot_id, do: "credit_paid_cents", else: "cash_paid_cents"
            room = Map.update!(room, field, &(&1 + used))

            allocation =
              Map.merge(chunk, %{
                group_id: group["group_id"],
                room_id: room["room_id"],
                funding_order: order,
                amount_cents: used,
                disposition: "held"
              })

            {room, {needed - used, if(used > 0, do: [allocation | added], else: added)}}
          end)

        {rooms, allocations ++ Enum.reverse(added)}
      end)

    if group["status"] == "cancelled" do
      cash_disposition =
        cond do
          group["cash_converted_to_credit_cents"] > 0 -> "converted_to_credit"
          group["cash_retained_cents"] > 0 -> "retained"
          true -> "refunded"
        end

      if cash_disposition == "converted_to_credit" do
        # Any identifiable payment predates a durable cancellation in this release.
        # Entirely legacy lots need no targetable entitlement.
        for record <- records,
            record["type"] == "cancel_group",
            lot <-
              rows("SELECT id FROM credit_lots WHERE source_operation_id = ? AND guest_id = ?", [
                record["operation_id"],
                group["guest_id"]
              ]) do
          backfill_entitlements(lot["id"], Enum.filter(allocations, &is_nil(&1.credit_lot_id)))
        end
      end

      allocations =
        Enum.map(allocations, fn allocation ->
          Map.put(
            allocation,
            :disposition,
            if(allocation.credit_lot_id, do: "settled", else: cash_disposition)
          )
        end)

      insert_allocations(allocations)

      rooms =
        Enum.map(
          rooms,
          &Map.merge(&1, %{
            "status" => "cancelled",
            "deposit_due_cents" => 0,
            "cash_paid_cents" => 0,
            "credit_paid_cents" => 0
          })
        )

      repo().query!("UPDATE groups SET rooms = ?, lodging_total_cents = 0 WHERE group_id = ?", [
        Jason.encode!(rooms),
        group["group_id"]
      ])
    else
      insert_allocations(allocations)

      repo().query!("UPDATE groups SET rooms = ? WHERE group_id = ?", [
        Jason.encode!(rooms),
        group["group_id"]
      ])
    end
  end

  defp take_credit(credit, 0), do: {[], credit}

  defp take_credit([lot | rest], needed) when needed > 0 do
    used = min(lot["amount_cents"], needed)

    remainder =
      if used == lot["amount_cents"],
        do: rest,
        else: [Map.put(lot, "amount_cents", lot["amount_cents"] - used) | rest]

    {chunks, rest} = take_credit(remainder, needed - used)

    {[
       %{amount_cents: used, payment_operation_id: nil, credit_lot_id: lot["credit_lot_id"]}
       | chunks
     ], rest}
  end

  defp backfill_entitlements(lot_id, allocations) do
    allocations
    |> Enum.group_by(& &1.payment_operation_id)
    |> Enum.sort_by(fn {_, allocations} ->
      Enum.min(Enum.map(allocations, & &1.funding_order))
    end)
    |> Enum.reduce(0, fn {payment_id, allocations}, preceding ->
      through = preceding + Enum.sum(Enum.map(allocations, & &1.amount_cents))

      repo().insert_all("credit_entitlements", [
        %{
          credit_lot_id: lot_id,
          payment_operation_id: payment_id,
          amount_cents: bonus_value(through) - bonus_value(preceding)
        }
      ])

      through
    end)
  end

  defp bonus_value(cash), do: cash + div(cash * 10 + 50, 100)
  defp insert_allocations([]), do: :ok

  defp insert_allocations(allocations) do
    allocations |> Enum.chunk_every(500) |> Enum.each(&repo().insert_all("room_allocations", &1))
  end

  defp decode(value) when is_binary(value), do: Jason.decode!(value)
  defp decode(value), do: value

  defp rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = repo().query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:room_allocations)
    alter table(:credit_lots), do: remove(:unrecovered_clawback_cents)
  end
end
