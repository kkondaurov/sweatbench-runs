defmodule GroupStay.MigrationUpgradeTestRepo do
  use Ecto.Repo,
    otp_app: :group_stay,
    adapter: Ecto.Adapters.SQLite3
end

defmodule GroupStay.MigrationUpgradeTest do
  use ExUnit.Case, async: false

  alias GroupStay.MigrationUpgradeTestRepo, as: Repo

  test "brings legacy and durable funding forward in funding order" do
    database_path =
      Path.join(
        System.tmp_dir!(),
        "group_stay_migration_#{System.unique_integer([:positive])}.db"
      )

    on_exit(fn -> File.rm(database_path) end)

    start_supervised!({Repo, [database: database_path, pool_size: 1, log: false]})

    migrations_path = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations_path, :up, to: 20_260_829_020_000)

    group_id = Ecto.UUID.generate()
    room_a_id = Ecto.UUID.generate()
    room_b_id = Ecto.UUID.generate()
    credit_lot_id = Ecto.UUID.generate()

    query!(
      """
      INSERT INTO groups
        (id, group_id, guest_id, property_id, booked_on, arrival_on, departure_on, rate_plan,
         status, lodging_total_cents, deposit_due_cents, deposit_paid_cents, revision,
         policy_version, cash_paid_cents, credit_paid_cents)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        group_id,
        "ordered-group",
        "guest-1",
        "property-1",
        "2026-01-01",
        "2026-02-01",
        "2026-02-02",
        "flexible",
        "active",
        20_000,
        4_000,
        4_000,
        3,
        "flex-14",
        2_000,
        2_000
      ]
    )

    query!(
      """
      INSERT INTO rooms (id, group_id, room_id, nightly_rate_cents, position)
      VALUES (?, ?, ?, ?, ?), (?, ?, ?, ?, ?)
      """,
      [room_a_id, group_id, "room-a", 10_000, 0, room_b_id, group_id, "room-b", 10_000, 1]
    )

    query!(
      """
      INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on)
      VALUES (?, ?, ?, ?, ?)
      """,
      [credit_lot_id, "guest-1", "credit-source", 0, "2028-01-01"]
    )

    query!(
      """
      INSERT INTO credit_applications (id, group_id, credit_lot_id, amount_cents)
      VALUES (?, ?, ?, ?)
      """,
      [Ecto.UUID.generate(), group_id, credit_lot_id, 2_000]
    )

    query!(
      """
      INSERT INTO partner_operations (operation_id, operation_type, submitted_payload, result)
      VALUES (?, ?, ?, ?), (?, ?, ?, ?)
      """,
      [
        "apply-1",
        "apply_hotel_credit",
        "{}",
        ~s({"status":"applied","group_id":"ordered-group","amount_cents":2000}),
        "pay-1",
        "record_cash_payment",
        "{}",
        ~s({"status":"applied","group_id":"ordered-group","amount_cents":1000})
      ]
    )

    Ecto.Migrator.run(Repo, migrations_path, :up, all: true)

    assert query!(
             """
             SELECT room_id, cash_paid_cents, credit_paid_cents
             FROM rooms
             ORDER BY position
             """,
             []
           ).rows == [["room-a", 1_000, 1_000], ["room-b", 1_000, 1_000]]

    assert query!(
             """
             SELECT cash_paid_cents, credit_paid_cents, deposit_paid_cents
             FROM groups
             WHERE group_id = 'ordered-group'
             """,
             []
           ).rows == [[2_000, 2_000, 4_000]]
  end

  defp query!(statement, params), do: Ecto.Adapters.SQL.query!(Repo, statement, params)
end
