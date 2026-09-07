defmodule GroupStay.RoomAccountingMigrationTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias GroupStay.{Repo, Reservations, Payments, HotelCredit}
  alias GroupStay.Reservations.Group
  alias GroupStay.Operations.Record

  setup do
    directory = Path.expand("tmp/room-upgrade-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    options = [
      name: nil,
      database: Path.join(directory, "upgrade.db"),
      pool: DBConnection.ConnectionPool,
      pool_size: 1
    ]

    repo = start_supervised!({Repo, options})
    previous = Repo.put_dynamic_repo(repo)

    Ecto.Migrator.run(Repo, GroupStay.TestDatabase.migrations(), :up,
      to: 20_260_907_200_000,
      log: false
    )

    on_exit(fn ->
      Repo.put_dynamic_repo(previous)
      GroupStay.TestDatabase.remove!(directory)
    end)

    %{repo: repo, options: options}
  end

  defp group(id, cash, credit, status \\ "active", disposition \\ "refunded_cents") do
    settled = if status == "cancelled", do: cash, else: 0
    held = if status == "active", do: cash + credit, else: 0
    due = if status == "active", do: 800, else: 0
    rooms = for id <- ~w(a b c d), do: %{"room_id" => id, "nightly_rate_cents" => 1000}

    Repo.query!(
      """
      INSERT INTO groups (group_id, guest_id, property_id, booked_on, arrival_on, departure_on,
        rate_plan, policy_version, status, revision, rooms, lodging_total_cents, deposit_due_cents,
        deposit_paid_cents, credit_paid_cents, #{disposition})
      VALUES (?, 'guest', 'hotel', '2026-01-01', '2028-12-01', '2028-12-02', 'flexible', 'flex-14', ?, 7, ?, 4000, ?, ?, ?, ?)
      """,
      [id, status, Jason.encode!(rooms), due, held, credit, settled]
    )
  end

  defp record(id, type, group, amount, on \\ "2026-10-01", status \\ "applied") do
    Repo.insert!(%Record{
      operation_id: id,
      type: type,
      submission: %{
        "operation_id" => id,
        "type" => type,
        "group_id" => group,
        "amount_cents" => amount,
        "occurred_on" => on
      },
      result: %{
        "operation_id" => id,
        "status" => status,
        "group_id" => group,
        "amount_cents" => amount,
        "revision" => 7
      }
    })
  end

  defp lot(source, remaining) do
    Repo.query!(
      "INSERT INTO credit_lots (guest_id, source_operation_id, remaining_cents, expires_on) VALUES ('guest', ?, ?, '2027-10-01')",
      [source, remaining]
    )

    %{rows: [[id]]} =
      Repo.query!("SELECT id FROM credit_lots WHERE source_operation_id = ?", [source])

    id
  end

  defp allocate(group, lot_id, amount) do
    Repo.query!(
      "INSERT INTO credit_allocations (group_id, credit_lot_id, amount_cents) VALUES (?, ?, ?)",
      [group, lot_id, amount]
    )
  end

  defp apply!(type, attrs) do
    [result] =
      Reservations.submit([
        Map.merge(
          %{
            "operation_id" => "new-#{System.unique_integer([:positive])}",
            "type" => type,
            "occurred_on" => "2026-10-01"
          },
          attrs
        )
      ])

    assert result["status"] == "applied", inspect(result)
    result
  end

  test "mixed legacy funding precedes typed durable funding in commit order and survives restart",
       %{options: options} do
    group("mixed", 400, 250)
    first_lot = lot("z-original", 30)
    second_lot = lot("a-later", 20)
    allocate("mixed", first_lot, 100)
    allocate("mixed", second_lot, 150)
    # Legacy = 150 cash and 100 credit. The result shapes deliberately match;
    # only the retained type can distinguish the following funding operations.
    record("credit", "apply_hotel_credit", "mixed", 150, "2026-10-03")
    record("cash-z", "record_cash_payment", "mixed", 100, "2026-10-02")
    record("cash-a", "record_cash_payment", "mixed", 150, "2026-10-01")
    record("rejected", "record_cash_payment", "mixed", 500, "2026-10-01", "rejected")
    original_records = Repo.all(from r in Record, order_by: r.id)
    Ecto.Migrator.run(Repo, GroupStay.TestDatabase.migrations(), :up, all: true, log: false)
    group = Repo.get!(Group, "mixed")
    assert group.revision == 7
    assert group.deposit_paid_cents == 650
    assert group.credit_paid_cents == 250

    assert Enum.map(group.rooms, &{&1["cash_paid_cents"], &1["credit_paid_cents"]}) == [
             {150, 50},
             {0, 200},
             {200, 0},
             {50, 0}
           ]

    assert Reservations.ledger(~D[2026-10-01]).credit_liability_cents == 300
    assert Reservations.ledger(~D[2026-10-01]).cash_held_cents == 400
    assert Repo.all(from r in Record, order_by: r.id) == original_records
    {:ok, statement} = Payments.statement("cash-a")
    assert statement.held_cents == 150
    assert Payments.statement("legacy") == {:error, "operation_not_found"}

    apply!("reduce_cash_payment", %{
      "payment_operation_id" => "cash-a",
      "amount_cents" => 70,
      "expected_revision" => 7
    })

    assert Enum.map(Repo.get!(Group, "mixed").rooms, & &1["cash_paid_cents"]) == [150, 0, 180, 0]
    apply!("cancel_rooms", %{"group_id" => "mixed", "room_ids" => ["a"]})
    assert HotelCredit.balance("guest", ~D[2026-10-01]).available_cents == 100
    assert Reservations.ledger(~D[2026-10-01]).cash_refunded_cents == 150

    before =
      {Repo.get!(Group, "mixed"), Payments.statement("cash-a"),
       Reservations.ledger(~D[2026-10-01])}

    stop_supervised!(Repo)
    restarted = start_supervised!({Repo, options})
    Repo.put_dynamic_repo(restarted)

    assert {Repo.get!(Group, "mixed"), Payments.statement("cash-a"),
            Reservations.ledger(~D[2026-10-01])} == before
  end

  test "settled payments retain their disposition and converted entitlement after upgrade" do
    for {id, disposition} <- [
          {"refund", "refunded_cents"},
          {"retain", "retained_cents"},
          {"convert", "cash_converted_to_credit_cents"}
        ] do
      group(id, 10, 0, "cancelled", disposition)
      record(id <> "-pay", "record_cash_payment", id, 5)
      record(id <> "-cancel", "cancel_group", id, 0)
    end

    lot("convert-cancel", 11)
    Ecto.Migrator.run(Repo, GroupStay.TestDatabase.migrations(), :up, all: true, log: false)

    for {id, disposition} <- [
          {"refund", :refunded_cents},
          {"retain", :retained_cents},
          {"convert", :converted_to_credit_cents}
        ] do
      {:ok, statement} = Payments.statement(id <> "-pay")
      assert statement[disposition] == 5
      assert statement.recorded_cents == 5

      assert apply!("charge_back_payment", %{
               "payment_operation_id" => id <> "-pay",
               "expected_revision" => 7
             })["charged_back_cents"] == 5

      assert Repo.get!(Group, id).revision == 8
    end

    # The senior legacy five cents owns six cents of entitlement; the recorded
    # junior payment owns the other five, independently of the lot's fungible use.
    assert HotelCredit.balance("guest", ~D[2026-10-01]).available_cents == 6
    totals = Reservations.ledger(~D[2026-10-01])
    assert totals.cash_refunded_cents == 5
    assert totals.cash_retained_cents == 5
    assert totals.cash_converted_to_credit_cents == 5
    assert totals.cash_charged_back_cents == 15
  end
end
