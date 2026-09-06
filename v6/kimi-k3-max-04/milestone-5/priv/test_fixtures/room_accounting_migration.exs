# Builds a scratch database with only the pre-room-accounting migrations,
# loads legacy and durable-record funding fixtures, runs the remaining
# migrations, and verifies the backfill brought the funding forward.
#
# Invoked by GroupStay.RoomAccountingMigrationTest through
# `GROUP_STAY_DATABASE_PATH=<scratch> mix run <this file>`.
defmodule MigrationFixture do
  alias GroupStay.Repo
  alias GroupStay.Groups
  alias GroupStay.Groups.{CashAllocation, CreditApplication}

  import Ecto.Query

  @pre_room_accounting [
    202_608_270_000_00,
    202_608_271_200_00,
    202_608_271_800_00
  ]

  def run do
    # `mix run --no-start` leaves everything unstarted; start the application
    # here so dev's normal connection pool (not the sandbox) is used.
    {:ok, _} = Application.ensure_all_started(:group_stay)
    load_migration_modules()
    migrate_upto(@pre_room_accounting)
    insert_legacy_group()
    insert_durable_group()
    migrate_all()

    verify_legacy_group()
    verify_durable_group()

    IO.puts("migration-fixture-ok")
  end

  # Migrations under priv/ are compiled on demand, the way `mix ecto.migrate`
  # loads them.
  defp load_migration_modules do
    "priv/repo/migrations/*.exs"
    |> Path.wildcard()
    |> Enum.each(&Code.require_file/1)
  end

  defp migrate_upto(versions) do
    Ecto.Migrator.with_repo(Repo, fn repo ->
      Ecto.Migrator.run(repo, tuples_for(repo, &(&1 in versions)), :up, all: true)
    end)
  end

  defp migrate_all do
    Ecto.Migrator.with_repo(Repo, fn repo ->
      Ecto.Migrator.run(repo, tuples_for(repo, fn _ -> true end), :up, all: true)
    end)
  end

  defp tuples_for(repo, include?) do
    repo
    |> Ecto.Migrator.migrations()
    |> Enum.filter(fn {status, version, _name} -> status == :down and include?.(version) end)
    |> Enum.map(fn {_status, version, name} -> {version, module_of(name)} end)
  end

  defp module_of(name) do
    Module.concat(["GroupStay.Repo.Migrations", Macro.camelize(name)])
  end

  # A group whose funding predates durable operation records. The credit
  # applications are inserted out of consumption order on purpose; the
  # backfill must still allocate them in original consumption order
  # (earliest expiry, then source_operation_id).
  defp insert_legacy_group do
    group_id = Ecto.UUID.generate()
    now = timestamp()

    Repo.query!(
      """
      INSERT INTO groups (id, group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
                          rate_plan, policy_version, status, revision, lodging_total_cents,
                          deposit_due_cents, deposit_paid_cents, cash_paid_cents, credit_paid_cents,
                          refunded_cents, retained_cents, converted_cents, inserted_at, updated_at)
      VALUES (?, 'legacy', 'g1', 'p1', '2026-10-03', '2026-12-10', '2026-12-13', 'flexible',
              'flex-14', 'active', 1, 97500, 19500, 13000, 10000, 3000, NULL, NULL, 0, ?, ?)
      """,
      [group_id, now, now]
    )

    insert_room(group_id, "room-a", 15000, 0, now)
    insert_room(group_id, "room-b", 17500, 1, now)

    lot_first_down = insert_lot("g1", "mt-first", "2027-06-30", now)
    lot_earlier = insert_lot("g1", "mt-early", "2027-01-01", now)

    # Insert the later-expiry application first: original DB order is not the
    # consumption order, so the backfill must sort by (expires_on, source id).
    insert_application(lot_first_down, group_id, 800, now)
    insert_application(lot_earlier, group_id, 2200, now)
  end

  # A group whose cash and credit are fully covered by durable records; a
  # rejected record and a foreign-group payment are interleaved and must not
  # be allocated.
  defp insert_durable_group do
    group_id = Ecto.UUID.generate()
    now = timestamp()

    Repo.query!(
      """
      INSERT INTO groups (id, group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
                          rate_plan, policy_version, status, revision, lodging_total_cents,
                          deposit_due_cents, deposit_paid_cents, cash_paid_cents, credit_paid_cents,
                          refunded_cents, retained_cents, converted_cents, inserted_at, updated_at)
      VALUES (?, 'durable', 'g2', 'p2', '2026-10-04', '2026-12-10', '2026-12-13', 'flexible',
              'flex-14', 'active', 2, 45000, 9000, 9000, 6000, 3000, NULL, NULL, 0, ?, ?)
      """,
      [group_id, now, now]
    )

    insert_room(group_id, "room-c", 15000, 0, now)

    lot = insert_lot("g2", "mt-durable", "2027-06-30", now)
    insert_application(lot, group_id, 3000, now)

    insert_record(now, "rec-1", "record_cash_payment", "applied", ~s({"group_id":"durable","amount_cents":6000}))
    insert_record(now, "rec-2", "wobble", "rejected", ~s({"group_id":"durable"}))
    insert_record(now, "rec-3", "apply_hotel_credit", "applied", ~s({"group_id":"durable","amount_cents":3000}))
    insert_record(now, "rec-4", "record_cash_payment", "applied", ~s({"group_id":"ghost","amount_cents":9}))
  end

  defp insert_room(group_id, room_id, rate, position, now) do
    Repo.query!(
      """
      INSERT INTO rooms (id, group_id, room_id, nightly_rate_cents, position, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      [Ecto.UUID.generate(), group_id, room_id, rate, position, now, now]
    )
  end

  defp insert_lot(guest_id, source, expires_on, now) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO credit_lots (id, guest_id, source_operation_id, available_cents, expires_on, inserted_at, updated_at)
      VALUES (?, ?, ?, 0, ?, ?, ?)
      """,
      [id, guest_id, source, expires_on, now, now]
    )

    id
  end

  defp insert_application(lot_id, group_id, amount, now) do
    Repo.query!(
      """
      INSERT INTO credit_applications (id, lot_id, group_id, amount_cents, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [Ecto.UUID.generate(), lot_id, group_id, amount, now, now]
    )
  end

  defp insert_record(now, operation_id, type, status, request) do
    Repo.query!(
      """
      INSERT INTO operation_records (operation_id, type, status, request, result, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, '{}', ?, ?)
      """,
      [operation_id, type, status, request, now, now]
    )
  end

  defp timestamp do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()
  end

  defp verify_legacy_group do
    group = Groups.get_group("legacy") |> Groups.group_view()

    [room_a, room_b] = group.rooms

    # Senior block: cash 10000 fills room-a (9000) and room-b (1000), then
    # credit 3000 fills room-b in the lots' consumption order.
    unless room_a.cash_paid_cents == 9000 and room_a.credit_paid_cents == 0 and
             room_b.cash_paid_cents == 1000 and room_b.credit_paid_cents == 3000 and
             group.deposit_due_cents == 19500 and group.deposit_paid_cents == 13000 do
      raise "legacy backfill mismatch: #{inspect(group)}"
    end

    unless senior_block_unattributed?("legacy") do
      raise "legacy allocations must be unattributed"
    end
  end

  defp verify_durable_group do
    group = Groups.get_group("durable") |> Groups.group_view()
    [room_c] = group.rooms

    unless room_c.cash_paid_cents == 6000 and room_c.credit_paid_cents == 3000 and
             group.deposit_paid_cents == 9000 do
      raise "durable backfill mismatch: #{inspect(group)}"
    end

    allocations =
      Repo.all(
        from a in CashAllocation,
          join: g in GroupStay.Groups.Group,
          on: a.group_id == g.id and g.group_id == "durable"
      )

    unless length(allocations) == 1 and hd(allocations).operation_id == "rec-1" do
      raise "durable allocations mismatch: #{inspect(allocations)}"
    end

    # The rejected record and the foreign-group payment cannot be targeted.
    unless Groups.get_payment("rec-2") == :not_reconcilable or Groups.get_payment("rec-2") == nil do
      raise "rejected record must not become a payment"
    end

    applications =
      Repo.all(
        from a in CreditApplication,
          join: g in GroupStay.Groups.Group,
          on: a.group_id == g.id and g.group_id == "durable"
      )

    unless Enum.all?(applications, &(not is_nil(&1.room_id))) do
      raise "applications must be attributed to rooms"
    end
  end

  defp senior_block_unattributed?(group_id) do
    allocations =
      Repo.all(
        from a in CashAllocation,
          join: g in GroupStay.Groups.Group,
          on: a.group_id == g.id and g.group_id == ^group_id,
          select: a.operation_id
      )

    Enum.all?(allocations, &is_nil/1)
  end
end

MigrationFixture.run()
