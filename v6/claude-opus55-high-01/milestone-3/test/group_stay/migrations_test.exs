defmodule GroupStay.MigrationsTest do
  # Runs the migrations against its own database file, outside the sandboxed test database.
  use ExUnit.Case, async: false

  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @migrations_path Application.app_dir(:group_stay, "priv/repo/migrations")
  @first_release 20_260_923_000_000
  @second_release 20_260_923_010_000

  setup do
    path =
      Path.join(System.tmp_dir!(), "group_stay_upgrade_#{System.unique_integer([:positive])}.db")

    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix) end)

    repo =
      start_supervised!(
        {Repo, name: nil, database: path, pool: DBConnection.ConnectionPool, pool_size: 1}
      )

    Repo.put_dynamic_repo(repo)
    %{repo: repo}
  end

  test "groups created by the first release receive the policy their booking date implies",
       %{repo: repo} do
    migrate(repo, to: @first_release)

    for {group_id, booked_on, rate_plan} <- [
          {"old-flex", "2026-12-31", "flexible"},
          {"new-flex", "2027-01-01", "flexible"},
          {"old-advance", "2026-10-03", "advance_purchase"}
        ] do
      Repo.query!(
        """
        INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
          rate_plan, status, revision, lodging_total_cents, deposit_due_cents, deposit_paid_cents,
          inserted_at, updated_at)
        VALUES (?, 'guest-22', 'ams-canal', ?, '2027-03-01', '2027-03-04', ?, 'active', 2,
          97500, 19500, 5000, '2026-10-03T00:00:00.000000Z', '2026-10-03T00:00:00.000000Z')
        """,
        [group_id, booked_on, rate_plan]
      )
    end

    migrate(repo, all: true)

    assert {:ok, old_flex} = Groups.fetch_group("old-flex")
    assert old_flex.policy_version == "flex-14"
    assert Group.refundable_until(old_flex) == ~D[2027-02-15]
    assert old_flex.credit_paid_cents == 0
    assert Group.cash_paid_cents(old_flex) == 5000

    assert {:ok, new_flex} = Groups.fetch_group("new-flex")
    assert new_flex.policy_version == "flex-30"
    assert Group.refundable_until(new_flex) == ~D[2027-01-30]

    assert {:ok, old_advance} = Groups.fetch_group("old-advance")
    assert old_advance.policy_version == "advance-nonrefundable"
    assert Group.refundable_until(old_advance) == nil
  end

  test "groups created by the second release keep working with durable operations",
       %{repo: repo} do
    migrate(repo, to: @second_release)

    Repo.query!("""
    INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
      rate_plan, policy_version, status, revision, lodging_total_cents, deposit_due_cents,
      deposit_paid_cents, credit_paid_cents, inserted_at, updated_at)
    VALUES ('group-81', 'guest-22', 'ams-canal', '2026-10-03', '2026-12-10', '2026-12-13',
      'flexible', 'flex-14', 'active', 2, 97500, 19500, 5000, 0,
      '2026-10-03T00:00:00.000000Z', '2026-10-03T00:00:00.000000Z')
    """)

    Repo.query!("""
    INSERT INTO ledger_entries (group_ref, operation_id, kind, amount_cents, occurred_on,
      inserted_at)
    SELECT id, 'op-legacy', 'cash_payment', 5000, '2026-10-04', '2026-10-04T00:00:00.000000Z'
    FROM groups
    """)

    migrate(repo, all: true)

    # Identifiers from earlier releases are not reconstructed as idempotency records.
    assert {:error, :not_found} = GroupStay.OperationRecords.fetch_result("op-legacy")

    pay = %{
      "operation_id" => "op-legacy",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-05",
      "group_id" => "group-81",
      "amount_cents" => 1000,
      "expected_revision" => 2
    }

    assert %{"status" => "applied", "revision" => 3, "outstanding_deposit_cents" => 13_500} =
             GroupStay.PartnerOperations.process_operation(pay)

    assert {:ok, %{"status" => "applied", "revision" => 3}} =
             GroupStay.OperationRecords.fetch_result("op-legacy")

    assert Groups.ledger_totals(~D[2026-10-05]).cash_held_cents == 6000
  end

  defp migrate(repo, opts) do
    Ecto.Migrator.run(Repo, @migrations_path, :up, [dynamic_repo: repo, log: false] ++ opts)
  end
end
