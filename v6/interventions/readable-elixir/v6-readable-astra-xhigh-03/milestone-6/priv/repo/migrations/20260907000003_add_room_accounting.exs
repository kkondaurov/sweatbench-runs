defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    create table(:cash_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, :string, null: false
      add :payment_operation_id, :string

      add :amount_cents, :integer,
        null: false,
        check: %{
          name: "balanced_cash_allocation",
          expr:
            "amount_cents > 0 AND held_cents >= 0 AND refunded_cents >= 0 AND retained_cents >= 0 AND converted_to_credit_cents >= 0 AND reduced_cents >= 0 AND charged_back_cents >= 0 AND amount_cents = held_cents + refunded_cents + retained_cents + converted_to_credit_cents + reduced_cents + charged_back_cents"
        }

      for field <- ~w(held refunded retained converted_to_credit reduced charged_back)a do
        add :"#{field}_cents", :integer, null: false, default: 0
      end
    end

    create index(:cash_allocations, [:group_id, :room_id])
    create index(:cash_allocations, [:payment_operation_id])

    create table(:room_credit_allocations) do
      add :group_id, references(:groups, column: :group_id, type: :string), null: false
      add :room_id, :string, null: false
      add :credit_lot_id, references(:credit_lots), null: false
      add :credit_allocation_id, references(:credit_allocations), null: false
      add :amount_cents, :integer, null: false
      add :active, :boolean, null: false, default: true
    end

    create index(:room_credit_allocations, [:group_id, :room_id])
    create index(:room_credit_allocations, [:credit_lot_id, :active])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots), null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
    end

    create index(:credit_entitlements, [:payment_operation_id])
    create index(:credit_entitlements, [:credit_lot_id])

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    drop unique_index(:credit_lots, [:source_group_id])
    create index(:credit_lots, [:source_group_id])
    flush()

    # Keep this backfill independent of application schemas and transitions: it
    # describes the previous release's storage, even after those modules evolve.
    recorded_by_group =
      rows("SELECT * FROM operation_records ORDER BY id")
      |> Enum.map(&Map.update!(&1, "result", fn result -> Jason.decode!(result) end))
      |> Enum.filter(fn record ->
        record["result"]["status"] == "applied" and
          record["type"] in ["record_cash_payment", "apply_hotel_credit"]
      end)
      |> Enum.group_by(& &1["result"]["group_id"])

    Enum.each(rows("SELECT * FROM groups ORDER BY group_id"), fn group ->
      backfill_group(group, Map.get(recorded_by_group, group["group_id"], []))
    end)
  end

  def down do
    applied_changes =
      rows("""
      SELECT id FROM operation_records
      WHERE type IN ('cancel_rooms', 'reduce_cash_payment', 'charge_back_payment')
        AND json_extract(result, '$.status') = 'applied'
      LIMIT 1
      """)

    if applied_changes != [] do
      raise Ecto.MigrationError,
            "cannot remove room accounting after room cancellations or payment corrections have been applied"
    end

    drop table(:credit_entitlements)
    drop table(:room_credit_allocations)
    drop table(:cash_allocations)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    # Multiple cancellation lots cannot be represented by the earlier release.
    # Its unique index deliberately prevents an unsafe downgrade of such data.
    drop index(:credit_lots, [:source_group_id])
    create unique_index(:credit_lots, [:source_group_id])
  end

  defp backfill_group(group, recorded) do
    group_id = group["group_id"]
    active? = group["status"] == "active"
    cash_entries = rows("SELECT * FROM cash_entries WHERE group_id = ? ORDER BY id", [group_id])
    credit = rows("SELECT * FROM credit_allocations WHERE group_id = ? ORDER BY id", [group_id])

    sources = funding_sources(group, recorded, cash_entries, credit)

    rooms = priced_rooms(group)
    disposition = cash_disposition(active?, cash_entries)

    rooms = allocate_sources(group_id, rooms, sources, disposition, active?)

    if disposition == :converted_to_credit_cents, do: backfill_entitlements(group_id, sources)

    rooms =
      if active?,
        do: rooms,
        else:
          Enum.map(rooms, fn room ->
            Map.merge(room, %{
              "status" => "cancelled",
              "deposit_due_cents" => 0,
              "cash_paid_cents" => 0,
              "credit_paid_cents" => 0
            })
          end)

    lodging = if active?, do: group["lodging_total_cents"], else: 0

    repo().query!("UPDATE groups SET rooms = ?, lodging_total_cents = ? WHERE group_id = ?", [
      Jason.encode!(rooms),
      lodging,
      group_id
    ])
  end

  # Before the journal, only aggregate cash and credit redemption order can
  # be known. Durable types distinguish cash from credit with identical result
  # shapes; journal IDs, not dates or partner identifiers, establish seniority.
  defp funding_sources(group, recorded, cash_entries, credit) do
    recorded_cash =
      recorded
      |> Enum.filter(&(&1["type"] == "record_cash_payment"))
      |> Enum.map(& &1["result"]["amount_cents"])
      |> Enum.sum()

    total_cash =
      if group["status"] == "active" do
        group["deposit_paid_cents"] - group["credit_paid_cents"]
      else
        cash_entries |> Enum.filter(&(&1["kind"] == "payment")) |> sum_amounts()
      end

    recorded_credit_ids =
      recorded
      |> Enum.filter(&(&1["type"] == "apply_hotel_credit"))
      |> Enum.map(& &1["operation_id"])

    senior_credit = Enum.reject(credit, &(&1["operation_id"] in recorded_credit_ids))
    senior_cash = total_cash - recorded_cash

    sources =
      [{:cash, nil, senior_cash}] ++ Enum.map(senior_credit, &{:credit, &1, &1["amount_cents"]})

    sources ++
      Enum.flat_map(recorded, fn record ->
        if record["type"] == "record_cash_payment" do
          [{:cash, record["operation_id"], record["result"]["amount_cents"]}]
        else
          credit
          |> Enum.filter(&(&1["operation_id"] == record["operation_id"]))
          |> Enum.map(&{:credit, &1, &1["amount_cents"]})
        end
      end)
  end

  defp allocate_sources(group_id, rooms, sources, disposition, active?) do
    Enum.reduce(sources, rooms, fn {kind, source, amount}, rooms ->
      {rooms, 0} =
        Enum.map_reduce(rooms, amount, fn room, remaining ->
          outstanding =
            room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"]

          portion = min(outstanding, remaining)

          if portion > 0,
            do:
              insert_portion(
                group_id,
                room["room_id"],
                kind,
                source,
                portion,
                disposition,
                active?
              )

          field = if kind == :cash, do: "cash_paid_cents", else: "credit_paid_cents"
          {Map.update!(room, field, &(&1 + portion)), remaining - portion}
        end)

      rooms
    end)
  end

  defp backfill_entitlements(group_id, sources) do
    [lot] = rows("SELECT id FROM credit_lots WHERE source_group_id = ?", [group_id])

    sources
    |> Enum.filter(fn {kind, _, amount} -> kind == :cash and amount > 0 end)
    |> Enum.reduce(0, fn {:cash, payment, amount}, previous ->
      repo().insert_all("credit_entitlements", [
        %{
          credit_lot_id: lot["id"],
          payment_operation_id: payment,
          amount_cents: credit_value(previous + amount) - credit_value(previous)
        }
      ])

      previous + amount
    end)
  end

  defp priced_rooms(group) do
    nights =
      Date.diff(
        Date.from_iso8601!(group["departure_on"]),
        Date.from_iso8601!(group["arrival_on"])
      )

    Enum.map(Jason.decode!(group["rooms"]), fn room ->
      lodging = room["nightly_rate_cents"] * nights

      deposit =
        if group["rate_plan"] == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

      Map.merge(room, %{
        "status" => "active",
        "lodging_total_cents" => lodging,
        "deposit_due_cents" => deposit,
        "cash_paid_cents" => 0,
        "credit_paid_cents" => 0
      })
    end)
  end

  defp insert_portion(group, room, :cash, payment, amount, disposition, _active?) do
    repo().insert_all("cash_allocations", [
      %{group_id: group, room_id: room, payment_operation_id: payment, amount_cents: amount}
      |> Map.put(disposition, amount)
    ])
  end

  defp insert_portion(group, room, :credit, allocation, amount, _disposition, active?) do
    repo().insert_all("room_credit_allocations", [
      %{
        group_id: group,
        room_id: room,
        credit_lot_id: allocation["credit_lot_id"],
        credit_allocation_id: allocation["id"],
        amount_cents: amount,
        # Schemaless inserts bypass Ecto's boolean dumper. SQLite predicates
        # require integer booleans, not the strings "true" and "false".
        active: if(active?, do: 1, else: 0)
      }
    ])
  end

  defp cash_disposition(true, _entries), do: :held_cents

  defp cash_disposition(false, entries) do
    cond do
      Enum.any?(entries, &(&1["kind"] == "credit_conversion")) -> :converted_to_credit_cents
      Enum.any?(entries, &(&1["kind"] == "retention")) -> :retained_cents
      true -> :refunded_cents
    end
  end

  defp sum_amounts(entries), do: Enum.reduce(entries, 0, &(&2 + &1["amount_cents"]))
  defp credit_value(cash), do: cash + div(cash * 10 + 50, 100)

  defp rows(sql, params \\ []) do
    %{columns: columns, rows: rows} = repo().query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end
end
