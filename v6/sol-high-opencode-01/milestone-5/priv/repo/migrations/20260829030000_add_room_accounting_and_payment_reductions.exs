defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  @max_sqlite_integer 9_223_372_036_854_775_807

  def up do
    alter table(:group_rooms) do
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :status, :string, null: false, default: "active"
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:credit_allocations) do
      add :room_id, references(:group_rooms, on_delete: :delete_all)
      add :funding_operation_id, :string
    end

    create table(:cash_allocations) do
      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :room_id, references(:group_rooms, on_delete: :delete_all), null: false
      add :payment_operation_id, :string
      add :amount_cents, :integer, null: false
    end

    create index(:cash_allocations, [:group_id])
    create index(:cash_allocations, [:room_id])
    create index(:cash_allocations, [:payment_operation_id])
    create index(:credit_allocations, [:room_id])
    create index(:credit_allocations, [:funding_operation_id])

    create table(:payment_accounts, primary_key: false) do
      add :payment_operation_id, :string, primary_key: true

      add :group_id,
          references(:groups, column: :group_id, type: :string, on_delete: :delete_all),
          null: false

      add :recorded_cents, :integer, null: false
      add :held_cents, :integer, null: false, default: 0
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_to_credit_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    create index(:payment_accounts, [:group_id])

    create table(:credit_lot_accounts, primary_key: false) do
      add :source_operation_id, :string, primary_key: true
    end

    create table(:credit_clawbacks) do
      add :source_operation_id,
          references(:credit_lot_accounts,
            column: :source_operation_id,
            type: :string,
            on_delete: :delete_all
          ),
          null: false

      add :amount_cents, :integer, null: false
    end

    create index(:credit_clawbacks, [:source_operation_id])

    create table(:credit_entitlements) do
      add :source_operation_id,
          references(:credit_lot_accounts,
            column: :source_operation_id,
            type: :string,
            on_delete: :delete_all
          ),
          null: false

      add :payment_operation_id,
          references(:payment_accounts,
            column: :payment_operation_id,
            type: :string,
            on_delete: :delete_all
          ),
          null: false

      add :amount_cents, :integer, null: false
    end

    create index(:credit_entitlements, [:source_operation_id, :payment_operation_id])
    create index(:credit_entitlements, [:payment_operation_id])

    flush()
    backfill()
  end

  def down do
    drop table(:credit_entitlements)
    drop table(:credit_clawbacks)
    drop table(:credit_lot_accounts)
    drop table(:payment_accounts)
    drop table(:cash_allocations)

    drop index(:credit_allocations, [:funding_operation_id])
    drop index(:credit_allocations, [:room_id])

    alter table(:credit_allocations) do
      remove :funding_operation_id
      remove :room_id
    end

    alter table(:group_rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :status
      remove :deposit_due_cents
      remove :lodging_total_cents
    end
  end

  defp backfill do
    repo = repo()

    operations =
      query!(
        repo,
        "SELECT id, operation_id, operation_type, submission, result FROM partner_operations ORDER BY id"
      )
      |> Enum.map(fn [id, operation_id, type, submission, result] ->
        %{
          id: id,
          operation_id: operation_id,
          type: type,
          submission: decode_json(submission),
          result: decode_json(result)
        }
      end)

    query!(repo, "SELECT DISTINCT source_operation_id FROM credit_lots")
    |> Enum.each(fn [source_operation_id] ->
      sql!(repo, "INSERT INTO credit_lot_accounts (source_operation_id) VALUES (?)", [
        source_operation_id
      ])
    end)

    groups =
      query!(
        repo,
        "SELECT group_id, arrival_on, departure_on, rate_plan, status, cash_paid_cents, " <>
          "credit_paid_cents, cash_refunded_cents, cash_retained_cents, " <>
          "cash_converted_to_credit_cents FROM groups"
      )

    Enum.each(groups, &backfill_group(repo, &1, operations))
    backfill_entitlements(repo, groups, operations)
  end

  defp backfill_group(
         repo,
         [
           group_id,
           arrival_on,
           departure_on,
           rate_plan,
           status,
           cash_paid,
           credit_paid,
           refunded,
           retained,
           converted
         ],
         operations
       ) do
    nights = Date.diff(parse_date!(departure_on), parse_date!(arrival_on))

    rooms =
      query!(
        repo,
        "SELECT id, nightly_rate_cents FROM group_rooms WHERE group_id = ? ORDER BY position",
        [group_id]
      )
      |> Enum.map(fn [id, rate] ->
        lodging = nights * rate
        deposit = if rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging

        if lodging > @max_sqlite_integer or deposit > @max_sqlite_integer do
          raise "room accounting backfill exceeds SQLite integer range for group #{group_id}"
        end

        sql!(
          repo,
          "UPDATE group_rooms SET lodging_total_cents = ?, deposit_due_cents = ?, status = ? WHERE id = ?",
          [lodging, deposit, status, id]
        )

        %{id: id, due: deposit, cash: 0, credit: 0}
      end)

    funding =
      Enum.filter(operations, fn operation ->
        operation.type in ["record_cash_payment", "apply_hotel_credit"] and
          operation.result["status"] == "applied" and operation.result["group_id"] == group_id
      end)

    payments = Enum.filter(funding, &(&1.type == "record_cash_payment"))
    durable_cash = Enum.sum(Enum.map(payments, & &1.result["amount_cents"]))

    durable_credit =
      funding
      |> Enum.reject(&(&1.type == "record_cash_payment"))
      |> Enum.sum_by(& &1.result["amount_cents"])

    legacy_cash = cash_paid - durable_cash
    legacy_credit = credit_paid - durable_credit

    if legacy_cash < 0 or legacy_credit < 0 do
      raise "durable funding exceeds stored group funding for group #{group_id}"
    end

    dispositions = %{refunded: refunded, retained: retained, converted: converted}
    {_legacy_dispositions, remaining_dispositions} = take_dispositions(dispositions, legacy_cash)

    {_remaining, payment_rows} =
      Enum.map_reduce(payments, remaining_dispositions, fn payment, available ->
        amount = payment.result["amount_cents"]

        row =
          if status == "active" do
            %{held: amount, refunded: 0, retained: 0, converted: 0}
          else
            {taken, _rest} = take_dispositions(available, amount)
            Map.put(taken, :held, 0)
          end

        next =
          if status == "active",
            do: available,
            else: elem(take_dispositions(available, amount), 1)

        {row, next}
      end)
      |> then(fn {rows, remaining} -> {remaining, rows} end)

    Enum.zip(payments, payment_rows)
    |> Enum.each(fn {payment, row} ->
      sql!(
        repo,
        "INSERT INTO payment_accounts " <>
          "(payment_operation_id, group_id, recorded_cents, held_cents, refunded_cents, retained_cents, converted_to_credit_cents) " <>
          "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [
          payment.operation_id,
          group_id,
          payment.result["amount_cents"],
          row.held,
          row.refunded,
          row.retained,
          row.converted
        ]
      )
    end)

    if status == "active" do
      old_credit =
        query!(
          repo,
          "SELECT credit_lot_id, amount_cents FROM credit_allocations WHERE group_id = ? ORDER BY id",
          [group_id]
        )
        |> Enum.map(fn [lot_id, amount] -> %{lot_id: lot_id, amount: amount} end)

      sql!(repo, "DELETE FROM credit_allocations WHERE group_id = ?", [group_id])
      {legacy_credit_fragments, credit_rest} = take_credit_fragments(old_credit, legacy_credit)

      units =
        []
        |> maybe_add_cash(legacy_cash, nil)
        |> maybe_add_credit(legacy_credit_fragments, nil)
        |> add_durable_units(funding, credit_rest)
        |> elem(0)

      final_rooms =
        Enum.reduce(units, rooms, fn
          {:cash, amount, payment_operation_id}, room_state ->
            {next, allocations} = fill_rooms(room_state, amount, :cash)

            Enum.each(allocations, fn {room_id, used} ->
              sql!(
                repo,
                "INSERT INTO cash_allocations (group_id, room_id, payment_operation_id, amount_cents) VALUES (?, ?, ?, ?)",
                [group_id, room_id, payment_operation_id, used]
              )
            end)

            next

          {:credit, fragments, operation_id}, room_state ->
            Enum.reduce(fragments, room_state, fn fragment, state ->
              {next, allocations} = fill_rooms(state, fragment.amount, :credit)

              Enum.each(allocations, fn {room_id, used} ->
                sql!(
                  repo,
                  "INSERT INTO credit_allocations (group_id, credit_lot_id, room_id, funding_operation_id, amount_cents) " <>
                    "VALUES (?, ?, ?, ?, ?)",
                  [group_id, fragment.lot_id, room_id, operation_id, used]
                )
              end)

              next
            end)
        end)

      Enum.each(final_rooms, fn room ->
        sql!(
          repo,
          "UPDATE group_rooms SET cash_paid_cents = ?, credit_paid_cents = ? WHERE id = ?",
          [room.cash, room.credit, room.id]
        )
      end)
    end
  end

  defp add_durable_units(units, funding, credit_fragments) do
    Enum.reduce(funding, {units, credit_fragments}, fn operation, {result, fragments} ->
      amount = operation.result["amount_cents"]

      if operation.type == "record_cash_payment" do
        {result ++ [{:cash, amount, operation.operation_id}], fragments}
      else
        {used, rest} = take_credit_fragments(fragments, amount)
        {result ++ [{:credit, used, operation.operation_id}], rest}
      end
    end)
  end

  defp maybe_add_cash(units, 0, _operation_id), do: units
  defp maybe_add_cash(units, amount, operation_id), do: units ++ [{:cash, amount, operation_id}]

  defp maybe_add_credit(units, [], _operation_id), do: units

  defp maybe_add_credit(units, fragments, operation_id),
    do: units ++ [{:credit, fragments, operation_id}]

  defp fill_rooms(rooms, 0, _kind), do: {rooms, []}

  defp fill_rooms([room | rest], amount, kind) do
    capacity = room.due - room.cash - room.credit
    used = min(capacity, amount)
    room = Map.update!(room, kind, &(&1 + used))
    {next_rest, allocations} = fill_rooms(rest, amount - used, kind)
    allocation = if used > 0, do: [{room.id, used}], else: []
    {[room | next_rest], allocation ++ allocations}
  end

  defp fill_rooms([], amount, _kind) when amount > 0,
    do: raise("stored funding exceeds room deposits during room accounting backfill")

  defp take_credit_fragments(fragments, amount), do: take_credit_fragments(fragments, amount, [])
  defp take_credit_fragments(fragments, 0, taken), do: {Enum.reverse(taken), fragments}

  defp take_credit_fragments([fragment | rest], amount, taken) do
    used = min(fragment.amount, amount)
    taken = [%{fragment | amount: used} | taken]

    remaining =
      if used == fragment.amount,
        do: rest,
        else: [%{fragment | amount: fragment.amount - used} | rest]

    take_credit_fragments(remaining, amount - used, taken)
  end

  defp take_credit_fragments([], amount, _taken) when amount > 0,
    do: raise("stored credit allocations do not cover the group's credit funding")

  defp take_dispositions(dispositions, amount) do
    Enum.reduce([:refunded, :retained, :converted], {%{}, dispositions, amount}, fn key,
                                                                                    {taken, left,
                                                                                     needed} ->
      used = min(Map.fetch!(left, key), needed)
      {Map.put(taken, key, used), Map.update!(left, key, &(&1 - used)), needed - used}
    end)
    |> then(fn {taken, left, _needed} -> {taken, left} end)
  end

  defp backfill_entitlements(repo, groups, operations) do
    Enum.each(groups, fn [group_id, _, _, _, _, _, _, _, _, converted] ->
      if converted > 0 do
        cancellations =
          Enum.filter(operations, fn operation ->
            operation.type == "cancel_group" and operation.result["status"] == "applied" and
              operation.result["group_id"] == group_id and
              operation.result["credit_issued_cents"] > 0
          end)

        Enum.each(cancellations, fn cancellation ->
          payments =
            query!(
              repo,
              "SELECT pa.payment_operation_id, pa.converted_to_credit_cents " <>
                "FROM payment_accounts pa JOIN partner_operations po ON po.operation_id = pa.payment_operation_id " <>
                "WHERE pa.group_id = ? AND pa.converted_to_credit_cents > 0 ORDER BY po.id",
              [group_id]
            )

          durable_principal = Enum.sum_by(payments, fn [_id, amount] -> amount end)
          running = converted - durable_principal

          Enum.reduce(payments, running, fn [payment_operation_id, principal], total ->
            entitlement = bonus_value(total + principal) - bonus_value(total)

            entitlement
            |> split_sqlite_integers()
            |> Enum.each(fn chunk ->
              sql!(
                repo,
                "INSERT INTO credit_entitlements (source_operation_id, payment_operation_id, amount_cents) VALUES (?, ?, ?)",
                [cancellation.operation_id, payment_operation_id, chunk]
              )
            end)

            total + principal
          end)
        end)
      end
    end)
  end

  defp bonus_value(amount), do: amount + div(amount * 10 + 50, 100)

  defp split_sqlite_integers(amount) when amount <= @max_sqlite_integer, do: [amount]

  defp split_sqlite_integers(amount),
    do: [@max_sqlite_integer | split_sqlite_integers(amount - @max_sqlite_integer)]

  defp parse_date!(%Date{} = date), do: date
  defp parse_date!(date), do: Date.from_iso8601!(date)

  defp decode_json(value) when is_map(value), do: value
  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)

  defp query!(repo, sql, params \\ []), do: repo.query!(sql, params).rows
  defp sql!(repo, sql, params), do: repo.query!(sql, params)
end
