defmodule GroupStay.Repo.Migrations.AddRoomAndPaymentAccounting do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_fundings) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_id, :string, null: false
      add :funding_type, :string, null: false
      add :payment_operation_id, :string
      add :credit_lot_id, references(:credit_lots, on_delete: :restrict)
      add :amount_cents, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:room_fundings, [:group_id, :room_id])
    create index(:room_fundings, [:payment_operation_id])
    create index(:room_fundings, [:credit_lot_id])

    create table(:payment_dispositions, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true
      add :original_group_id, :string, null: false
      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:payment_dispositions, [:original_group_id])

    create table(:credit_entitlements) do
      add :credit_lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
      add :charged_back, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:credit_entitlements, [:payment_operation_id])
    create index(:credit_entitlements, [:credit_lot_id])

    flush()
    backfill_existing_accounting()
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:payment_dispositions)
    drop table(:room_fundings)

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:groups) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end
  end

  defp backfill_existing_accounting do
    groups = load_groups()
    operations = load_operations()

    Enum.each(groups, &persist_room_details/1)

    dispositions = backfill_payment_dispositions(groups, operations)
    backfill_room_fundings(groups, operations)
    backfill_credit_entitlements(groups, operations, dispositions)
  end

  defp load_groups do
    result =
      repo().query!("""
      SELECT group_id, arrival_on, departure_on, rate_plan, status, rooms,
             cash_paid_cents, credit_paid_cents, cash_refunded_cents,
             cash_retained_cents, cash_converted_to_credit_cents
      FROM groups
      """)

    Enum.map(result.rows, fn row ->
      values = Enum.zip(result.columns, row) |> Map.new()
      rooms = decode_json(values["rooms"])["items"] || []
      arrival = date!(values["arrival_on"])
      departure = date!(values["departure_on"])
      nights = Date.diff(departure, arrival)

      detailed_rooms =
        Enum.map(rooms, fn room ->
          lodging = room["nightly_rate_cents"] * nights

          due =
            if values["rate_plan"] == "flexible",
              do: div(lodging * 20 + 50, 100),
              else: lodging

          room
          |> Map.put("status", if(values["status"] == "active", do: "active", else: "cancelled"))
          |> Map.put("lodging_total_cents", lodging)
          |> Map.put("deposit_due_cents", due)
        end)

      values
      |> Map.put("rooms", detailed_rooms)
      |> Map.put("cash_paid_cents", values["cash_paid_cents"] || 0)
      |> Map.put("credit_paid_cents", values["credit_paid_cents"] || 0)
      |> Map.put("cash_refunded_cents", values["cash_refunded_cents"] || 0)
      |> Map.put("cash_retained_cents", values["cash_retained_cents"] || 0)
      |> Map.put(
        "cash_converted_to_credit_cents",
        values["cash_converted_to_credit_cents"] || 0
      )
    end)
  end

  defp load_operations do
    result =
      repo().query!("""
      SELECT commit_order, operation_id, operation_type, submitted_content, result
      FROM operations
      ORDER BY commit_order
      """)

    Enum.map(result.rows, fn row ->
      values = Enum.zip(result.columns, row) |> Map.new()

      values
      |> Map.update!("submitted_content", &decode_json/1)
      |> Map.update!("result", &decode_json/1)
    end)
  end

  defp persist_room_details(group) do
    repo().query!("UPDATE groups SET rooms = ? WHERE group_id = ?", [
      Jason.encode!(%{"items" => group["rooms"]}),
      group["group_id"]
    ])
  end

  defp backfill_payment_dispositions(groups, operations) do
    payments =
      Enum.filter(operations, fn operation ->
        operation["operation_type"] == "record_cash_payment" and
          operation["result"]["status"] == "applied"
      end)

    groups
    |> Enum.flat_map(fn group ->
      group_payments = Enum.filter(payments, &(&1["result"]["group_id"] == group["group_id"]))
      durable_total = Enum.sum_by(group_payments, & &1["result"]["amount_cents"])

      classes = [
        held_cents: group["cash_paid_cents"],
        refunded_cents: group["cash_refunded_cents"],
        retained_cents: group["cash_retained_cents"],
        converted_to_credit_cents: group["cash_converted_to_credit_cents"]
      ]

      legacy = max(Enum.sum_by(classes, &elem(&1, 1)) - durable_total, 0)
      {_legacy_disposition, classes} = consume_classes(classes, legacy)

      {rows, _classes} =
        Enum.map_reduce(group_payments, classes, fn payment, remaining_classes ->
          amount = payment["result"]["amount_cents"]
          {disposition, next_classes} = consume_classes(remaining_classes, amount)

          row = %{
            payment_operation_id: payment["operation_id"],
            original_group_id: group["group_id"],
            recorded_cents: amount,
            held_cents: disposition[:held_cents],
            refunded_cents: disposition[:refunded_cents],
            retained_cents: disposition[:retained_cents],
            converted_to_credit_cents: disposition[:converted_to_credit_cents],
            reduced_cents: 0,
            charged_back_cents: 0,
            commit_order: payment["commit_order"]
          }

          insert_disposition(row)
          {row, next_classes}
        end)

      rows
    end)
  end

  defp consume_classes(classes, amount) do
    {taken, remaining, _left} =
      Enum.reduce(classes, {%{}, [], amount}, fn {key, available}, {taken, rest, left} ->
        used = min(available, left)
        {Map.put(taken, key, used), [{key, available - used} | rest], left - used}
      end)

    {Map.merge(
       %{held_cents: 0, refunded_cents: 0, retained_cents: 0, converted_to_credit_cents: 0},
       taken
     ), Enum.reverse(remaining)}
  end

  defp insert_disposition(row) do
    now = NaiveDateTime.utc_now()

    repo().query!(
      """
      INSERT INTO payment_dispositions (
        payment_operation_id, original_group_id, recorded_cents, held_cents,
        refunded_cents, retained_cents, converted_to_credit_cents, reduced_cents,
        charged_back_cents, inserted_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?)
      """,
      [
        row.payment_operation_id,
        row.original_group_id,
        row.recorded_cents,
        row.held_cents,
        row.refunded_cents,
        row.retained_cents,
        row.converted_to_credit_cents,
        now,
        now
      ]
    )
  end

  defp backfill_room_fundings(groups, operations) do
    credit_streams = credit_streams_by_group()

    Enum.each(groups, fn group ->
      if group["status"] == "active" do
        durable =
          Enum.filter(operations, fn operation ->
            operation["result"]["status"] == "applied" and
              operation["result"]["group_id"] == group["group_id"] and
              operation["operation_type"] in ["record_cash_payment", "apply_hotel_credit"]
          end)

        durable_cash =
          durable
          |> Enum.filter(&(&1["operation_type"] == "record_cash_payment"))
          |> Enum.sum_by(& &1["result"]["amount_cents"])

        durable_credit =
          durable
          |> Enum.filter(&(&1["operation_type"] == "apply_hotel_credit"))
          |> Enum.sum_by(& &1["result"]["amount_cents"])

        legacy_cash = max(group["cash_paid_cents"] - durable_cash, 0)
        legacy_credit = max(group["credit_paid_cents"] - durable_credit, 0)
        stream = Map.get(credit_streams, group["group_id"], [])
        {legacy_credit_units, stream} = take_credit_units(stream, legacy_credit, nil)

        {durable_units, _stream} =
          Enum.map_reduce(durable, stream, fn operation, remaining_stream ->
            amount = operation["result"]["amount_cents"]

            if operation["operation_type"] == "record_cash_payment" do
              {[{:cash, operation["operation_id"], nil, amount}], remaining_stream}
            else
              take_credit_units(remaining_stream, amount, nil)
            end
          end)

        units =
          if(legacy_cash > 0, do: [{:cash, nil, nil, legacy_cash}], else: []) ++
            legacy_credit_units ++ List.flatten(durable_units)

        allocate_units(group, units)
      end
    end)
  end

  defp credit_streams_by_group do
    result =
      repo().query!("""
      SELECT group_id, credit_lot_id, amount_cents
      FROM credit_allocations
      ORDER BY id
      """)

    result.rows
    |> Enum.map(fn [group_id, lot_id, amount] -> {group_id, {lot_id, amount}} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp take_credit_units(stream, amount, payment_operation_id) do
    {units, remaining, left} =
      Enum.reduce(stream, {[], [], amount}, fn {lot_id, available}, {units, rest, left} ->
        used = min(available, left)

        units =
          if used > 0, do: [{:credit, payment_operation_id, lot_id, used} | units], else: units

        rest = if available > used, do: [{lot_id, available - used} | rest], else: rest
        {units, rest, left - used}
      end)

    if left > 0 do
      raise "credit allocations do not cover the group's funded credit"
    else
      {Enum.reverse(units), Enum.reverse(remaining)}
    end
  end

  defp allocate_units(group, units) do
    rooms = Enum.map(group["rooms"], &{&1, 0})

    Enum.reduce(units, rooms, fn {type, payment_id, lot_id, amount}, room_states ->
      {room_states, _left} =
        Enum.map_reduce(room_states, amount, fn {room, funded}, left ->
          used = min(max(room["deposit_due_cents"] - funded, 0), left)

          if used > 0 do
            insert_room_funding(
              group["group_id"],
              room["room_id"],
              type,
              payment_id,
              lot_id,
              used
            )
          end

          {{room, funded + used}, left - used}
        end)

      room_states
    end)
  end

  defp insert_room_funding(group_id, room_id, type, payment_id, lot_id, amount) do
    repo().query!(
      """
      INSERT INTO room_fundings (
        group_id, room_id, funding_type, payment_operation_id, credit_lot_id,
        amount_cents, inserted_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [
        group_id,
        room_id,
        Atom.to_string(type),
        payment_id,
        lot_id,
        amount,
        NaiveDateTime.utc_now()
      ]
    )
  end

  defp backfill_credit_entitlements(groups, operations, dispositions) do
    group_by_id = Map.new(groups, &{&1["group_id"], &1})
    operation_by_id = Map.new(operations, &{&1["operation_id"], &1})

    lots = repo().query!("SELECT id, source_operation_id FROM credit_lots ORDER BY id").rows

    Enum.each(lots, fn [lot_id, source_operation_id] ->
      with %{"result" => %{"group_id" => group_id}} <- operation_by_id[source_operation_id],
           group when not is_nil(group) <- group_by_id[group_id] do
        payment_contributors =
          dispositions
          |> Enum.filter(&(&1.original_group_id == group_id and &1.converted_to_credit_cents > 0))
          |> Enum.sort_by(& &1.commit_order)

        durable_principal = Enum.sum_by(payment_contributors, & &1.converted_to_credit_cents)
        legacy_principal = max(group["cash_converted_to_credit_cents"] - durable_principal, 0)

        contributors =
          if(legacy_principal > 0, do: [{nil, legacy_principal}], else: []) ++
            Enum.map(
              payment_contributors,
              &{&1.payment_operation_id, &1.converted_to_credit_cents}
            )

        {_running, _} =
          Enum.map_reduce(contributors, 0, fn {payment_id, principal}, running ->
            next = running + principal
            entitlement = bonus_value(next) - bonus_value(running)
            insert_entitlement(lot_id, payment_id, principal, entitlement)
            {{payment_id, entitlement}, next}
          end)
      else
        _ -> :ok
      end
    end)
  end

  defp insert_entitlement(lot_id, payment_id, principal, entitlement) do
    repo().query!(
      """
      INSERT INTO credit_entitlements (
        credit_lot_id, payment_operation_id, principal_cents, entitlement_cents,
        charged_back, inserted_at
      ) VALUES (?, ?, ?, ?, 0, ?)
      """,
      [lot_id, payment_id, principal, entitlement, NaiveDateTime.utc_now()]
    )
  end

  defp bonus_value(principal), do: principal + div(principal * 10 + 50, 100)

  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
  defp decode_json(value) when is_map(value), do: value
  defp date!(%Date{} = value), do: value
  defp date!(value), do: Date.from_iso8601!(value)
end
