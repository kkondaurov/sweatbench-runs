defmodule GroupStay.RoomAccountingMigrationTest do
  use ExUnit.Case, async: false
  alias GroupStay.{Repo, Reservations}
  alias GroupStay.Reservations.{CashAllocation, CreditAllocation, CreditEntitlement}
  import Ecto.Query

  test "upgrade allocates legacy funding before recorded funding without changing balances or audit history" do
    token = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    database = Path.expand("_build/room-migration-#{token}.db")
    on_exit(fn -> for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> suffix) end)

    repo =
      start_supervised!(
        {Repo, name: nil, database: database, pool_size: 1, pool: DBConnection.ConnectionPool}
      )

    previous = Repo.put_dynamic_repo(repo)
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)
    migrations = Application.app_dir(:group_stay, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :up, to: 20_260_907_000_002, log: false)

    # Cash 60 + credit 50 is legacy. Journaled credit 50 commits before cash 100,
    # despite a later occurred_on. Deliberately misleading payload types ensure
    # retained record types, not payload guesses, classify the recorded funding.
    insert_group("g", "active", 160, 100, 0, 0, 0)
    insert_group("converted", "cancelled", 10, 0, 0, 0, 10)
    insert_group("refunded", "cancelled", 30, 0, 30, 0, 0)
    insert_group("retained", "cancelled", 20, 0, 0, 20, 0)

    Repo.query!(
      "INSERT INTO credit_lots (id, guest_id, source_operation_id, remaining_cents, expires_on) VALUES (1, 'guest', 'legacy-lot', 10, '2028-01-01'), (2, 'guest', 'other-lot', 20, '2028-02-01'), (3, 'guest', 'convert', 11, '2028-01-01')"
    )

    Repo.query!(
      "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES ('g', 1, 70), ('g', 2, 30)"
    )

    insert_record("credit", "apply_hotel_credit", "g", 50, "2027-05-01")
    insert_record("cash", "record_cash_payment", "g", 100, "2027-01-01")
    insert_record("converted-pay", "record_cash_payment", "converted", 5, "2027-01-01")
    insert_record("convert", "cancel_group", "converted", nil, "2027-01-01")
    insert_record("refunded-pay", "record_cash_payment", "refunded", 20, "2027-01-01")
    insert_record("retained-pay", "record_cash_payment", "retained", 20, "2027-01-01")
    audit = Repo.query!("SELECT * FROM operations ORDER BY id").rows

    aggregates =
      Repo.query!(
        "SELECT group_id, cash_paid_cents, credit_paid_cents FROM groups ORDER BY group_id"
      ).rows

    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
    assert Repo.query!("SELECT * FROM operations ORDER BY id").rows == audit

    assert Repo.query!(
             "SELECT group_id, cash_paid_cents, credit_paid_cents FROM groups ORDER BY group_id"
           ).rows == aggregates

    assert {:ok, group} = Reservations.get_group("g")

    assert Enum.map(group.rooms, &{&1.room_id, &1.cash_paid_cents, &1.credit_paid_cents}) == [
             {"a", 60, 40},
             {"b", 40, 60},
             {"c", 60, 0}
           ]

    assert Repo.all(
             from a in CreditAllocation,
               order_by: a.id,
               select: {a.room_id, a.credit_lot_id, a.amount_cents}
           ) == [{"a", 1, 40}, {"b", 1, 10}, {"b", 1, 20}, {"b", 2, 30}]

    assert Repo.all(
             from a in CashAllocation,
               where: a.group_id == "g",
               order_by: a.id,
               select: {a.room_id, a.payment_operation_id, a.amount_cents}
           ) == [{"a", nil, 60}, {"b", "cash", 40}, {"c", "cash", 60}]

    assert %{
             cash_held_cents: 160,
             cash_refunded_cents: 30,
             cash_retained_cents: 20,
             cash_converted_to_credit_cents: 10,
             credit_liability_cents: 141
           } = Reservations.ledger(~D[2027-01-01])

    assert Repo.one(CreditEntitlement).amount_cents == 5

    assert {:ok, %{held_cents: 100, recorded_cents: 100}} =
             GroupStay.Reservations.Payments.statement("cash")

    assert [%{"charged_back_cents" => 5, "revision" => 8}] =
             Reservations.submit_batch([correction("charge_back_payment", "cb", "converted-pay")])

    assert Reservations.ledger(~D[2027-01-01]).credit_liability_cents == 136

    assert [%{"amount_cents" => 70, "revision" => 8}] =
             Reservations.submit_batch([
               Map.put(correction("reduce_cash_payment", "reduce", "cash"), "amount_cents", 70)
             ])

    assert {:ok, group} = Reservations.get_group("g")
    assert Enum.map(group.rooms, & &1.cash_paid_cents) == [60, 30, 0]

    assert [%{"charged_back_cents" => 20}] =
             Reservations.submit_batch([
               correction("charge_back_payment", "refund-cb", "refunded-pay")
             ])

    assert [%{"charged_back_cents" => 20}] =
             Reservations.submit_batch([
               correction("charge_back_payment", "retain-cb", "retained-pay")
             ])

    assert Reservations.ledger(~D[2027-01-01]).cash_refunded_cents == 10
    assert Reservations.ledger(~D[2027-01-01]).cash_retained_cents == 0
    assert Repo.query!("SELECT * FROM operations ORDER BY id LIMIT 6").rows == audit
  end

  defp correction(type, id, payment) do
    %{
      "type" => type,
      "operation_id" => id,
      "payment_operation_id" => payment,
      "occurred_on" => "2027-01-01",
      "expected_revision" => 7
    }
  end

  defp insert_group(id, status, cash, credit, refunded, retained, converted) do
    rooms = Jason.encode!(for id <- ~w(a b c), do: %{room_id: id, nightly_rate_cents: 500})

    Repo.query!(
      """
      INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, policy_version, status, revision, rooms, lodging_total_cents, deposit_due_cents,
        deposit_paid_cents, cash_paid_cents, credit_paid_cents, refunded_cents, retained_cents, cash_converted_to_credit_cents)
      VALUES (?, 'guest', 'hotel', '2026-01-01', '2027-06-01', '2027-06-02', 'flexible', 'flex-14', ?, 7, ?, 1500, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        id,
        status,
        rooms,
        if(status == "active", do: 300, else: 0),
        cash + credit,
        cash,
        credit,
        refunded,
        retained,
        converted
      ]
    )
  end

  defp insert_record(id, type, group, amount, on) do
    payload =
      Jason.encode!(%{
        operation_id: id,
        type: "retained-type-is-authoritative",
        group_id: group,
        amount_cents: amount,
        occurred_on: on
      })

    result =
      Jason.encode!(%{
        operation_id: id,
        status: "applied",
        group_id: group,
        amount_cents: amount,
        revision: 7
      })

    Repo.query!(
      "INSERT INTO operations (operation_id, type, payload, result) VALUES (?, ?, ?, ?)",
      [id, type, payload, result]
    )
  end
end
