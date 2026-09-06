defmodule GroupStay.MigrationTest do
  use ExUnit.Case, async: false

  defmodule LegacyRepo do
    use Ecto.Repo,
      otp_app: :group_stay,
      adapter: Ecto.Adapters.SQLite3
  end

  test "upgrades existing groups with fixed policies and cash funding intact" do
    Application.put_env(:group_stay, LegacyRepo,
      database: ":memory:",
      pool_size: 1,
      priv: "priv/legacy_repo"
    )

    on_exit(fn -> Application.delete_env(:group_stay, LegacyRepo) end)

    start_supervised!(LegacyRepo)
    migrations_path = Application.app_dir(:group_stay, "priv/repo/migrations")

    assert [20_260_828_000_000] =
             Ecto.Migrator.run(LegacyRepo, migrations_path, :up, to: 20_260_828_000_000)

    insert_legacy_group("old-flex", "2026-12-31", "flexible", 700)
    insert_legacy_group("new-flex", "2027-01-01", "flexible", 800)
    insert_legacy_group("advance", "2026-01-01", "advance_purchase", 900)

    assert [20_260_828_010_000] =
             Ecto.Migrator.run(LegacyRepo, migrations_path, :up, all: true)

    result =
      Ecto.Adapters.SQL.query!(
        LegacyRepo,
        """
        SELECT group_id, policy_version, cash_paid_cents, credit_paid_cents
        FROM groups
        ORDER BY group_id
        """,
        []
      )

    assert result.rows == [
             ["advance", "advance-nonrefundable", 900, 0],
             ["new-flex", "flex-30", 800, 0],
             ["old-flex", "flex-14", 700, 0]
           ]
  end

  defp insert_legacy_group(group_id, booked_on, rate_plan, paid_cents) do
    Ecto.Adapters.SQL.query!(
      LegacyRepo,
      """
      INSERT INTO groups (
        group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, status, rooms, lodging_total_cents, deposit_due_cents,
        deposit_paid_cents, cash_refunded_cents, cash_retained_cents, revision,
        inserted_at, updated_at
      ) VALUES (?, 'guest', 'property', ?, '2027-06-01', '2027-06-02', ?, 'active',
                '{}', 1000, 1000, ?, 0, 0, 1, '2026-08-28 00:00:00',
                '2026-08-28 00:00:00')
      """,
      [group_id, booked_on, rate_plan, paid_cents]
    )
  end
end
