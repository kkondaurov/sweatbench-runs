defmodule GroupStay.Repo.Migrations.UpgradeFromOperationalCoreTest do
  use ExUnit.Case, async: false

  alias GroupStay.UpgradeRepo

  @migrations_dir "priv/repo/migrations"
  @economics_version 20_260_826_000_002

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "group-stay-upgrade-#{System.unique_integer([:positive])}.db"
      )

    Application.put_env(:group_stay, UpgradeRepo, database: path, pool_size: 1)
    start_supervised!(UpgradeRepo)

    on_exit(fn ->
      for suffix <- ["", "-wal", "-shm"] do
        File.rm(path <> suffix)
      end
    end)

    :ok
  end

  test "a database created by the first release upgrades with implied policies", %{} do
    # Bring the throwaway database up to exactly the previous release.
    Ecto.Migrator.run(UpgradeRepo, @migrations_dir, :up,
      to: @economics_version - 1,
      log: false
    )

    # Rows shaped exactly as the previous release wrote them: no credit
    # columns, cash-only deposits, no policy versions.
    legacy_rows()
    |> Enum.each(&insert_legacy_group!/1)

    # Upgrade it with this release's migration.
    Ecto.Migrator.run(UpgradeRepo, @migrations_dir, :up, all: true, log: false)

    assert %{
             rows: rows,
             columns: columns
           } =
             UpgradeRepo.query!(
               "SELECT group_id, policy_version, cash_paid_cents, credit_paid_cents, " <>
                 "cash_converted_to_credit_cents FROM groups ORDER BY group_id"
             )

    assert Enum.map(columns, fn column -> String.to_existing_atom(column) end) == [
             :group_id,
             :policy_version,
             :cash_paid_cents,
             :credit_paid_cents,
             :cash_converted_to_credit_cents
           ]

    assert rows == [
             # Flexible, booked well before the cutoff, actively holding cash.
             ["legacy-active", "flex-14", 5_000, 0, 0],
             # Advance purchase keeps its non-refundable policy regardless of date.
             ["legacy-advance", "advance-nonrefundable", 12_000, 0, 0],
             # Cancelled groups hold no cash and still receive their policy.
             ["legacy-cancelled", "flex-14", 0, 0, 0],
             # Booked exactly on the cutoff date: the newer window applies.
             ["legacy-on-cutoff", "flex-30", 500, 0, 0]
           ]

    # Durable idempotency begins with this release: the upgraded database gets
    # an empty operations table rather than reconstructed records.
    assert %{rows: [[0]]} = UpgradeRepo.query!("SELECT COUNT(*) FROM operations")
  end

  defp legacy_rows do
    [
      [
        group_id: "legacy-active",
        rate_plan: "flexible",
        status: "active",
        booked_on: "2026-05-01",
        arrival_on: "2026-06-10",
        departure_on: "2026-06-13",
        revision: 2,
        lodging_total_cents: 45_000,
        deposit_due_cents: 9_000,
        deposit_paid_cents: 5_000
      ],
      [
        group_id: "legacy-advance",
        rate_plan: "advance_purchase",
        status: "active",
        booked_on: "2027-03-02",
        arrival_on: "2027-04-10",
        departure_on: "2027-04-13",
        revision: 3,
        lodging_total_cents: 12_000,
        deposit_due_cents: 12_000,
        deposit_paid_cents: 12_000
      ],
      [
        group_id: "legacy-cancelled",
        rate_plan: "flexible",
        status: "cancelled",
        booked_on: "2026-09-09",
        arrival_on: "2026-11-01",
        departure_on: "2026-11-04",
        revision: 2,
        lodging_total_cents: 30_000,
        deposit_due_cents: 0,
        deposit_paid_cents: 0
      ],
      [
        group_id: "legacy-on-cutoff",
        rate_plan: "flexible",
        status: "active",
        booked_on: "2027-01-01",
        arrival_on: "2027-02-01",
        departure_on: "2027-02-04",
        revision: 2,
        lodging_total_cents: 2_500,
        deposit_due_cents: 500,
        deposit_paid_cents: 500
      ]
    ]
  end

  defp insert_legacy_group!(row) do
    fields = Keyword.merge(row, guest_id: "guest-upgrade", property_id: "ams-canal")

    UpgradeRepo.query!(
      """
      INSERT INTO groups
        (id, group_id, guest_id, property_id, rate_plan, status, booked_on,
         arrival_on, departure_on, revision, lodging_total_cents,
         deposit_due_cents, deposit_paid_cents, refunded_cents, retained_cents,
         inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?)
      """,
      [
        Ecto.UUID.bingenerate(),
        fields[:group_id],
        fields[:guest_id],
        fields[:property_id],
        fields[:rate_plan],
        fields[:status],
        fields[:booked_on],
        fields[:arrival_on],
        fields[:departure_on],
        fields[:revision],
        fields[:lodging_total_cents],
        fields[:deposit_due_cents],
        fields[:deposit_paid_cents],
        "2026-05-01 00:00:00Z",
        "2026-05-01 00:00:00Z"
      ]
    )
  end
end
