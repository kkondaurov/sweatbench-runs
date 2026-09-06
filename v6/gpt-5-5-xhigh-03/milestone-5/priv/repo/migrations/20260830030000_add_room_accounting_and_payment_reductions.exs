defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:group_rooms) do
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :status, :string, null: false, default: "active"
    end

    alter table(:guest_credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:cash_fundings) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :recorded_cents, :integer, null: false, default: 0
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:cash_fundings, [:group_id])
    create unique_index(:cash_fundings, [:payment_operation_id])

    create table(:room_funding_allocations) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :room_id, references(:group_rooms, on_delete: :delete_all), null: false
      add :funding_type, :string, null: false
      add :amount_cents, :integer, null: false
      add :source_operation_id, :string
      add :cash_funding_id, references(:cash_fundings, on_delete: :delete_all)
      add :credit_lot_id, references(:guest_credit_lots, on_delete: :restrict)

      timestamps(type: :utc_datetime)
    end

    create index(:room_funding_allocations, [:group_id])
    create index(:room_funding_allocations, [:room_id])
    create index(:room_funding_allocations, [:cash_funding_id])
    create index(:room_funding_allocations, [:credit_lot_id])

    create table(:credit_lot_cash_entitlements) do
      add :credit_lot_id, references(:guest_credit_lots, on_delete: :delete_all), null: false
      add :cash_funding_id, references(:cash_fundings, on_delete: :delete_all), null: false
      add :principal_cents, :integer, null: false, default: 0
      add :entitlement_cents, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:credit_lot_cash_entitlements, [:credit_lot_id])
    create index(:credit_lot_cash_entitlements, [:cash_funding_id])

    flush()

    backfill_room_totals()
    backfill_cash_funding()
    backfill_active_credit_allocations()
    backfill_credit_entitlements()
  end

  def down do
    drop table(:credit_lot_cash_entitlements)
    drop table(:room_funding_allocations)
    drop table(:cash_fundings)

    alter table(:guest_credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:group_rooms) do
      remove :status
      remove :deposit_due_cents
      remove :lodging_total_cents
    end
  end

  defp backfill_room_totals do
    execute("""
    UPDATE group_rooms
    SET
      lodging_total_cents =
        nightly_rate_cents *
        CAST(
          julianday((SELECT departure_on FROM groups WHERE groups.id = group_rooms.group_id)) -
          julianday((SELECT arrival_on FROM groups WHERE groups.id = group_rooms.group_id))
          AS INTEGER
        ),
      deposit_due_cents =
        CASE
          WHEN (SELECT rate_plan FROM groups WHERE groups.id = group_rooms.group_id) = 'advance_purchase'
          THEN
            nightly_rate_cents *
            CAST(
              julianday((SELECT departure_on FROM groups WHERE groups.id = group_rooms.group_id)) -
              julianday((SELECT arrival_on FROM groups WHERE groups.id = group_rooms.group_id))
              AS INTEGER
            )
          ELSE
            CAST(
              (
                nightly_rate_cents *
                CAST(
                  julianday((SELECT departure_on FROM groups WHERE groups.id = group_rooms.group_id)) -
                  julianday((SELECT arrival_on FROM groups WHERE groups.id = group_rooms.group_id))
                  AS INTEGER
                ) *
                20 + 50
              ) / 100 AS INTEGER
            )
        END,
      status =
        CASE
          WHEN (SELECT status FROM groups WHERE groups.id = group_rooms.group_id) = 'cancelled'
          THEN 'cancelled'
          ELSE 'active'
        END
    """)
  end

  defp backfill_cash_funding do
    now = DateTime.utc_now(:second)
    groups = all_groups()
    payments_by_group = durable_cash_payments_by_group()

    Enum.each(groups, fn group ->
      payments = Map.get(payments_by_group, group.group_id, [])
      durable_total = Enum.reduce(payments, 0, &(&1.amount_cents + &2))
      total_recorded = max(group.deposit_paid_cents, settled_cash_total(group))
      legacy_amount = max(total_recorded - durable_total, 0)

      sources =
        []
        |> append_legacy_source(legacy_amount)
        |> Kernel.++(payments)

      sources_with_dispositions = assign_group_dispositions(group, sources)

      Enum.each(sources_with_dispositions, fn source ->
        {cash_funding_id, held_cents} = insert_cash_funding!(group, source, now)

        if held_cents > 0 and group.status == "active" do
          allocate_backfilled_funding(
            group.id,
            cash_funding_id,
            "cash",
            source.operation_id,
            held_cents,
            now
          )
        end
      end)
    end)
  end

  defp backfill_active_credit_allocations do
    now = DateTime.utc_now(:second)

    sql = """
    SELECT a.id, a.group_id, a.credit_lot_id, a.amount_cents
    FROM group_credit_applications AS a
    JOIN groups AS g ON g.id = a.group_id
    WHERE g.status = 'active' AND a.amount_cents > 0
    ORDER BY a.id ASC
    """

    repo().query!(sql, []).rows
    |> Enum.each(fn [_application_id, group_id, credit_lot_id, amount_cents] ->
      allocate_backfilled_funding(group_id, nil, "credit", nil, amount_cents, now, credit_lot_id)
    end)
  end

  defp backfill_credit_entitlements do
    now = DateTime.utc_now(:second)
    lots_by_operation = credit_lots_by_source_operation()

    partner_operations()
    |> Enum.filter(fn operation -> operation.operation_type == "cancel_group" end)
    |> Enum.each(fn operation ->
      result = decode_json(operation.result_json)

      with %{
             "status" => "applied",
             "group_id" => group_id,
             "credit_issued_cents" => credit_issued
           }
           when is_integer(credit_issued) and credit_issued > 0 <- result,
           [lot | _] <- Map.get(lots_by_operation, operation.operation_id, []),
           cash_fundings when cash_fundings != [] <- converted_cash_fundings(group_id) do
        insert_entitlements!(lot.id, cash_fundings, credit_issued, now)
      else
        _ -> :ok
      end
    end)
  end

  defp all_groups do
    repo().query!(
      """
      SELECT id, group_id, status, deposit_paid_cents, refunded_cents, retained_cents,
             cash_converted_to_credit_cents
      FROM groups
      ORDER BY id ASC
      """,
      []
    ).rows
    |> Enum.map(fn [id, group_id, status, deposit_paid, refunded, retained, converted] ->
      %{
        id: id,
        group_id: group_id,
        status: status,
        deposit_paid_cents: deposit_paid || 0,
        refunded_cents: refunded || 0,
        retained_cents: retained || 0,
        cash_converted_to_credit_cents: converted || 0
      }
    end)
  end

  defp durable_cash_payments_by_group do
    partner_operations()
    |> Enum.filter(fn operation -> operation.operation_type == "record_cash_payment" end)
    |> Enum.reduce(%{}, fn operation, acc ->
      case decode_json(operation.result_json) do
        %{"status" => "applied", "group_id" => group_id, "amount_cents" => amount}
        when is_integer(amount) and amount > 0 ->
          source = %{operation_id: operation.operation_id, amount_cents: amount}
          Map.update(acc, group_id, [source], &(&1 ++ [source]))

        _other ->
          acc
      end
    end)
  end

  defp partner_operations do
    repo().query!(
      """
      SELECT id, operation_id, operation_type, result_json
      FROM partner_operations
      ORDER BY id ASC
      """,
      []
    ).rows
    |> Enum.map(fn [id, operation_id, operation_type, result_json] ->
      %{
        id: id,
        operation_id: operation_id,
        operation_type: operation_type,
        result_json: result_json
      }
    end)
  end

  defp credit_lots_by_source_operation do
    repo().query!(
      """
      SELECT id, source_operation_id
      FROM guest_credit_lots
      ORDER BY id ASC
      """,
      []
    ).rows
    |> Enum.reduce(%{}, fn [id, source_operation_id], acc ->
      Map.update(acc, source_operation_id, [%{id: id}], &(&1 ++ [%{id: id}]))
    end)
  end

  defp converted_cash_fundings(group_id) do
    repo().query!(
      """
      SELECT f.id, f.converted_to_credit_cents
      FROM cash_fundings AS f
      JOIN groups AS g ON g.id = f.group_id
      WHERE g.group_id = ? AND f.converted_to_credit_cents > 0
      ORDER BY f.id ASC
      """,
      [group_id]
    ).rows
    |> Enum.map(fn [id, principal_cents] ->
      %{id: id, principal_cents: principal_cents}
    end)
  end

  defp append_legacy_source(sources, amount_cents) when amount_cents > 0 do
    sources ++ [%{operation_id: nil, amount_cents: amount_cents}]
  end

  defp append_legacy_source(sources, _amount_cents), do: sources

  defp assign_group_dispositions(group, sources) do
    totals =
      if group.status == "active" do
        %{
          held_cents: group.deposit_paid_cents,
          refunded_cents: 0,
          retained_cents: 0,
          converted_to_credit_cents: 0
        }
      else
        %{
          held_cents: 0,
          refunded_cents: group.refunded_cents,
          retained_cents: group.retained_cents,
          converted_to_credit_cents: group.cash_converted_to_credit_cents
        }
      end

    {sources, totals} = assign_disposition(sources, totals, :held_cents)
    {sources, totals} = assign_disposition(sources, totals, :refunded_cents)
    {sources, totals} = assign_disposition(sources, totals, :retained_cents)
    {sources, _totals} = assign_disposition(sources, totals, :converted_to_credit_cents)
    sources
  end

  defp assign_disposition(sources, totals, disposition_key) do
    {assigned_sources, remaining} =
      Enum.map_reduce(sources, Map.fetch!(totals, disposition_key), fn source, remaining ->
        assigned_so_far =
          Map.get(source, :held_cents, 0) +
            Map.get(source, :refunded_cents, 0) +
            Map.get(source, :retained_cents, 0) +
            Map.get(source, :converted_to_credit_cents, 0)

        available = max(source.amount_cents - assigned_so_far, 0)
        assigned = min(available, remaining)
        {Map.put(source, disposition_key, assigned), remaining - assigned}
      end)

    {assigned_sources, Map.put(totals, disposition_key, remaining)}
  end

  defp insert_cash_funding!(group, source, now) do
    held_cents = Map.get(source, :held_cents, 0)

    repo().query!(
      """
      INSERT INTO cash_fundings (
        group_id, payment_operation_id, recorded_cents, held_cents, refunded_cents,
        retained_cents, converted_to_credit_cents, reduced_cents, charged_back_cents,
        inserted_at, updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?)
      """,
      [
        group.id,
        source.operation_id,
        source.amount_cents,
        held_cents,
        Map.get(source, :refunded_cents, 0),
        Map.get(source, :retained_cents, 0),
        Map.get(source, :converted_to_credit_cents, 0),
        now,
        now
      ]
    )

    cash_funding_id =
      repo().query!("SELECT last_insert_rowid()", []).rows
      |> hd()
      |> hd()

    {cash_funding_id, held_cents}
  end

  defp allocate_backfilled_funding(
         group_id,
         cash_funding_id,
         funding_type,
         source_operation_id,
         amount_cents,
         now,
         credit_lot_id \\ nil
       ) do
    rooms =
      repo().query!(
        """
        SELECT id, deposit_due_cents
        FROM group_rooms
        WHERE group_id = ? AND status = 'active'
        ORDER BY position ASC
        """,
        [group_id]
      ).rows

    Enum.reduce_while(rooms, amount_cents, fn [room_id, deposit_due_cents], remaining ->
      room_paid = room_paid_cents(room_id)
      allocatable = min(max(deposit_due_cents - room_paid, 0), remaining)

      cond do
        remaining == 0 ->
          {:halt, 0}

        allocatable == 0 ->
          {:cont, remaining}

        true ->
          repo().insert_all("room_funding_allocations", [
            %{
              group_id: group_id,
              room_id: room_id,
              funding_type: funding_type,
              amount_cents: allocatable,
              source_operation_id: source_operation_id,
              cash_funding_id: cash_funding_id,
              credit_lot_id: credit_lot_id,
              inserted_at: now,
              updated_at: now
            }
          ])

          {:cont, remaining - allocatable}
      end
    end)

    :ok
  end

  defp room_paid_cents(room_id) do
    repo().query!(
      """
      SELECT COALESCE(SUM(amount_cents), 0)
      FROM room_funding_allocations
      WHERE room_id = ?
      """,
      [room_id]
    ).rows
    |> hd()
    |> hd()
  end

  defp settled_cash_total(group) do
    group.refunded_cents + group.retained_cents + group.cash_converted_to_credit_cents
  end

  defp insert_entitlements!(credit_lot_id, cash_fundings, _credit_issued_cents, now) do
    {_running_principal, rows} =
      Enum.map_reduce(cash_fundings, 0, fn funding, running_principal ->
        next_running_principal = running_principal + funding.principal_cents

        entitlement_cents =
          bonus_value(next_running_principal) - bonus_value(running_principal)

        row = %{
          credit_lot_id: credit_lot_id,
          cash_funding_id: funding.id,
          principal_cents: funding.principal_cents,
          entitlement_cents: entitlement_cents,
          inserted_at: now,
          updated_at: now
        }

        {row, next_running_principal}
      end)

    if rows != [] do
      repo().insert_all("credit_lot_cash_entitlements", rows)
    end
  end

  defp bonus_value(principal_cents), do: principal_cents + div(principal_cents * 10 + 50, 100)

  defp decode_json(nil), do: %{}

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      {:error, _reason} -> %{}
    end
  end
end
