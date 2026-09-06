defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  defp post_batch(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(~p"/api/v1/partner-batches", Jason.encode!(payload))
  end

  defp submit(conn, operations) do
    conn
    |> post_batch(%{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp submit_one(conn, operation) do
    [result] = submit(conn, [operation])
    result
  end

  # Two flexible rooms, 3 nights: room-a due 9000, room-b due 10500, total 19500.
  defp open_operation(group_id, guest_id, property_id) do
    %{
      "operation_id" => unique_id("open"),
      "type" => "open_group",
      "occurred_on" => "2026-10-03",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => property_id,
      "arrival_on" => "2026-12-10",
      "departure_on" => "2026-12-13",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
        %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
      ]
    }
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp open_group!(conn, group_id, guest_id \\ "guest-22", property_id \\ "ams-canal") do
    result = submit_one(conn, open_operation(group_id, guest_id, property_id))
    assert result["status"] == "applied"
    result
  end

  defp pay!(conn, group_id, amount_cents, occurred_on \\ "2026-10-04") do
    result =
      submit_one(conn, %{
        "operation_id" => unique_id("pay"),
        "type" => "record_cash_payment",
        "occurred_on" => occurred_on,
        "group_id" => group_id,
        "amount_cents" => amount_cents
      })

    assert result["status"] == "applied"
    result
  end

  # Pays a fixed operation identifier so reductions and chargebacks can
  # address it; returns the payment operation id.
  defp pay_named!(conn, operation_id, group_id, amount_cents) do
    result =
      submit_one(conn, %{
        "operation_id" => operation_id,
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      })

    assert result["status"] == "applied"
    operation_id
  end

  defp transfer_operation(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => unique_id("transfer"),
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 4000
      },
      overrides
    )
  end

  defp transfer!(conn, overrides \\ %{}) do
    result = submit_one(conn, transfer_operation(overrides))
    assert result["status"] == "applied"
    result
  end

  defp get_group(conn, group_id) do
    conn |> get(~p"/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp room(data, room_id) do
    Enum.find(data["rooms"], &(&1["room_id"] == room_id))
  end

  defp get_payment(conn, payment_operation_id) do
    conn
    |> get(~p"/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  # group-81 (ams-canal) holding 10000 cash, group-92 (rhs-plaza) empty.
  defp setup_pair(conn) do
    open_group!(conn, "group-81")
    open_group!(conn, "group-92", "guest-22", "rhs-plaza")
    pay!(conn, "group-81", 10000)
  end

  # Same pair, but with a named payment for reductions and chargebacks.
  defp setup_named_pair(conn) do
    open_group!(conn, "group-81")
    open_group!(conn, "group-92", "guest-22", "rhs-plaza")
    pay_named!(conn, "pay-1", "group-81", 10000)
    "pay-1"
  end

  describe "transfer_deposit" do
    test "moves held funding and reports both groups' outstanding and revisions", %{conn: conn} do
      setup_pair(conn)

      operation = transfer_operation()

      assert submit_one(conn, operation) == %{
               "operation_id" => operation["operation_id"],
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-92",
               "amount_cents" => 4000,
               "source_outstanding_deposit_cents" => 13500,
               "destination_outstanding_deposit_cents" => 15500,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      source = get_group(conn, "group-81")
      assert source["cash_paid_cents"] == 6000
      assert source["outstanding_deposit_cents"] == 13500

      destination = get_group(conn, "group-92")
      assert destination["cash_paid_cents"] == 4000
      assert destination["outstanding_deposit_cents"] == 15500
    end

    test "keeps provenance so transferred cash settles under the destination policy", %{
      conn: conn
    } do
      setup_pair(conn)
      transfer!(conn)

      pay!(conn, "group-92", 15500)

      [result] =
        submit(conn, [
          %{
            "operation_id" => "cancel-1",
            "type" => "cancel_group",
            "occurred_on" => "2026-11-26",
            "group_id" => "group-92",
            "refund_method" => "cash"
          }
        ])

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 19500
    end

    test "a reduction follows the payment's allocations into the destination group", %{conn: conn} do
      pay1 = setup_named_pair(conn)
      transfer!(conn)

      assert submit_one(conn, %{
               "operation_id" => "reduce-1",
               "type" => "reduce_cash_payment",
               "occurred_on" => "2026-10-06",
               "payment_operation_id" => pay1,
               "amount_cents" => 4000
             })["status"] == "applied"

      # The reduction removed the transferred allocation, so the destination's
      # outstanding reopens and its revision advances too, while the original
      # payment group's revision still increments exactly once.
      destination = get_group(conn, "group-92")
      assert destination["cash_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 19500
      assert destination["revision"] == 3

      payment = get_payment(conn, pay1)
      assert payment["held_cents"] == 6000
      assert payment["reduced_cents"] == 4000
    end

    test "a chargeback follows the payment's allocations wherever they fund rooms", %{conn: conn} do
      pay1 = setup_named_pair(conn)
      transfer!(conn)

      assert submit_one(conn, %{
               "operation_id" => "chargeback-1",
               "type" => "charge_back_payment",
               "occurred_on" => "2026-10-06",
               "payment_operation_id" => pay1
             }) == %{
               "operation_id" => "chargeback-1",
               "status" => "applied",
               "payment_operation_id" => pay1,
               "group_id" => "group-81",
               "charged_back_cents" => 10000,
               "outstanding_deposit_cents" => 19500,
               "revision" => 4
             }

      destination = get_group(conn, "group-92")
      assert destination["outstanding_deposit_cents"] == 19500
      assert destination["revision"] == 3
    end

    test "moves hotel credit as well as cash, preserving the original lot", %{conn: conn} do
      # Issue a credit lot for guest-22 worth 6050 (110% of 5500).
      open_group!(conn, "group-81")
      pay!(conn, "group-81", 5500)

      assert submit_one(conn, %{
               "operation_id" => "cancel-1",
               "type" => "cancel_group",
               "occurred_on" => "2026-11-26",
               "group_id" => "group-81",
               "refund_method" => "hotel_credit"
             })["credit_issued_cents"] == 6050

      open_group!(conn, "group-81c", "guest-22")

      assert submit_one(conn, %{
               "operation_id" => "apply-1",
               "type" => "apply_hotel_credit",
               "occurred_on" => "2026-11-27",
               "group_id" => "group-81c",
               "amount_cents" => 6050
             })["status"] == "applied"

      open_group!(conn, "group-92", "guest-22", "rhs-plaza")

      transfer!(conn, %{
        "source_group_id" => "group-81c",
        "destination_group_id" => "group-92",
        "amount_cents" => 6050
      })

      assert get_group(conn, "group-92")["credit_paid_cents"] == 6050

      # Refundable settlement restores the transferred credit to its original lot.
      assert submit_one(conn, %{
               "operation_id" => "cancel-2",
               "type" => "cancel_group",
               "occurred_on" => "2026-11-26",
               "group_id" => "group-92",
               "refund_method" => "cash"
             })["status"] == "applied"

      credit =
        conn
        |> get(~p"/api/v1/guests/guest-22/credit?on=2026-11-27")
        |> json_response(200)
        |> Map.fetch!("data")

      assert credit["available_cents"] == 6050
    end

    test "rejects a transfer within one group or between different guests", %{conn: conn} do
      setup_pair(conn)

      assert %{"status" => "rejected", "code" => "invalid_transfer"} =
               submit_one(conn, transfer_operation(%{"destination_group_id" => "group-81"}))

      open_group!(conn, "group-55", "guest-99")

      assert %{"status" => "rejected", "code" => "invalid_transfer"} =
               submit_one(conn, transfer_operation(%{"destination_group_id" => "group-55"}))
    end

    test "rejects a non-positive amount, excess held funding, and excess outstanding", %{
      conn: conn
    } do
      setup_pair(conn)

      assert %{"status" => "rejected", "code" => "invalid_amount"} =
               submit_one(conn, transfer_operation(%{"amount_cents" => 0}))

      assert %{"status" => "rejected", "code" => "transfer_exceeds_held_funding"} =
               submit_one(conn, transfer_operation(%{"amount_cents" => 10001}))

      pay!(conn, "group-92", 16000)

      # Destination outstanding is now 3500.
      assert %{"status" => "rejected", "code" => "transfer_exceeds_outstanding"} =
               submit_one(conn, transfer_operation(%{"amount_cents" => 4000}))
    end

    test "resolves existence of the source and then the destination", %{conn: conn} do
      assert %{"status" => "rejected", "code" => "group_not_found", "group_id" => "group-81"} =
               submit_one(conn, transfer_operation())

      open_group!(conn, "group-81")

      assert %{"status" => "rejected", "code" => "group_not_found", "group_id" => "group-92"} =
               submit_one(conn, transfer_operation())
    end

    test "checks the source revision before the destination revision", %{conn: conn} do
      setup_pair(conn)

      operation =
        transfer_operation(%{
          "expected_revision" => 1,
          "destination_expected_revision" => 9
        })

      assert submit_one(conn, operation) ==
               %{
                 "operation_id" => operation["operation_id"],
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
    end

    test "a stale destination revision names the destination group", %{conn: conn} do
      setup_pair(conn)

      operation =
        transfer_operation(%{
          "expected_revision" => 2,
          "destination_expected_revision" => 9
        })

      assert submit_one(conn, operation) ==
               %{
                 "operation_id" => operation["operation_id"],
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-92",
                 "expected_revision" => 9,
                 "actual_revision" => 1
               }

      assert transfer!(conn, %{
               "expected_revision" => 2,
               "destination_expected_revision" => 1
             })["status"] == "applied"
    end

    test "rejects either group that is not active, with that group's identifier", %{conn: conn} do
      setup_pair(conn)

      submit_one(conn, %{
        "operation_id" => "cancel-1",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-92"
      })

      assert %{"status" => "rejected", "code" => "group_not_active", "group_id" => "group-92"} =
               submit_one(conn, transfer_operation())
    end

    test "an exact retry moves nothing twice and returns the stored result", %{conn: conn} do
      setup_pair(conn)
      operation = transfer_operation()
      first = submit_one(conn, operation)
      second = submit_one(conn, operation)

      assert second == first

      assert get_group(conn, "group-81")["cash_paid_cents"] == 6000
      assert get_group(conn, "group-92")["cash_paid_cents"] == 4000

      assert submit_one(conn, Map.put(operation, "amount_cents", 5000)) ==
               %{
                 "operation_id" => operation["operation_id"],
                 "status" => "rejected",
                 "code" => "operation_id_conflict"
               }
    end

    test "fills the destination rooms in original order, splitting a unit at room edges", %{
      conn: conn
    } do
      open_group!(conn, "group-81")
      open_group!(conn, "group-92", "guest-22", "rhs-plaza")
      pay!(conn, "group-81", 9500)

      # room-a of the destination is filled first with 9000; the 500 rest goes to room-b.
      transfer!(conn, %{"amount_cents" => 9500})

      source = get_group(conn, "group-81")
      assert room(source, "room-a")["cash_paid_cents"] == 0
      assert room(source, "room-b")["cash_paid_cents"] == 0

      destination = get_group(conn, "group-92")
      assert room(destination, "room-a")["cash_paid_cents"] == 9000
      assert room(destination, "room-b")["cash_paid_cents"] == 500
    end
  end

  describe "payment statement after transfer" do
    test "held_by_group lists each holding group ordered by group_id", %{conn: conn} do
      open_group!(conn, "group-81")
      open_group!(conn, "group-91", "guest-22", "rhs-plaza")
      open_group!(conn, "group-92", "guest-22", "rhs-plaza")
      pay1 = pay_named!(conn, "pay-1", "group-91", 10000)

      transfer!(conn, %{
        "source_group_id" => "group-91",
        "destination_group_id" => "group-81",
        "amount_cents" => 500
      })

      transfer!(conn, %{
        "source_group_id" => "group-91",
        "destination_group_id" => "group-92",
        "amount_cents" => 500
      })

      payment = get_payment(conn, pay1)
      assert payment["held_cents"] == 10000

      assert payment["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 500},
               %{"group_id" => "group-91", "amount_cents" => 9000},
               %{"group_id" => "group-92", "amount_cents" => 500}
             ]
    end

    test "a payment that never transferred keeps the earlier statement shape", %{conn: conn} do
      open_group!(conn, "group-81")
      pay1 = pay_named!(conn, "pay-1", "group-81", 5000)

      payment = get_payment(conn, pay1)
      refute Map.has_key?(payment, "held_by_group")
      assert payment["held_cents"] == 5000
    end
  end
end
