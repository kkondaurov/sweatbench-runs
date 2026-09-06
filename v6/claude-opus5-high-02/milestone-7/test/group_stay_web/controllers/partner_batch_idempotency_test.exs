defmodule GroupStayWeb.PartnerBatchIdempotencyTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Partner.Record
  alias GroupStay.Repo

  # A rate no integer column can hold: the operation faults while it is being applied instead of
  # being rejected by a domain rule.
  @unstorable_rate 100_000_000_000_000_000_000_000

  describe "retrying an applied operation" do
    setup do
      submit_one(open_group(%{"rooms" => [room("room-a", 10_000)]}))
      :ok
    end

    test "a retry returns the original result and the operation is applied once" do
      first = submit_one(record_cash_payment(%{"amount_cents" => 1_000}))
      assert first["revision"] == 2

      assert submit_one(record_cash_payment(%{"amount_cents" => 1_000})) == first

      {200, %{"data" => group}} = read_group("group-81")
      assert group["deposit_paid_cents"] == 1_000
      assert group["revision"] == 2
      assert read_ledger()["cash_held_cents"] == 1_000
    end

    test "a retry within the same batch is answered from the first attempt" do
      [first, retry] =
        submit([
          record_cash_payment(%{"amount_cents" => 1_000}),
          record_cash_payment(%{"amount_cents" => 1_000})
        ])

      assert retry == first

      {200, %{"data" => group}} = read_group("group-81")
      assert group["deposit_paid_cents"] == 1_000
      assert group["revision"] == 2
    end

    test "a retry does not consult the state the operation would have changed" do
      first = submit_one(record_cash_payment(%{"amount_cents" => 1_000}))
      submit_one(cancel_group(%{"occurred_on" => "2026-11-26"}))

      # A payment submitted now would be rejected, and the revision has moved on twice.
      assert submit_one(record_cash_payment(%{"amount_cents" => 1_000})) == first

      {200, %{"data" => group}} = read_group("group-81")
      assert group["status"] == "cancelled"
      assert group["revision"] == 3
      assert read_ledger()["cash_refunded_cents"] == 1_000
    end

    test "object key order is not part of an operation" do
      # The same group, submitted twice with its keys - nested ones included - in opposite orders.
      one =
        ~s({"operation_id":"op-second","type":"open_group","occurred_on":"2026-10-03",) <>
          ~s("group_id":"group-2","guest_id":"guest-22","property_id":"ams-canal",) <>
          ~s("arrival_on":"2026-12-10","departure_on":"2026-12-11","rate_plan":"flexible",) <>
          ~s("rooms":[{"room_id":"room-a","nightly_rate_cents":10000}]})

      two =
        ~s({"rooms":[{"nightly_rate_cents":10000,"room_id":"room-a"}],"rate_plan":"flexible",) <>
          ~s("departure_on":"2026-12-11","arrival_on":"2026-12-10","property_id":"ams-canal",) <>
          ~s("guest_id":"guest-22","group_id":"group-2","occurred_on":"2026-10-03",) <>
          ~s("type":"open_group","operation_id":"op-second"})

      assert [first] = submit_raw([one])
      assert first["status"] == "applied"

      assert submit_raw([two]) == [first]
      assert Repo.aggregate(from(r in Record, where: r.operation_id == "op-second"), :count) == 1
    end

    test "the order of an array is part of an operation" do
      rooms = [room("room-a", 10_000), room("room-b", 12_000)]
      operation = open_group(%{"operation_id" => "op-two", "group_id" => "group-2"})

      assert submit_one(Map.put(operation, "rooms", rooms))["status"] == "applied"

      assert submit_one(Map.put(operation, "rooms", Enum.reverse(rooms)))["code"] ==
               "operation_id_conflict"
    end
  end

  describe "retrying a rejected operation" do
    test "a retry receives the original rejection even once it would be applied" do
      rejected = submit_one(record_cash_payment(%{"amount_cents" => 1_000}))
      assert rejected["code"] == "group_not_found"

      submit_one(open_group(%{"rooms" => [room("room-a", 10_000)]}))

      assert submit_one(record_cash_payment(%{"amount_cents" => 1_000})) == rejected

      {200, %{"data" => group}} = read_group("group-81")
      assert group["deposit_paid_cents"] == 0
      assert group["revision"] == 1
    end

    test "a rejection leaves the domain untouched and is still remembered" do
      submit_one(open_group(%{"rooms" => [room("room-a", 10_000)]}))

      rejected = submit_one(record_cash_payment(%{"amount_cents" => 99_999}))
      assert rejected["code"] == "payment_exceeds_outstanding"

      {200, %{"data" => group}} = read_group("group-81")
      assert group["deposit_paid_cents"] == 0
      assert group["revision"] == 1

      assert read_operation("op-pay") == {200, %{"data" => rejected}}
    end

    test "an operation rejected before it could be parsed is remembered too" do
      rejected = submit_one(Map.put(open_group(), "type", "transfer_group"))
      assert rejected["code"] == "invalid_operation"

      assert submit_one(Map.put(open_group(), "type", "transfer_group")) == rejected

      # Correcting the type spends an identifier that already stands for something else.
      assert submit_one(open_group())["code"] == "operation_id_conflict"
      assert {404, _} = read_group("group-81")
    end

    test "an operation that cannot name itself is neither remembered nor recognised" do
      anonymous = Map.delete(record_cash_payment(), "operation_id")

      assert submit_one(anonymous) == %{
               "operation_id" => nil,
               "status" => "rejected",
               "code" => "invalid_operation"
             }

      assert submit_one(anonymous)["code"] == "invalid_operation"
      assert Repo.aggregate(Record, :count) == 0
    end
  end

  describe "reusing an identifier for a different operation" do
    setup do
      submit_one(open_group(%{"rooms" => [room("room-a", 10_000)]}))
      :ok
    end

    test "the reuse is rejected and the original record stands" do
      applied = submit_one(record_cash_payment(%{"amount_cents" => 1_000}))

      assert submit_one(record_cash_payment(%{"amount_cents" => 2_000})) == %{
               "operation_id" => "op-pay",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      assert read_operation("op-pay") == {200, %{"data" => applied}}

      {200, %{"data" => group}} = read_group("group-81")
      assert group["deposit_paid_cents"] == 1_000
      assert group["revision"] == 2
    end

    test "the conflict does not stop the rest of the batch" do
      submit_one(record_cash_payment(%{"amount_cents" => 1_000}))

      [conflict, applied] =
        submit([
          record_cash_payment(%{"amount_cents" => 2_000}),
          record_cash_payment(%{"operation_id" => "op-pay-2", "amount_cents" => 2_000})
        ])

      assert conflict["code"] == "operation_id_conflict"
      assert applied["status"] == "applied"

      {200, %{"data" => group}} = read_group("group-81")
      assert group["deposit_paid_cents"] == 3_000
    end
  end

  describe "revisions in remembered results" do
    setup do
      submit_one(open_group(%{"rooms" => [room("room-a", 10_000)]}))
      :ok
    end

    test "a retry reports the revision the first attempt produced" do
      first =
        submit_one(record_cash_payment(%{"amount_cents" => 1_000, "expected_revision" => 1}))

      assert first["revision"] == 2

      submit_one(reschedule_group())

      assert submit_one(record_cash_payment(%{"amount_cents" => 1_000, "expected_revision" => 1})) ==
               first

      {200, %{"data" => group}} = read_group("group-81")
      assert group["revision"] == 3
      assert group["deposit_paid_cents"] == 1_000
    end

    test "a retry reports the stale revision the first attempt observed" do
      submit_one(record_cash_payment(%{"operation_id" => "op-first", "amount_cents" => 1_000}))

      stale = submit_one(record_cash_payment(%{"amount_cents" => 500, "expected_revision" => 1}))
      assert stale["code"] == "stale_revision"
      assert stale["actual_revision"] == 2

      submit_one(reschedule_group())

      assert submit_one(record_cash_payment(%{"amount_cents" => 500, "expected_revision" => 1})) ==
               stale
    end

    test "correcting the expected revision is a different operation" do
      submit_one(record_cash_payment(%{"operation_id" => "op-first", "amount_cents" => 1_000}))

      assert submit_one(record_cash_payment(%{"amount_cents" => 500, "expected_revision" => 1}))[
               "code"
             ] == "stale_revision"

      assert submit_one(record_cash_payment(%{"amount_cents" => 500, "expected_revision" => 2}))[
               "code"
             ] == "operation_id_conflict"

      {200, %{"data" => group}} = read_group("group-81")
      assert group["deposit_paid_cents"] == 1_000
      assert group["revision"] == 2
    end
  end

  describe "unexpected faults" do
    test "a fault aborts the batch and is never remembered" do
      assert_error_sent(500, fn ->
        submit_batch(%{
          "operations" => [
            open_group(%{"operation_id" => "op-before", "group_id" => "group-before"}),
            open_group(%{
              "operation_id" => "op-fault",
              "group_id" => "group-fault",
              "rooms" => [room("room-a", @unstorable_rate)]
            }),
            open_group(%{"operation_id" => "op-after", "group_id" => "group-after"})
          ]
        })
      end)

      # The operation that faulted rolled back, and the batch stopped there.
      assert {404, _} = read_group("group-fault")
      assert {404, _} = read_group("group-after")
      assert {404, %{"error" => %{"code" => "operation_not_found"}}} = read_operation("op-fault")
      assert {404, _} = read_operation("op-after")

      # Operations committed before the fault stand and are remembered.
      assert {200, _} = read_group("group-before")
      assert {200, _} = read_operation("op-before")
    end

    test "the gateway can retry the batch once the fault is gone" do
      assert_error_sent(500, fn ->
        submit_batch(%{
          "operations" => [
            open_group(%{"operation_id" => "op-before", "group_id" => "group-before"}),
            open_group(%{
              "operation_id" => "op-fault",
              "group_id" => "group-fault",
              "rooms" => [room("room-a", @unstorable_rate)]
            })
          ]
        })
      end)

      [replayed, applied] =
        submit([
          open_group(%{"operation_id" => "op-before", "group_id" => "group-before"}),
          open_group(%{
            "operation_id" => "op-fault",
            "group_id" => "group-fault",
            "rooms" => [room("room-a", 10_000)]
          })
        ])

      assert replayed["status"] == "applied"
      assert applied["status"] == "applied"

      assert Repo.aggregate(from(r in Record, where: r.operation_id == "op-before"), :count) == 1
    end
  end

  describe "the durable record" do
    test "retains the type and the complete submission of an applied operation" do
      operation = open_group(%{"rooms" => [room("room-a", 10_000)]})
      result = submit_one(operation)

      record = Repo.get_by!(Record, operation_id: "op-open")
      assert record.type == "open_group"
      assert Jason.decode!(record.payload) == operation
      assert Jason.decode!(record.result) == result
    end

    test "retains the submission of a rejected operation, whatever type it named" do
      operation = Map.put(open_group(), "type", "transfer_group")
      result = submit_one(operation)

      record = Repo.get_by!(Record, operation_id: "op-open")
      assert record.type == "transfer_group"
      assert Jason.decode!(record.payload) == operation
      assert Jason.decode!(record.result) == result
    end

    test "preserves the order records were first committed in" do
      submit([
        open_group(%{"operation_id" => "op-1", "group_id" => "group-1"}),
        record_cash_payment(%{"operation_id" => "op-2", "group_id" => "group-404"}),
        open_group(%{"operation_id" => "op-3", "group_id" => "group-3"})
      ])

      submit_one(open_group(%{"operation_id" => "op-4", "group_id" => "group-4"}))
      # A retry is answered from the record it already has and adds nothing to the audit trail.
      submit_one(open_group(%{"operation_id" => "op-4", "group_id" => "group-4"}))

      assert Repo.all(from r in Record, order_by: [asc: r.id], select: r.operation_id) ==
               ["op-1", "op-2", "op-3", "op-4"]
    end

    test "the database itself refuses a second record for an identifier" do
      submit_one(open_group())

      duplicate =
        %Record{operation_id: "op-open", type: "open_group", payload: "{}", result: "{}"}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.unique_constraint(:operation_id)

      assert {:error, changeset} = Repo.insert(duplicate)
      assert GroupStay.DataCase.errors_on(changeset).operation_id == ["has already been taken"]
    end
  end
end
