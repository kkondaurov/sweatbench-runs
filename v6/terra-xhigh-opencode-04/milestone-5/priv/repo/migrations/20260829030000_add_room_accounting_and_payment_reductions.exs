defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_total_cents, :integer, null: false, default: 0
      add :deposit_due_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    alter table(:credit_applications) do
      add :room_id, references(:rooms, type: :binary_id, on_delete: :restrict)
    end

    alter table(:cash_entries) do
      add :cash_payment_id, :integer
      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict)
    end

    create table(:cash_payments) do
      add :payment_operation_id, :string, null: false
      add :group_id, references(:groups, type: :binary_id, on_delete: :restrict), null: false
      add :recorded_cents, :integer, null: false
    end

    create unique_index(:cash_payments, [:payment_operation_id])
    create index(:cash_payments, [:group_id])

    create table(:cash_room_allocations) do
      add :room_id, references(:rooms, type: :binary_id, on_delete: :restrict), null: false
      add :cash_payment_id, references(:cash_payments, on_delete: :restrict)
      add :amount_cents, :integer, null: false
      add :fill_order, :integer, null: false
    end

    create index(:cash_room_allocations, [:room_id])
    create index(:cash_room_allocations, [:cash_payment_id])
    create index(:cash_room_allocations, [:fill_order])

    create table(:cash_payment_dispositions) do
      add :cash_payment_id, references(:cash_payments, on_delete: :restrict), null: false
      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict)
      add :disposition, :string, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:cash_payment_dispositions, [:cash_payment_id])
    create index(:cash_payment_dispositions, [:credit_lot_id])

    create table(:credit_lot_contributions) do
      add :credit_lot_id, references(:credit_lots, type: :binary_id, on_delete: :restrict),
        null: false

      add :cash_payment_id, references(:cash_payments, on_delete: :restrict)
      add :principal_cents, :integer, null: false
      add :entitlement_cents, :integer, null: false
      add :funding_order, :integer, null: false
    end

    create index(:credit_lot_contributions, [:credit_lot_id])
    create index(:credit_lot_contributions, [:cash_payment_id])

    flush()

    execute("""
    UPDATE rooms
    SET
      status = CASE WHEN (SELECT status FROM groups WHERE groups.id = rooms.group_id) = 'active'
        THEN 'active' ELSE 'cancelled' END,
      lodging_total_cents = CAST(
        (julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)) -
         julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id))) * nightly_rate_cents
        AS INTEGER
      ),
      deposit_due_cents = CASE
        WHEN (SELECT rate_plan FROM groups WHERE groups.id = rooms.group_id) = 'flexible' THEN
          CAST((
            (julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)) -
             julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id))) *
            nightly_rate_cents * 20 + 50
          ) / 100 AS INTEGER)
        ELSE CAST(
          (julianday((SELECT departure_on FROM groups WHERE groups.id = rooms.group_id)) -
           julianday((SELECT arrival_on FROM groups WHERE groups.id = rooms.group_id))) * nightly_rate_cents
          AS INTEGER)
      END
    """)

    execute("""
    INSERT INTO cash_payments (payment_operation_id, group_id, recorded_cents)
    SELECT operation_id, groups.id, CAST(json_extract(result, '$.amount_cents') AS INTEGER)
    FROM partner_operations
    JOIN groups ON groups.group_id = json_extract(result, '$.group_id')
    WHERE operation_type = 'record_cash_payment'
      AND json_extract(result, '$.status') = 'applied'
    """)

    flush()
    backfill_active_funding()
    backfill_cancelled_dispositions()
    refresh_group_totals()
  end

  def down do
    drop table(:credit_lot_contributions)
    drop table(:cash_payment_dispositions)
    drop table(:cash_room_allocations)
    drop table(:cash_payments)

    alter table(:cash_entries) do
      remove :credit_lot_id
      remove :cash_payment_id
    end

    alter table(:credit_applications) do
      remove :room_id
    end

    alter table(:credit_lots) do
      remove :unrecovered_clawback_cents
    end

    alter table(:rooms) do
      remove :credit_paid_cents
      remove :cash_paid_cents
      remove :deposit_due_cents
      remove :lodging_total_cents
      remove :status
    end
  end

  defp backfill_active_funding do
    repo = repo()

    groups =
      repo.query!(
        "SELECT id, group_id, cash_paid_cents, credit_paid_cents FROM groups WHERE status = 'active'"
      ).rows

    Enum.each(groups, fn [group_id, partner_group_id, cash_paid_cents, credit_paid_cents] ->
      rooms =
        repo.query!(
          "SELECT id, deposit_due_cents FROM rooms WHERE group_id = ? ORDER BY position",
          [group_id]
        ).rows
        |> Enum.map(fn [room_id, deposit_due_cents] -> {room_id, deposit_due_cents} end)

      cash_payments =
        repo.query!(
          """
          SELECT payment_operation_id, id, recorded_cents
          FROM cash_payments
          WHERE group_id = ?
          """,
          [group_id]
        ).rows

      payments_by_operation =
        Map.new(cash_payments, fn [operation_id, payment_id, _recorded_cents] ->
          {operation_id, payment_id}
        end)

      operations =
        repo.query!(
          """
          SELECT operation_id, operation_type, CAST(json_extract(result, '$.amount_cents') AS INTEGER)
          FROM partner_operations
          WHERE json_extract(result, '$.status') = 'applied'
            AND json_extract(result, '$.group_id') = ?
            AND operation_type IN ('record_cash_payment', 'apply_hotel_credit')
          ORDER BY id
          """,
          [partner_group_id]
        ).rows

      durable_cash_cents =
        operations
        |> Enum.filter(fn [_operation_id, operation_type, _amount] ->
          operation_type == "record_cash_payment"
        end)
        |> Enum.sum_by(fn [_operation_id, _operation_type, amount] -> amount end)

      durable_credit_cents =
        operations
        |> Enum.filter(fn [_operation_id, operation_type, _amount] ->
          operation_type == "apply_hotel_credit"
        end)
        |> Enum.sum_by(fn [_operation_id, _operation_type, amount] -> amount end)

      credit_sources =
        repo.query!(
          "SELECT credit_lot_id, amount_cents FROM credit_applications WHERE group_id = ? ORDER BY rowid",
          [group_id]
        ).rows
        |> Enum.map(fn [credit_lot_id, amount_cents] -> {credit_lot_id, amount_cents} end)

      repo.query!("DELETE FROM credit_applications WHERE group_id = ?", [group_id])

      {rooms, order} =
        allocate_cash_source(
          repo,
          rooms,
          nil,
          max(cash_paid_cents - durable_cash_cents, 0),
          1
        )

      {credit_sources, legacy_credit_sources} =
        take_credit_sources(credit_sources, max(credit_paid_cents - durable_credit_cents, 0))

      rooms = allocate_credit_sources(repo, group_id, rooms, legacy_credit_sources)

      {_credit_sources, _rooms, _order} =
        Enum.reduce(operations, {credit_sources, rooms, order}, fn
          [operation_id, "record_cash_payment", amount_cents], {credit_sources, rooms, order} ->
            {rooms, order} =
              allocate_cash_source(
                repo,
                rooms,
                Map.fetch!(payments_by_operation, operation_id),
                amount_cents,
                order
              )

            {credit_sources, rooms, order}

          [_operation_id, "apply_hotel_credit", amount_cents], {credit_sources, rooms, order} ->
            {credit_sources, sources} = take_credit_sources(credit_sources, amount_cents)
            {credit_sources, allocate_credit_sources(repo, group_id, rooms, sources), order}
        end)
    end)
  end

  defp allocate_cash_source(_repo, rooms, _payment_id, 0, order), do: {rooms, order}

  defp allocate_cash_source(repo, rooms, payment_id, source_amount, order) do
    {_, updated, order} =
      Enum.reduce(rooms, {source_amount, [], order}, fn {room_id, capacity},
                                                        {remaining, updated, current_order} ->
        amount = min(remaining, capacity)

        if amount > 0 do
          repo.query!(
            """
            INSERT INTO cash_room_allocations (room_id, cash_payment_id, amount_cents, fill_order)
            VALUES (?, ?, ?, ?)
            """,
            [room_id, payment_id, amount, current_order]
          )

          repo.query!("UPDATE rooms SET cash_paid_cents = cash_paid_cents + ? WHERE id = ?", [
            amount,
            room_id
          ])
        end

        room = {room_id, capacity - amount}

        {remaining - amount, [room | updated], current_order + if(amount > 0, do: 1, else: 0)}
      end)

    {Enum.reverse(updated), order}
  end

  defp take_credit_sources(sources, 0), do: {sources, []}

  defp take_credit_sources([], _amount_cents), do: {[], []}

  defp take_credit_sources([{credit_lot_id, available_cents} | rest], amount_cents) do
    amount = min(available_cents, amount_cents)

    remaining_sources =
      if amount == available_cents,
        do: rest,
        else: [{credit_lot_id, available_cents - amount} | rest]

    {remaining_sources, later_sources} =
      take_credit_sources(remaining_sources, amount_cents - amount)

    {remaining_sources, [{credit_lot_id, amount} | later_sources]}
  end

  defp allocate_credit_sources(repo, group_id, rooms, sources) do
    Enum.reduce(sources, rooms, fn {credit_lot_id, amount_cents}, rooms ->
      allocate_credit_source(repo, group_id, rooms, credit_lot_id, amount_cents)
    end)
  end

  defp allocate_credit_source(_repo, _group_id, rooms, _credit_lot_id, 0), do: rooms

  defp allocate_credit_source(repo, group_id, rooms, credit_lot_id, amount_cents) do
    {_, updated} =
      Enum.reduce(rooms, {amount_cents, []}, fn {room_id, capacity}, {remaining, updated} ->
        amount = min(remaining, capacity)

        if amount > 0 do
          repo.query!(
            """
            INSERT INTO credit_applications (id, group_id, room_id, credit_lot_id, amount_cents)
            VALUES (?, ?, ?, ?, ?)
            """,
            [Ecto.UUID.generate(), group_id, room_id, credit_lot_id, amount]
          )

          repo.query!("UPDATE rooms SET credit_paid_cents = credit_paid_cents + ? WHERE id = ?", [
            amount,
            room_id
          ])
        end

        {remaining - amount, [{room_id, capacity - amount} | updated]}
      end)

    Enum.reverse(updated)
  end

  defp backfill_cancelled_dispositions do
    repo = repo()

    repo.query!("SELECT id, group_id, cash_paid_cents FROM groups WHERE status = 'cancelled'").rows
    |> Enum.each(fn [group_id, partner_group_id, cash_paid_cents] ->
      payments = payments_for_group(repo, group_id)
      durable_total = Enum.sum(Enum.map(payments, fn {_id, amount} -> amount end))
      sources = [{nil, max(cash_paid_cents - durable_total, 0)} | payments]

      settlements =
        repo.query!(
          """
          SELECT entry_type, SUM(amount_cents)
          FROM cash_entries
          WHERE group_id = ?
            AND entry_type IN ('cash_refund', 'cash_retention', 'cash_credit_conversion')
          GROUP BY entry_type
          """,
          [group_id]
        ).rows

      {_, converted_sources} =
        Enum.reduce(settlements, {sources, []}, fn [entry_type, amount_cents],
                                                   {sources, converted} ->
          {updated_sources, allocations} =
            distribute_settlement(repo, sources, entry_type, amount_cents)

          converted =
            if entry_type == "cash_credit_conversion",
              do: converted ++ allocations,
              else: converted

          {updated_sources, converted}
        end)

      backfill_credit_contributions(repo, partner_group_id, converted_sources)
    end)
  end

  defp payments_for_group(repo, group_id) do
    repo.query!(
      """
      SELECT cash_payments.id, cash_payments.recorded_cents
      FROM cash_payments
      JOIN partner_operations ON partner_operations.operation_id = cash_payments.payment_operation_id
      WHERE cash_payments.group_id = ?
      ORDER BY partner_operations.id
      """,
      [group_id]
    ).rows
    |> Enum.map(fn [payment_id, recorded_cents] -> {payment_id, recorded_cents} end)
  end

  defp distribute_settlement(repo, sources, entry_type, amount_cents) do
    {_, sources, allocations} =
      Enum.reduce(sources, {amount_cents, [], []}, fn {payment_id, available},
                                                      {remaining, updated_sources, allocations} ->
        amount = min(remaining, available)

        if payment_id && amount > 0 do
          repo.query!(
            """
            INSERT INTO cash_payment_dispositions (cash_payment_id, disposition, amount_cents)
            VALUES (?, ?, ?)
            """,
            [payment_id, settlement_disposition(entry_type), amount]
          )
        end

        allocation = if amount > 0, do: [{payment_id, amount} | allocations], else: allocations
        {remaining - amount, [{payment_id, available - amount} | updated_sources], allocation}
      end)

    {Enum.reverse(sources), Enum.reverse(allocations)}
  end

  defp settlement_disposition("cash_refund"), do: "refunded"
  defp settlement_disposition("cash_retention"), do: "retained"
  defp settlement_disposition("cash_credit_conversion"), do: "converted"

  defp backfill_credit_contributions(_repo, _partner_group_id, []), do: :ok

  defp backfill_credit_contributions(repo, partner_group_id, converted_sources) do
    credit_lot =
      repo.query!(
        """
        SELECT credit_lots.id
        FROM credit_lots
        JOIN partner_operations ON partner_operations.operation_id = credit_lots.source_operation_id
        WHERE partner_operations.operation_type = 'cancel_group'
          AND json_extract(partner_operations.result, '$.status') = 'applied'
          AND json_extract(partner_operations.result, '$.group_id') = ?
        ORDER BY partner_operations.id DESC
        LIMIT 1
        """,
        [partner_group_id]
      ).rows

    case credit_lot do
      [[credit_lot_id]] ->
        {_principal, _order} =
          Enum.reduce(converted_sources, {0, 0}, fn {payment_id, amount_cents},
                                                    {prior_principal, order} ->
            principal = prior_principal + amount_cents

            repo.query!(
              """
              INSERT INTO credit_lot_contributions
                (credit_lot_id, cash_payment_id, principal_cents, entitlement_cents, funding_order)
              VALUES (?, ?, ?, ?, ?)
              """,
              [
                credit_lot_id,
                payment_id,
                amount_cents,
                credit_value(principal) - credit_value(prior_principal),
                order
              ]
            )

            {principal, order + 1}
          end)

        :ok

      [] ->
        :ok
    end
  end

  defp credit_value(principal_cents), do: principal_cents + div(principal_cents + 5, 10)

  defp refresh_group_totals do
    repo().query!("""
    UPDATE groups
    SET
      lodging_total_cents = COALESCE((
        SELECT SUM(lodging_total_cents) FROM rooms
        WHERE rooms.group_id = groups.id AND rooms.status = 'active'
      ), 0),
      deposit_due_cents = COALESCE((
        SELECT SUM(deposit_due_cents) FROM rooms
        WHERE rooms.group_id = groups.id AND rooms.status = 'active'
      ), 0),
      cash_paid_cents = COALESCE((
        SELECT SUM(cash_paid_cents) FROM rooms
        WHERE rooms.group_id = groups.id AND rooms.status = 'active'
      ), 0),
      credit_paid_cents = COALESCE((
        SELECT SUM(credit_paid_cents) FROM rooms
        WHERE rooms.group_id = groups.id AND rooms.status = 'active'
      ), 0),
      deposit_paid_cents = COALESCE((
        SELECT SUM(cash_paid_cents + credit_paid_cents) FROM rooms
        WHERE rooms.group_id = groups.id AND rooms.status = 'active'
      ), 0)
    """)
  end
end
