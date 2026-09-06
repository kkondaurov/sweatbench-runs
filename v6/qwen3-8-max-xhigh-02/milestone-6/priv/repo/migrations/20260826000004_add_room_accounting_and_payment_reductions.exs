defmodule GroupStay.Repo.Migrations.AddRoomAccountingAndPaymentReductions do
  use Ecto.Migration

  import Ecto.Query

  @flexible_deposit_percent 20

  def change do
    alter table(:rooms) do
      add :status, :string, null: false, default: "active"
      add :lodging_cents, :integer, null: false, default: 0
      add :deposit_cents, :integer, null: false, default: 0
      add :cash_paid_cents, :integer, null: false, default: 0
      add :credit_paid_cents, :integer, null: false, default: 0
    end

    alter table(:groups) do
      add :cash_reduced_cents, :integer, null: false, default: 0
      add :cash_charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:cash_payments) do
      add :refunded_cents, :integer, null: false, default: 0
      add :retained_cents, :integer, null: false, default: 0
      add :converted_cents, :integer, null: false, default: 0
      add :reduced_cents, :integer, null: false, default: 0
      add :charged_back_cents, :integer, null: false, default: 0
    end

    alter table(:credit_applications) do
      add :operation_id, :string
    end

    alter table(:credit_lots) do
      add :unrecovered_clawback_cents, :integer, null: false, default: 0
    end

    create table(:room_allocations) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :cash_payment_id, references(:cash_payments, on_delete: :delete_all)
      add :credit_application_id, references(:credit_applications, on_delete: :delete_all)
      add :amount_cents, :integer, null: false

      timestamps()
    end

    create index(:room_allocations, [:room_id])
    create index(:room_allocations, [:cash_payment_id])
    create index(:room_allocations, [:credit_application_id])

    create table(:credit_lot_contributions) do
      add :lot_id, references(:credit_lots, on_delete: :delete_all), null: false
      add :cash_payment_id, references(:cash_payments, on_delete: :delete_all)
      add :amount_cents, :integer, null: false
      add :position, :integer, null: false

      timestamps()
    end

    create index(:credit_lot_contributions, [:lot_id])
    create index(:credit_lot_contributions, [:cash_payment_id])

    flush()

    backfill_rooms()
    backfill_settled_groups()
    backfill_settled_payment_dispositions()
    backfill_room_allocations()
    backfill_lot_contributions()
  end

  # Every room gets the lodging and deposit amounts originally used for the
  # group requirement. Rooms of cancelled groups are already settled.
  defp backfill_rooms do
    groups =
      repo().all(
        from(g in "groups",
          select: %{
            id: g.id,
            arrival_on: g.arrival_on,
            departure_on: g.departure_on,
            rate_plan: g.rate_plan,
            status: g.status
          }
        )
      )

    Enum.each(groups, fn group ->
      nights = Date.diff(parse_date!(group.departure_on), parse_date!(group.arrival_on))
      status = if group.status == "active", do: "active", else: "cancelled"

      rooms =
        repo().all(
          from(r in "rooms",
            where: r.group_id == ^group.id,
            select: %{id: r.id, nightly_rate_cents: r.nightly_rate_cents}
          )
        )

      Enum.each(rooms, fn room ->
        lodging_cents = nights * room.nightly_rate_cents

        repo().update_all(
          from(r in "rooms", where: r.id == ^room.id),
          set: [
            status: status,
            lodging_cents: lodging_cents,
            deposit_cents: room_deposit(lodging_cents, group.rate_plan)
          ]
        )
      end)
    end)
  end

  # A settled group has no active rooms, so its lodging, due, paid, and
  # outstanding totals all describe nothing.
  defp backfill_settled_groups do
    repo().update_all(
      from(g in "groups", where: g.status != "active"),
      set: [
        lodging_total_cents: 0,
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        credit_paid_cents: 0
      ]
    )
  end

  # Before this release a group settled as a whole, so every payment of a
  # settled group moved to the single disposition chosen by its cancellation.
  defp backfill_settled_payment_dispositions do
    settled_groups =
      repo().all(
        from(g in "groups",
          where: g.status != "active",
          select: %{
            id: g.id,
            refunded_cents: g.refunded_cents,
            converted_cents: g.converted_cents
          }
        )
      )

    Enum.each(settled_groups, fn group ->
      column =
        cond do
          group.converted_cents > 0 -> "converted_cents"
          group.refunded_cents > 0 -> "refunded_cents"
          true -> "retained_cents"
        end

      repo().query!(
        "UPDATE cash_payments SET #{column} = amount_cents WHERE group_id = ?",
        [group.id]
      )
    end)
  end

  # Brings pre-durable-record funding forward as one unattributed senior
  # block per group (aggregate cash first, then hotel-credit lots in
  # original consumption order), then allocates funding retained by durable
  # operation records in durable-record commit order. Creating the
  # allocations changes no aggregate cash, credit, or liability balance.
  defp backfill_room_allocations do
    record_ids = recorded_operation_ids()

    groups = repo().all(from(g in "groups", where: g.status == "active", select: %{id: g.id}))

    Enum.each(groups, fn group ->
      rooms =
        repo().all(
          from(r in "rooms",
            where: r.group_id == ^group.id,
            order_by: [asc: r.position],
            select: %{id: r.id, deposit_cents: r.deposit_cents}
          )
        )

      payments =
        repo().all(
          from(p in "cash_payments",
            where: p.group_id == ^group.id,
            order_by: [asc: p.id],
            select: %{id: p.id, amount_cents: p.amount_cents, operation_id: p.operation_id}
          )
        )

      applications =
        repo().all(
          from(a in "credit_applications",
            where: a.group_id == ^group.id,
            order_by: [asc: a.id],
            select: %{id: a.id, amount_cents: a.amount_cents}
          )
        )

      {legacy_payments, recorded_payments} =
        Enum.split_with(payments, fn payment -> not recorded?(payment, record_ids) end)

      recorded_payments =
        Enum.sort_by(recorded_payments, fn payment ->
          Map.fetch!(record_ids, payment.operation_id)
        end)

      sources =
        Enum.map(legacy_payments, &{:cash, &1.id, &1.amount_cents}) ++
          Enum.map(applications, &{:credit, &1.id, &1.amount_cents}) ++
          Enum.map(recorded_payments, &{:cash, &1.id, &1.amount_cents})

      allocate_sources(rooms, sources)
    end)
  end

  defp allocate_sources(rooms, sources) do
    initial = Enum.map(rooms, fn room -> {room.id, room.deposit_cents, 0, 0} end)

    final =
      Enum.reduce(sources, initial, fn {kind, ref_pk, amount_cents}, state ->
        {state, takes} = take_capacity(state, kind, amount_cents, [])

        Enum.each(takes, fn {room_pk, take} ->
          insert_allocation(kind, ref_pk, room_pk, take)
        end)

        state
      end)

    Enum.each(final, fn
      {_room_pk, _capacity, 0, 0} ->
        :ok

      {room_pk, _capacity, cash_paid, credit_paid} ->
        repo().update_all(
          from(r in "rooms", where: r.id == ^room_pk),
          inc: [cash_paid_cents: cash_paid, credit_paid_cents: credit_paid]
        )
    end)
  end

  defp take_capacity(rooms, kind, remaining, acc) do
    take_from_rooms(rooms, kind, remaining, acc, [])
  end

  defp take_from_rooms(rooms, _kind, 0, acc, done) do
    {Enum.reverse(done) ++ rooms, Enum.reverse(acc)}
  end

  defp take_from_rooms([], _kind, remaining, _acc, _done) when remaining > 0 do
    raise "funding exceeds room deposit capacity during backfill"
  end

  defp take_from_rooms([{room_pk, capacity, cash, credit} | rest], kind, remaining, acc, done) do
    take = min(capacity, remaining)

    entry =
      case kind do
        :cash -> {room_pk, capacity - take, cash + take, credit}
        :credit -> {room_pk, capacity - take, cash, credit + take}
      end

    acc = if take > 0, do: [{room_pk, take} | acc], else: acc
    take_from_rooms(rest, kind, remaining - take, acc, [entry | done])
  end

  defp insert_allocation(kind, ref_pk, room_pk, amount_cents) do
    now = NaiveDateTime.utc_now(:second)

    row =
      case kind do
        :cash ->
          %{
            room_id: room_pk,
            cash_payment_id: ref_pk,
            credit_application_id: nil,
            amount_cents: amount_cents,
            inserted_at: now,
            updated_at: now
          }

        :credit ->
          %{
            room_id: room_pk,
            cash_payment_id: nil,
            credit_application_id: ref_pk,
            amount_cents: amount_cents,
            inserted_at: now,
            updated_at: now
          }
      end

    repo().insert_all("room_allocations", [row])
  end

  # A credit lot whose issuing cancellation has a durable record keeps, for
  # each contributing payment, the converted cash needed to compute
  # entitlements if the payment is later charged back. The unattributed
  # senior block contributes first, then recorded payments in commit order.
  defp backfill_lot_contributions do
    records =
      repo().all(
        from(r in "operation_records",
          order_by: [asc: r.id],
          select: %{
            id: r.id,
            operation_id: r.operation_id,
            type: r.type,
            payload: r.payload,
            result: r.result
          }
        )
      )

    record_ids = Map.new(records, &{&1.operation_id, &1.id})
    records_by_operation = Map.new(records, &{&1.operation_id, &1})

    lots =
      repo().all(
        from(l in "credit_lots", select: %{id: l.id, source_operation_id: l.source_operation_id})
      )

    Enum.each(lots, fn lot ->
      with %{type: "cancel_group"} = record <-
             Map.get(records_by_operation, lot.source_operation_id),
           %{"status" => "applied"} <- Jason.decode!(record.result),
           %{"group_id" => group_id} when is_binary(group_id) <- Jason.decode!(record.payload),
           [%{id: group_pk}] <-
             repo().all(from(g in "groups", where: g.group_id == ^group_id, select: %{id: g.id})) do
        payments =
          repo().all(
            from(p in "cash_payments",
              where: p.group_id == ^group_pk,
              order_by: [asc: p.id],
              select: %{id: p.id, amount_cents: p.amount_cents, operation_id: p.operation_id}
            )
          )

        {legacy_payments, recorded_payments} =
          Enum.split_with(payments, fn payment -> not recorded?(payment, record_ids) end)

        recorded_payments =
          Enum.sort_by(recorded_payments, fn payment ->
            Map.fetch!(record_ids, payment.operation_id)
          end)

        entries =
          legacy_entry(legacy_payments) ++
            Enum.map(recorded_payments, &{&1.id, &1.amount_cents})

        if entries != [] do
          now = NaiveDateTime.utc_now(:second)

          rows =
            entries
            |> Enum.with_index()
            |> Enum.map(fn {{payment_pk, amount_cents}, position} ->
              %{
                lot_id: lot.id,
                cash_payment_id: payment_pk,
                amount_cents: amount_cents,
                position: position,
                inserted_at: now,
                updated_at: now
              }
            end)

          repo().insert_all("credit_lot_contributions", rows)
        end
      end
    end)
  end

  defp legacy_entry([]), do: []

  defp legacy_entry(payments) do
    [{nil, payments |> Enum.map(& &1.amount_cents) |> Enum.sum()}]
  end

  defp recorded_operation_ids do
    repo().all(from(r in "operation_records", select: {r.operation_id, r.id})) |> Map.new()
  end

  defp recorded?(%{operation_id: nil}, _record_ids), do: false
  defp recorded?(payment, record_ids), do: Map.has_key?(record_ids, payment.operation_id)

  defp parse_date!(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, reason} -> raise "invalid stored date #{inspect(value)}: #{reason}"
    end
  end

  defp parse_date!(%Date{} = date), do: date

  defp room_deposit(lodging_cents, "flexible") do
    round_half_up(lodging_cents * @flexible_deposit_percent, 100)
  end

  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  defp round_half_up(numerator, denominator) do
    div(2 * numerator + denominator, 2 * denominator)
  end
end
