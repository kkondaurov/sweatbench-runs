defmodule GroupStay.OperationsTransactionTest do
  use GroupStay.CommittedCase, async: false

  import Phoenix.ConnTest
  import Plug.Conn
  import GroupStay.PartnerFixtures

  alias GroupStay.{Operations, Repo, Reservations}
  alias GroupStay.Credits.{Allocation, Entitlement, Lot}
  alias GroupStay.Finance.{CashAllocation, CashEntry}
  alias GroupStay.Operations.Record
  alias GroupStay.Reservations.{Group, Room}

  @endpoint GroupStayWeb.Endpoint

  for table <- ["cash_entries", "operation_records"] do
    test "a fault writing #{table} rolls back only the current operation and aborts HTTP with 500" do
      booking = open_group()
      rejected = operation("cancel_group", %{"group_id" => "missing"})

      payment =
        operation("record_cash_payment", %{"operation_id" => "fail", "amount_cents" => 500})

      later = open_group(%{"group_id" => "later"})
      batch = [booking, rejected, payment, later]

      # The cash entry is written after the group balance; the audit record is
      # written after all domain effects. Either failure must undo every effect.
      Repo.query!("""
      CREATE TRIGGER fail_operation BEFORE INSERT ON #{unquote(table)}
      WHEN NEW.operation_id = 'fail'
      BEGIN SELECT RAISE(ABORT, 'injected storage fault'); END
      """)

      assert {500, _, _} = assert_error_sent(500, fn -> post_batch(batch) end)

      assert %{revision: 1, cash_paid_cents: 0, deposit_paid_cents: 0} =
               Repo.get!(Group, "group-81")

      assert Repo.all(CashEntry) == []
      assert Repo.aggregate(Record, :count) == 2
      assert Operations.get_result(booking["operation_id"])["status"] == "applied"
      assert Operations.get_result(rejected["operation_id"])["code"] == "group_not_found"
      assert Operations.get_result("fail") == nil
      assert Operations.get_result(later["operation_id"]) == nil
      assert Repo.get(Group, "later") == nil

      Repo.query!("DROP TRIGGER fail_operation")

      assert %{"results" => [opened, rejected_result, paid, last]} =
               batch |> post_batch() |> json_response(200)

      assert opened["revision"] == 1
      assert rejected_result["code"] == "group_not_found"
      assert paid["revision"] == 2
      assert last["status"] == "applied"
      assert Repo.aggregate(Record, :count) == 4
      assert [%CashEntry{amount_cents: 500}] = Repo.all(CashEntry)
      assert Operations.apply_batch(batch) == [opened, rejected_result, paid, last]
    end
  end

  test "failure to remember a credit cancellation rolls back its lot, cash, and group" do
    Operations.apply_batch([
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100})
    ])

    cancellation =
      operation("cancel_group", %{"operation_id" => "fail", "refund_method" => "hotel_credit"})

    before = snapshot()

    Repo.query!("""
    CREATE TRIGGER fail_operation BEFORE INSERT ON operation_records
    WHEN NEW.operation_id = 'fail'
    BEGIN SELECT RAISE(ABORT, 'injected audit fault'); END
    """)

    assert_error_sent(500, fn -> post_batch([cancellation]) end)
    assert snapshot() == before
    assert Operations.get_result("fail") == nil

    Repo.query!("DROP TRIGGER fail_operation")

    assert [%{"credit_issued_cents" => 110, "revision" => 3}] =
             Operations.apply_batch([cancellation])

    assert [%Lot{remaining_cents: 110}] = Repo.all(Lot)
  end

  for {table, event, condition} <- [
        {"groups", "UPDATE", "NEW.group_id = 'destination'"},
        {"operation_records", "INSERT", "NEW.operation_id = 'fail'"}
      ] do
    test "a transfer rolls back both groups and provenance when writing #{table} fails" do
      Operations.apply_batch([
        open_group(%{"group_id" => "issuer"}),
        operation("record_cash_payment", %{"group_id" => "issuer", "amount_cents" => 100}),
        operation("cancel_group", %{"group_id" => "issuer", "refund_method" => "hotel_credit"}),
        open_group(),
        operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 100}),
        operation("apply_hotel_credit", %{"amount_cents" => 110}),
        open_group(%{"group_id" => "destination"})
      ])

      transfer = transfer_deposit("group-81", "destination", 150, %{"operation_id" => "fail"})
      before = snapshot()

      Repo.query!("""
      CREATE TRIGGER fail_transfer BEFORE #{unquote(event)} ON #{unquote(table)}
      WHEN #{unquote(condition)}
      BEGIN SELECT RAISE(ABORT, 'injected transfer fault'); END
      """)

      assert_error_sent(500, fn -> post_batch([transfer]) end)
      assert snapshot() == before
      assert Operations.get_result("fail") == nil
      Repo.query!("DROP TRIGGER fail_transfer")

      assert [%{"source_revision" => 4, "destination_revision" => 2} = result] =
               Operations.apply_batch([transfer])

      after_success = snapshot()
      assert Operations.apply_batch([transfer]) == [result]
      assert snapshot() == after_success
    end
  end

  for type <- ["reduce_cash_payment", "charge_back_payment"] do
    test "#{type} rolls back every affected group if its audit write fails" do
      Operations.apply_batch([
        open_group(),
        operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 1000}),
        open_group(%{"group_id" => "destination"}),
        transfer_deposit("group-81", "destination", 500)
      ])

      correction =
        operation(unquote(type), %{
          "operation_id" => "fail",
          "payment_operation_id" => "payment",
          "amount_cents" => 600
        })
        |> Map.delete("group_id")

      before = snapshot()

      Repo.query!("""
      CREATE TRIGGER fail_correction BEFORE INSERT ON operation_records
      WHEN NEW.operation_id = 'fail'
      BEGIN SELECT RAISE(ABORT, 'injected correction fault'); END
      """)

      assert_error_sent(500, fn -> post_batch([correction]) end)
      assert snapshot() == before
      Repo.query!("DROP TRIGGER fail_correction")
      assert [%{"revision" => 4}] = Operations.apply_batch([correction])
      assert Reservations.get_group("destination").revision == 3
    end
  end

  test "replay and result lookup work without access to current group state" do
    operations = [
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100, "expected_revision" => 1}),
      operation("cancel_group", %{"expected_revision" => 1})
    ]

    results = Operations.apply_batch(operations)
    Repo.query!("ALTER TABLE groups RENAME TO unavailable_groups")

    assert Operations.apply_batch(operations) == results
    assert Enum.map(operations, &Operations.get_result(&1["operation_id"])) == results
  end

  test "records and their order survive replacing every database process", %{database: database} do
    operations = [
      open_group(),
      operation("record_cash_payment", %{"amount_cents" => 100}),
      operation("cancel_group", %{"expected_revision" => 1})
    ]

    results = Operations.apply_batch(operations)
    before = snapshot()
    greatest_id = Repo.aggregate(Record, :max, :id)

    stop_supervised!(Repo)

    repo =
      start_supervised!({Repo, name: nil, database: database, pool: DBConnection.ConnectionPool})

    Repo.put_dynamic_repo(repo)

    assert Operations.apply_batch(operations) == results
    assert Enum.map(operations, &Operations.get_result(&1["operation_id"])) == results
    assert snapshot() == before

    [result] =
      Operations.apply_batch([operation("record_cash_payment", %{"amount_cents" => 200})])

    assert result["revision"] == 3
    record = Repo.get_by!(Record, operation_id: result["operation_id"])
    assert record.id > greatest_id
    assert Reservations.get_group("group-81").cash_paid_cents == 300
  end

  test "upgrading the cancellation release preserves existing credit and creates an empty audit" do
    old_payment = operation("record_cash_payment", %{"amount_cents" => 100})

    Operations.apply_batch([
      open_group(),
      old_payment,
      operation("cancel_group", %{"refund_method" => "hotel_credit"}),
      open_group(%{"group_id" => "next"}),
      operation("apply_hotel_credit", %{"group_id" => "next", "amount_cents" => 50})
    ])

    # Return to the previous release's schema with populated groups, cash, lots,
    # and allocations, then run the new release's migration normally.
    before = domain_snapshot()

    assert [20_260_907_040_000, 20_260_907_030_000, 20_260_907_020_000] =
             Ecto.Migrator.run(Repo, :down, step: 3, log: false)

    assert [20_260_907_020_000, 20_260_907_030_000, 20_260_907_040_000] =
             Ecto.Migrator.run(Repo, :up, all: true, log: false)

    assert domain_snapshot() == before
    assert Repo.all(Record) == []
    assert Operations.get_result(old_payment["operation_id"]) == nil

    payment = Map.put(old_payment, "group_id", "next")
    assert [%{"status" => "applied", "revision" => 3}] = Operations.apply_batch([payment])
    assert Repo.aggregate(Record, :count) == 1
    assert Ecto.Migrator.run(Repo, :up, all: true, log: false) == []
  end

  for type <- ["cancel_rooms", "reduce_cash_payment", "charge_back_payment"],
      table <- ["cash_entries", "operation_records"] do
    test "#{type} rolls back allocations and entitlements when #{table} fails" do
      Operations.apply_batch([
        open_group(),
        operation("record_cash_payment", %{"operation_id" => "payment", "amount_cents" => 10_000})
      ])

      # A chargeback also touches a spent credit lot, outside its addressed group.
      if unquote(type) == "charge_back_payment" do
        Operations.apply_batch([
          operation("cancel_rooms", %{"room_ids" => ["room-b"], "refund_method" => "hotel_credit"}),
          open_group(%{"group_id" => "recipient"}),
          operation("apply_hotel_credit", %{"group_id" => "recipient", "amount_cents" => 9000})
        ])
      end

      correction =
        operation(unquote(type), %{
          "operation_id" => "fail",
          "payment_operation_id" => "payment",
          "amount_cents" => 500,
          "room_ids" => ["room-b"],
          "refund_method" => "hotel_credit"
        })

      before = snapshot()

      Repo.query!("""
      CREATE TRIGGER fail_operation BEFORE INSERT ON #{unquote(table)}
      WHEN NEW.operation_id = 'fail'
      BEGIN SELECT RAISE(ABORT, 'injected storage fault'); END
      """)

      assert_error_sent(500, fn -> post_batch([correction]) end)
      assert snapshot() == before
      assert Operations.get_result("fail") == nil
      Repo.query!("DROP TRIGGER fail_operation")
      assert [%{"status" => "applied"} = result] = Operations.apply_batch([correction])
      after_success = snapshot()
      assert Operations.apply_batch([correction]) == [result]
      assert snapshot() == after_success
    end
  end

  defp post_batch(operations) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp snapshot do
    Map.merge(
      domain_snapshot(),
      Map.new([Record, Room, CashAllocation, Entitlement], &{&1, Repo.all(&1)})
    )
  end

  defp domain_snapshot do
    for schema <- [Group, CashEntry, Lot, Allocation],
        into: %{},
        do: {schema, Repo.all(schema)}
  end
end
