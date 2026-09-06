defmodule GroupStay.Repo.Migrations.AddRoomAccounting do
  use Ecto.Migration

  def up do
    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_applications) do
      add :operation_id, :string
    end

    create table(:room_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :amount_cents, :integer, null: false
      add :payment_operation_id, :string

      add :credit_application_id,
          references(:credit_applications, type: :binary_id, on_delete: :delete_all)

      add :fill_position, :integer, null: false

      timestamps()
    end

    create index(:room_allocations, [:group_id])
    create index(:room_allocations, [:payment_operation_id])
    create index(:room_allocations, [:credit_application_id])
    create index(:room_allocations, [:room_id])

    create table(:payment_dispositions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :payment_operation_id, :string, null: false
      add :recorded_cents, :integer, null: false
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:payment_dispositions, [:payment_operation_id])

    create table(:credit_lot_funding, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :lot_id, references(:credit_lots, type: :binary_id, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :principal_cents, :integer, null: false
      add :position, :integer, null: false

      timestamps()
    end

    create index(:credit_lot_funding, [:lot_id])

    execute("""
    UPDATE rooms SET status = 'cancelled'
    WHERE group_id IN (SELECT id FROM groups WHERE status <> 'active')
    """)

    execute(fn -> backfill_allocations() end)
  end

  def down do
    drop table(:credit_lot_funding)
    drop table(:payment_dispositions)
    drop table(:room_allocations)

    alter table(:credit_applications) do
      remove :operation_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :status
    end

    alter table(:groups) do
      remove :cash_charged_back_cents
      remove :cash_reduced_cents
    end
  end

  ## Bring pre-durable funding forward as one unattributed senior block per
  ## active group, followed by durable-record funding in commit order.

  defp backfill_allocations do
    repo = repo()

    payments =
      "SELECT id, operation_id, payload, result FROM operations WHERE result IS NOT NULL AND type = 'record_cash_payment' ORDER BY id"
      |> query_rows(repo)
      |> Enum.map(fn [id, operation_id, payload, result] ->
        %{
          id: id,
          operation_id: operation_id,
          payload: Jason.decode!(payload),
          result: Jason.decode!(result)
        }
      end)
      |> Enum.filter(fn op -> op.result["status"] == "applied" end)
      |> Enum.map(fn op ->
        {:cash, op.id, op.operation_id, op.result["amount_cents"], op.payload["group_id"]}
      end)

    credits =
      "SELECT id, operation_id, payload, result FROM operations WHERE result IS NOT NULL AND type = 'apply_hotel_credit' ORDER BY id"
      |> query_rows(repo)
      |> Enum.map(fn [id, operation_id, payload, result] ->
        %{
          id: id,
          operation_id: operation_id,
          payload: Jason.decode!(payload),
          result: Jason.decode!(result)
        }
      end)
      |> Enum.filter(fn op -> op.result["status"] == "applied" end)
      |> Enum.map(fn op ->
        {:credit_op, op.id, op.operation_id, op.result["amount_cents"], op.payload["group_id"],
         op.payload["occurred_on"]}
      end)

    "SELECT id, group_id, cash_paid_cents FROM groups WHERE status = 'active'"
    |> query_rows(repo)
    |> Enum.each(fn [id, group_id, cash_paid_cents] ->
      backfill_group(repo, id, group_id, cash_paid_cents, payments, credits)
    end)

    # Groups cancelled by the previous release keep aggregate-only settlement
    # columns. Reconstruct per-payment dispositions there too so that payment
    # reconciliation still agrees with the group and ledger views.
    """
    SELECT id, group_id, cash_paid_cents, refunded_cents, retained_cents,
           cash_converted_to_credit_cents
    FROM groups WHERE status <> 'active'
    """
    |> query_rows(repo)
    |> Enum.each(fn [id, group_id, cash_paid_cents, refunded, retained, converted] ->
      backfill_settled_dispositions(
        repo,
        id,
        group_id,
        cash_paid_cents,
        refunded,
        retained,
        converted,
        payments,
        credits
      )
    end)
  end

  defp backfill_settled_dispositions(
         repo,
         group_id,
         group_partner_id,
         cash_paid_cents,
         refunded,
         retained,
         converted,
         payments,
         credits
       ) do
    group_payments =
      Enum.filter(payments, fn {:cash, _id, _op, _amount, gid} -> gid == group_partner_id end)

    group_credits =
      Enum.filter(credits, fn {:credit_op, _id, _op, _amount, gid, _on} ->
        gid == group_partner_id
      end)

    apps =
      "SELECT id, amount_cents, applied_on, inserted_at FROM credit_applications WHERE group_id = ? ORDER BY applied_on, inserted_at, id"
      |> query_rows(repo, [group_id])
      |> Enum.with_index()
      |> Enum.map(fn {[id, amount_cents, applied_on, _inserted_at], index} ->
        %{id: id, amount_cents: amount_cents, applied_on: applied_on, index: index}
      end)

    {matched, legacy_apps} = match_credit_operations(apps, group_credits)

    for {operation_id, taken} <- matched do
      placeholders = Enum.map_join(taken, ",", fn _ -> "?" end)

      execute_parameters(
        repo,
        "UPDATE credit_applications SET operation_id = ? WHERE id IN (#{placeholders})",
        [operation_id | Enum.map(taken, & &1.id)]
      )
    end

    rooms =
      "SELECT id, deposit_cents FROM rooms WHERE group_id = ? ORDER BY position"
      |> query_rows(repo, [group_id])

    legacy_cash =
      cash_paid_cents -
        Enum.sum(Enum.map(group_payments, fn {:cash, _, _, amount, _} -> amount end))

    legacy_pieces =
      if legacy_cash > 0,
        do: [{:cash, nil, legacy_cash}],
        else: []

    legacy_pieces =
      legacy_pieces ++
        Enum.map(legacy_apps, fn app -> {:credit, nil, app.id, app.amount_cents} end)

    durable_pieces =
      (group_payments ++ group_credits)
      |> Enum.sort_by(fn piece -> elem(piece, 1) end)
      |> Enum.flat_map(fn
        {:cash, _id, operation_id, amount, _gid} ->
          [{:cash, operation_id, amount}]

        {:credit_op, _id, operation_id, _amount, _gid, _on} ->
          matched
          |> Map.get(operation_id, [])
          |> Enum.map(fn app -> {:credit, operation_id, app.id, app.amount_cents} end)
      end)

    pieces = legacy_pieces ++ durable_pieces
    fill_pieces(repo, group_id, rooms, pieces)

    {field, settled} =
      cond do
        refunded > 0 -> {"refunded_cents", refunded}
        retained > 0 -> {"retained_cents", retained}
        true -> {"converted_cents", converted}
      end

    Enum.reduce(
      [
        {nil, legacy_cash}
        | Enum.map(group_payments, fn {:cash, _, op_id, amount, _} -> {op_id, amount} end)
      ],
      settled,
      fn {operation_id, amount}, left ->
        if left <= 0 do
          0
        else
          take = min(amount, left)

          if operation_id do
            now = now_string()

            execute_parameters(
              repo,
              """
              INSERT INTO payment_dispositions
                (id, group_id, payment_operation_id, recorded_cents,
                 refunded_cents, retained_cents, converted_cents,
                 reduced_cents, charged_back_cents, inserted_at, updated_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?)
              """,
              [
                Ecto.UUID.generate(),
                group_id,
                operation_id,
                amount,
                if(field == "refunded_cents", do: take, else: 0),
                if(field == "retained_cents", do: take, else: 0),
                if(field == "converted_cents", do: take, else: 0),
                now,
                now
              ]
            )
          end

          left - take
        end
      end
    )
  end

  defp backfill_group(repo, group_id, group_partner_id, cash_paid_cents, payments, credits) do
    rooms =
      "SELECT id, deposit_cents FROM rooms WHERE group_id = ? ORDER BY position"
      |> query_rows(repo, [group_id])

    apps =
      "SELECT id, amount_cents, applied_on, inserted_at FROM credit_applications WHERE group_id = ? ORDER BY applied_on, inserted_at, id"
      |> query_rows(repo, [group_id])
      |> Enum.with_index()
      |> Enum.map(fn {[id, amount_cents, applied_on, _inserted_at], index} ->
        %{id: id, amount_cents: amount_cents, applied_on: applied_on, index: index}
      end)

    group_payments =
      Enum.filter(payments, fn {:cash, _id, _op, _amount, gid} -> gid == group_partner_id end)

    group_credits =
      Enum.filter(credits, fn {:credit_op, _id, _op, _amount, gid, _on} ->
        gid == group_partner_id
      end)

    {matched, legacy_apps} = match_credit_operations(apps, group_credits)

    for {operation_id, taken} <- matched do
      placeholders = Enum.map_join(taken, ",", fn _ -> "?" end)

      execute_parameters(
        repo,
        "UPDATE credit_applications SET operation_id = ? WHERE id IN (#{placeholders})",
        [operation_id | Enum.map(taken, & &1.id)]
      )
    end

    legacy_cash =
      cash_paid_cents -
        Enum.sum(Enum.map(group_payments, fn {:cash, _, _, amount, _} -> amount end))

    legacy_pieces =
      if legacy_cash > 0,
        do: [{:cash, nil, legacy_cash}],
        else: []

    legacy_pieces =
      legacy_pieces ++
        Enum.map(legacy_apps, fn app -> {:credit, nil, app.id, app.amount_cents} end)

    durable_pieces =
      (group_payments ++ group_credits)
      |> Enum.sort_by(fn piece -> elem(piece, 1) end)
      |> Enum.flat_map(fn
        {:cash, _id, operation_id, amount, _gid} ->
          [{:cash, operation_id, amount}]

        {:credit_op, _id, operation_id, _amount, _gid, _on} ->
          matched
          |> Map.get(operation_id, [])
          |> Enum.map(fn app -> {:credit, operation_id, app.id, app.amount_cents} end)
      end)

    pieces = legacy_pieces ++ durable_pieces
    fill_pieces(repo, group_id, rooms, pieces)
  end

  defp match_credit_operations(apps, credits) do
    {matched, remaining} =
      Enum.reduce(credits, {%{}, apps}, fn {:credit_op, _id, operation_id, amount, _gid,
                                            occurred_on},
                                           {matched, leftover} ->
        same_day = Enum.filter(leftover, &(&1.applied_on == occurred_on))

        case prefix_take(same_day, amount) || prefix_take(leftover, amount) do
          nil ->
            {matched, leftover}

          taken ->
            taken_ids = MapSet.new(taken, & &1.id)

            {Map.put(matched, operation_id, taken),
             Enum.reject(leftover, &MapSet.member?(taken_ids, &1.id))}
        end
      end)

    {matched, Enum.sort_by(remaining, & &1.index)}
  end

  defp prefix_take(items, amount) do
    result =
      Enum.reduce_while(items, {[], 0}, fn item, {taken, sum} ->
        case sum + item.amount_cents do
          ^amount ->
            {:halt, Enum.reverse([item | taken])}

          subtotal when subtotal < amount ->
            {:cont, {[item | taken], subtotal}}

          _too_much ->
            {:halt, nil}
        end
      end)

    if is_list(result), do: result, else: nil
  end

  defp fill_pieces(repo, group_id, rooms, pieces) do
    {_capacities, _position, rows} =
      Enum.reduce(
        pieces,
        {Map.new(rooms, fn [id, deposit] -> {id, deposit} end), 0, []},
        fn piece, {capacities, position, rows} ->
          {capacities, position, piece_rows} = fill_piece(piece, rooms, capacities, position)
          {capacities, position, rows ++ piece_rows}
        end
      )

    now = now_string()

    for {room_id, kind, amount_cents, payment_operation_id, application_id, position} <- rows do
      execute_parameters(
        repo,
        """
        INSERT INTO room_allocations
          (id, group_id, room_id, kind, amount_cents, payment_operation_id,
           credit_application_id, fill_position, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          Ecto.UUID.generate(),
          group_id,
          room_id,
          kind,
          amount_cents,
          payment_operation_id,
          application_id,
          position,
          now,
          now
        ]
      )
    end
  end

  defp fill_piece(piece, rooms, capacities, position) do
    {kind, payment_operation_id, application_id, amount} =
      case piece do
        {:cash, payment_operation_id, amount} ->
          {"cash", payment_operation_id, nil, amount}

        {:credit, _operation_id, application_id, amount} ->
          {"credit", nil, application_id, amount}
      end

    {_amount, capacities, position, rows} =
      Enum.reduce(rooms, {amount, capacities, position, []}, fn [room_id, _deposit],
                                                                {left, caps, pos, acc} ->
        if left == 0 do
          {0, caps, pos, acc}
        else
          capacity = Map.get(caps, room_id)

          case min(capacity, left) do
            0 ->
              {left, caps, pos, acc}

            take ->
              {left - take, Map.put(caps, room_id, capacity - take), pos + 1,
               [{room_id, kind, take, payment_operation_id, application_id, pos + 1} | acc]}
          end
        end
      end)

    {capacities, position, Enum.reverse(rows)}
  end

  defp now_string do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.truncate(:microsecond)
    |> NaiveDateTime.to_iso8601()
    |> String.replace("T", " ")
  end

  defp query_rows(sql, repo, params \\ []) do
    Ecto.Adapters.SQL.query!(repo, sql, params).rows
  end

  defp execute_parameters(repo, sql, params) do
    Ecto.Adapters.SQL.query!(repo, sql, params)
  end
end
