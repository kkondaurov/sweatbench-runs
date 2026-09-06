defmodule GroupStay.RequestFourMigrationRepo do
  use Ecto.Repo,
    otp_app: :group_stay,
    adapter: Ecto.Adapters.SQLite3
end

defmodule GroupStay.RequestFourMigrationTest do
  use ExUnit.Case, async: false

  alias GroupStay.RequestFourMigrationRepo, as: Repo

  @migrations Path.expand("../../priv/repo/migrations", __DIR__)
  @request_three 20_260_829_000_002

  setup do
    database =
      Path.join(
        System.tmp_dir!(),
        "group_stay_request_four_#{System.unique_integer([:positive])}.db"
      )

    :ok = Ecto.Adapters.SQLite3.storage_up(database: database)
    start_supervised!({Repo, database: database, pool_size: 1})
    Ecto.Migrator.run(Repo, @migrations, :up, to: @request_three)

    on_exit(fn ->
      File.rm(database)
      File.rm("#{database}-shm")
      File.rm("#{database}-wal")
    end)

    :ok
  end

  test "backfills cancelled rooms, interleaved funding, and converted payment entitlements" do
    insert_active_group()
    insert_cancelled_group()

    Ecto.Migrator.run(Repo, @migrations, :up, all: true)

    assert %{
             rows: [
               ["a", "active"],
               ["b", "active"],
               ["c", "active"],
               ["cancelled-room", "cancelled"]
             ]
           } =
             Repo.query!("SELECT room_id, status FROM rooms ORDER BY room_id")

    assert %{
             rows: [
               ["a", "cash", nil, nil, 20],
               ["b", "credit", nil, 1, 10],
               ["b", "credit", nil, 2, 5],
               ["c", "cash", "pay-durable", nil, 10],
               ["c", "credit", nil, 2, 5]
             ]
           } =
             Repo.query!(
               """
               SELECT room_id, funding_kind, payment_operation_id, credit_lot_id, amount_cents
               FROM room_funding_allocations
               WHERE group_id = ?
               ORDER BY room_id, funding_kind, credit_lot_id
               """,
               ["active"]
             )

    assert %{
             rows: [
               [nil, 50, 55],
               ["pay-converted", 50, 55]
             ]
           } =
             Repo.query!(
               """
               SELECT payment_operation_id, cash_amount_cents, entitlement_cents
               FROM credit_lot_contributions
               WHERE credit_lot_id = (SELECT id FROM credit_lots WHERE source_operation_id = ?)
               ORDER BY payment_operation_id
               """,
               ["cancel-converted"]
             )
  end

  defp insert_active_group do
    insert_group("active", "active", 30, 20, 0, 300, 60)

    Repo.query!(
      """
      INSERT INTO rooms (group_id, room_id, nightly_rate_cents, position, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
             (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
             (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      ["active", "a", 100, 0, "active", "b", 75, 1, "active", "c", 125, 2]
    )

    Repo.query!(
      """
      INSERT INTO credit_lots (guest_id, source_operation_id, remaining_cents, expires_on, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
             (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      ["guest", "legacy-lot", 0, "2027-01-01", "guest", "durable-lot", 0, "2027-01-02"]
    )

    Repo.query!(
      """
      INSERT INTO credit_applications (group_id, credit_lot_id, amount_cents, inserted_at, updated_at)
      VALUES (?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
             (?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      ["active", 1, 10, "active", 2, 10]
    )

    insert_operation("apply-durable", "apply_hotel_credit", "active", 10)
    insert_operation("pay-durable", "record_cash_payment", "active", 10)
  end

  defp insert_cancelled_group do
    insert_group("cancelled", "cancelled", 100, 0, 100, 500, 100)

    Repo.query!(
      """
      INSERT INTO rooms (group_id, room_id, nightly_rate_cents, position, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      ["cancelled", "cancelled-room", 500, 0]
    )

    insert_operation("pay-converted", "record_cash_payment", "cancelled", 50)
    insert_operation("cancel-converted", "cancel_group", "cancelled", nil)

    Repo.query!(
      """
      INSERT INTO credit_lots (guest_id, source_operation_id, remaining_cents, expires_on, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      ["guest", "cancel-converted", 110, "2027-01-01"]
    )
  end

  defp insert_group(
         group_id,
         status,
         cash_paid_cents,
         credit_paid_cents,
         converted_cents,
         lodging_total_cents,
         deposit_due_cents
       ) do
    Repo.query!(
      """
      INSERT INTO groups (
        group_id, guest_id, property_id, booked_on, arrival_on, departure_on, rate_plan,
        status, revision, lodging_total_cents, deposit_due_cents, deposit_paid_cents,
        refunded_cents, retained_cents, policy_version, cash_paid_cents, credit_paid_cents,
        cash_converted_to_credit_cents, inserted_at, updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      [
        group_id,
        "guest",
        "property",
        "2026-01-01",
        "2026-04-01",
        "2026-04-02",
        "flexible",
        status,
        1,
        lodging_total_cents,
        deposit_due_cents,
        cash_paid_cents + credit_paid_cents,
        0,
        0,
        "flex-14",
        cash_paid_cents,
        credit_paid_cents,
        converted_cents
      ]
    )
  end

  defp insert_operation(operation_id, operation_type, group_id, amount_cents) do
    result =
      %{status: "applied", group_id: group_id}
      |> maybe_put(:amount_cents, amount_cents)
      |> Jason.encode!()

    Repo.query!(
      """
      INSERT INTO partner_operations (operation_id, operation_type, submitted_payload, result, inserted_at)
      VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
      """,
      [operation_id, operation_type, "{}", result]
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
