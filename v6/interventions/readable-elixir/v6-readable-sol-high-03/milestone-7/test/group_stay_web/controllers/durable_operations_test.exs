defmodule GroupStayWeb.DurableOperationsTest do
  use GroupStayWeb.ConnCase

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, OperationProcessor, PartnerOperation}

  describe "durable idempotency" do
    test "an exact retry returns the original applied result without reading current state", %{
      conn: conn
    } do
      opening = open_group()
      payment = cash_payment("pay-1", 5_000, 1)

      assert %{"results" => [opened, paid]} = submit(conn, [opening, payment])
      assert opened["revision"] == 1
      assert paid["revision"] == 2

      assert %{"results" => [replayed]} = submit(conn, [opening])
      assert replayed == opened

      assert %{"data" => group} = fetch_group(conn)
      assert group["revision"] == 2
      assert group["cash_paid_cents"] == 5_000

      assert conn |> get(~p"/api/v1/operations/open-1") |> json_response(200) == %{
               "data" => opened
             }
    end

    test "replays a rejection after domain state changes", %{conn: conn} do
      payment = cash_payment("pay-before-open", 1_000)

      assert %{"results" => [original_rejection]} = submit(conn, [payment])
      assert original_rejection == rejected("pay-before-open", "group_not_found")

      submit(conn, [open_group()])

      assert %{"results" => [replayed]} = submit(conn, [payment])
      assert replayed == original_rejection

      assert %{"data" => group} = fetch_group(conn)
      assert group["cash_paid_cents"] == 0
      assert group["revision"] == 1
    end

    test "reusing an identifier for a different JSON payload does not replace its receipt", %{
      conn: conn
    } do
      opening = open_group()
      assert %{"results" => [original]} = submit(conn, [opening])

      conflicting = put_in(opening, ["rooms", Access.at(0), "nightly_rate_cents"], 20_000)

      assert submit(conn, [conflicting]) == %{
               "results" => [rejected("open-1", "operation_id_conflict")]
             }

      assert conn |> get(~p"/api/v1/operations/open-1") |> json_response(200) == %{
               "data" => original
             }

      assert Repo.aggregate(PartnerOperation, :count) == 1
    end

    test "a same-batch retry is replayed and later operations observe only one effect", %{
      conn: conn
    } do
      opening = open_group()
      payment = cash_payment("pay-once", 2_000, 1)
      following_payment = cash_payment("pay-after", 3_000, 2)

      assert %{"results" => [opened, first, replayed, following]} =
               submit(conn, [opening, payment, payment, following_payment])

      assert first == replayed
      assert opened["revision"] == 1
      assert first["revision"] == 2
      assert following["revision"] == 3

      assert %{"data" => group} = fetch_group(conn)
      assert group["cash_paid_cents"] == 5_000
    end

    test "concurrent retries have one effect and one durable receipt" do
      operation = open_group()

      results =
        1..8
        |> Enum.map(fn _index -> Task.async(fn -> OperationProcessor.process(operation) end) end)
        |> Task.await_many()

      assert Enum.uniq(results) == [
               %{
                 "operation_id" => "open-1",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "deposit_due_cents" => 19_500,
                 "revision" => 1
               }
             ]

      assert Repo.aggregate(Group, :count) == 1
      assert Repo.aggregate(PartnerOperation, :count) == 1
    end

    test "a stale-revision retry preserves the originally observed revision", %{conn: conn} do
      opening = open_group()
      first_payment = cash_payment("pay-1", 1_000, 1)
      stale_payment = cash_payment("stale-pay", 1_000, 1)
      later_payment = cash_payment("pay-2", 1_000, 2)

      assert %{"results" => [_opened, _paid, stale, _later]} =
               submit(conn, [opening, first_payment, stale_payment, later_payment])

      assert stale == %{
               "operation_id" => "stale-pay",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      assert %{"results" => [replayed]} = submit(conn, [stale_payment])
      assert replayed == stale

      corrected = %{stale_payment | "expected_revision" => 3}

      assert submit(conn, [corrected]) == %{
               "results" => [rejected("stale-pay", "operation_id_conflict")]
             }
    end
  end

  test "receipts retain complete submissions, operation types, and first-commit order", %{
    conn: conn
  } do
    opening = open_group()
    invalid = %{"operation_id" => "unknown-1", "type" => "unknown", "nested" => %{"b" => 2}}

    submit(conn, [opening, invalid, opening])

    receipts = Repo.all(from receipt in PartnerOperation, order_by: receipt.commit_order)
    assert Enum.map(receipts, & &1.operation_id) == ["open-1", "unknown-1"]
    assert Enum.map(receipts, & &1.operation_type) == ["open_group", "unknown"]
    assert Enum.map(receipts, & &1.submitted_payload) == [opening, invalid]

    assert Enum.map(receipts, & &1.commit_order) ==
             Enum.sort(Enum.map(receipts, & &1.commit_order))

    assert Enum.at(receipts, 1).result == rejected("unknown-1", "invalid_operation")
  end

  test "the operation read endpoint returns the documented not-found error", %{conn: conn} do
    assert conn |> get(~p"/api/v1/operations/missing") |> json_response(404) == %{
             "error" => %{"code" => "operation_not_found"}
           }
  end

  test "a receipt-write fault rolls back domain changes and is not remembered" do
    Repo.query!("""
    CREATE TRIGGER fail_partner_operation_receipt
    BEFORE INSERT ON partner_operations
    BEGIN
      SELECT RAISE(ABORT, 'forced receipt failure');
    END
    """)

    assert_raise Exqlite.Error, fn -> OperationProcessor.process(open_group()) end

    assert Repo.get(Group, "group-81") == nil
    assert Repo.aggregate(PartnerOperation, :count) == 0

    Repo.query!("DROP TRIGGER fail_partner_operation_receipt")
  end

  defp open_group do
    %{
      "operation_id" => "open-1",
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => "group-81",
      "guest_id" => "guest-22",
      "property_id" => "ams-canal",
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
      ]
    }
  end

  defp cash_payment(operation_id, amount_cents, expected_revision \\ nil) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => amount_cents
    }
    |> then(fn operation ->
      if expected_revision,
        do: Map.put(operation, "expected_revision", expected_revision),
        else: operation
    end)
  end

  defp submit(conn, operations) do
    conn
    |> post(~p"/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
  end

  defp fetch_group(conn) do
    conn
    |> get(~p"/api/v1/groups/group-81")
    |> json_response(200)
  end

  defp rejected(operation_id, code) do
    %{"operation_id" => operation_id, "status" => "rejected", "code" => code}
  end
end
