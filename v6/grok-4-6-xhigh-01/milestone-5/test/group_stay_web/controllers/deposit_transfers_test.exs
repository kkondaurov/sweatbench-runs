defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  describe "transfer_deposit" do
    test "moves held cash between active groups of the same guest", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(10_000),
          open_dest(),
          transfer_op(4000)
        ])

      assert [
               %{"status" => "applied", "revision" => 1},
               %{"status" => "applied", "revision" => 2},
               %{"status" => "applied", "revision" => 1},
               %{
                 "operation_id" => "op-xfer",
                 "status" => "applied",
                 "source_group_id" => "group-81",
                 "destination_group_id" => "group-92",
                 "amount_cents" => 4000,
                 "source_outstanding_deposit_cents" => 13_500,
                 "destination_outstanding_deposit_cents" => 15_500,
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")
      source = json_response(conn, 200)["data"]
      assert source["revision"] == 3
      assert source["cash_paid_cents"] == 6000
      assert source["credit_paid_cents"] == 0
      assert source["outstanding_deposit_cents"] == 13_500
      assert Enum.at(source["rooms"], 0)["cash_paid_cents"] == 6000
      assert Enum.at(source["rooms"], 1)["cash_paid_cents"] == 0

      conn = get(conn, "/api/v1/groups/group-92")
      dest = json_response(conn, 200)["data"]
      assert dest["revision"] == 2
      assert dest["cash_paid_cents"] == 4000
      assert dest["outstanding_deposit_cents"] == 15_500
      assert Enum.at(dest["rooms"], 0)["cash_paid_cents"] == 4000
      assert Enum.at(dest["rooms"], 1)["cash_paid_cents"] == 0

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_held_cents"] == 10_000
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["credit_liability_cents"] == 0
    end

    test "draws mixed funding in reverse allocation order and fills dest rooms in draw order", %{
      conn: conn
    } do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{"operation_id" => "open-src", "group_id" => "group-src"}),
          Map.merge(pay_op(5000), %{"group_id" => "group-src", "operation_id" => "pay-src"}),
          credit_op("apply-src", "group-src", 4000, "2026-11-02"),
          open_op(%{"operation_id" => "open-dst", "group_id" => "group-dst"}),
          %{
            "operation_id" => "xfer-mixed",
            "type" => "transfer_deposit",
            "source_group_id" => "group-src",
            "destination_group_id" => "group-dst",
            "amount_cents" => 6000
          }
        ])

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "xfer-mixed",
               "status" => "applied",
               "source_group_id" => "group-src",
               "destination_group_id" => "group-dst",
               "amount_cents" => 6000,
               "source_outstanding_deposit_cents" => 16_500,
               "destination_outstanding_deposit_cents" => 13_500,
               "source_revision" => 4,
               "destination_revision" => 2
             }

      conn = get(conn, "/api/v1/groups/group-src")
      source = json_response(conn, 200)["data"]
      assert source["cash_paid_cents"] == 3000
      assert source["credit_paid_cents"] == 0
      assert Enum.at(source["rooms"], 0)["cash_paid_cents"] == 3000
      assert Enum.at(source["rooms"], 0)["credit_paid_cents"] == 0

      conn = get(conn, "/api/v1/groups/group-dst")
      dest = json_response(conn, 200)["data"]
      assert dest["cash_paid_cents"] == 2000
      assert dest["credit_paid_cents"] == 4000
      assert Enum.at(dest["rooms"], 0)["credit_paid_cents"] == 4000
      assert Enum.at(dest["rooms"], 0)["cash_paid_cents"] == 2000
      assert Enum.at(dest["rooms"], 1)["cash_paid_cents"] == 0
      assert Enum.at(dest["rooms"], 1)["credit_paid_cents"] == 0

      conn = get(conn, "/api/v1/ledger?on=2026-11-02")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_held_cents"] == 5000
      assert ledger["cash_converted_to_credit_cents"] == 5000
      assert ledger["credit_liability_cents"] == 5500

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-11-02")
      assert json_response(conn, 200)["data"]["available_cents"] == 1500
    end

    test "fills multiple destination rooms while preserving draw order", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(12_000),
          open_dest(),
          transfer_op(10_000)
        ])

      conn = get(conn, "/api/v1/groups/group-92")
      dest = json_response(conn, 200)["data"]
      assert Enum.at(dest["rooms"], 0)["cash_paid_cents"] == 9000
      assert Enum.at(dest["rooms"], 1)["cash_paid_cents"] == 1000

      conn = get(conn, "/api/v1/groups/group-81")
      source = json_response(conn, 200)["data"]
      assert Enum.at(source["rooms"], 0)["cash_paid_cents"] == 2000
      assert Enum.at(source["rooms"], 1)["cash_paid_cents"] == 0
    end
  end

  describe "transfer_deposit rejections" do
    test "resolves source existence before destination existence", %{conn: conn} do
      conn =
        post_batch(conn, [
          %{
            "operation_id" => "missing-src",
            "type" => "transfer_deposit",
            "source_group_id" => "missing-a",
            "destination_group_id" => "missing-b",
            "amount_cents" => 100
          }
        ])

      assert [
               %{
                 "operation_id" => "missing-src",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "missing-a"
               }
             ] = json_response(conn, 200)["results"]
    end

    test "returns destination group_not_found after the source exists", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          %{
            "operation_id" => "missing-dst",
            "type" => "transfer_deposit",
            "source_group_id" => "group-81",
            "destination_group_id" => "missing-b",
            "amount_cents" => 100
          }
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "code" => "group_not_found",
                 "group_id" => "missing-b"
               }
             ] = json_response(conn, 200)["results"]
    end

    test "checks source revision before destination revision", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          open_dest(),
          Map.merge(pay_dest(500), %{"operation_id" => "pay-dst"}),
          %{
            "operation_id" => "stale-src",
            "type" => "transfer_deposit",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-92",
            "amount_cents" => 100,
            "expected_revision" => 1,
            "destination_expected_revision" => 1
          }
        ])

      assert [
               _,
               _,
               _,
               _,
               %{
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]
    end

    test "destination revision mismatch uses the destination group_id", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          open_dest(),
          Map.merge(pay_dest(500), %{"operation_id" => "pay-dst"}),
          %{
            "operation_id" => "stale-dst",
            "type" => "transfer_deposit",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-92",
            "amount_cents" => 100,
            "expected_revision" => 2,
            "destination_expected_revision" => 1
          }
        ])

      assert [
               _,
               _,
               _,
               _,
               %{
                 "code" => "stale_revision",
                 "group_id" => "group-92",
                 "expected_revision" => 1,
                 "actual_revision" => 2
               }
             ] = json_response(conn, 200)["results"]
    end

    test "rejects the same group or different guests as invalid_transfer", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          open_op(%{
            "operation_id" => "open-other",
            "group_id" => "group-99",
            "guest_id" => "guest-99"
          }),
          %{
            "operation_id" => "same",
            "type" => "transfer_deposit",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-81",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "other-guest",
            "type" => "transfer_deposit",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-99",
            "amount_cents" => 100
          }
        ])

      assert [
               _,
               _,
               _,
               %{"operation_id" => "same", "code" => "invalid_transfer"},
               %{"operation_id" => "other-guest", "code" => "invalid_transfer"}
             ] = json_response(conn, 200)["results"]
    end

    test "invalid_transfer wins over an inactive destination", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          open_op(%{
            "operation_id" => "open-other",
            "group_id" => "group-99",
            "guest_id" => "guest-99"
          }),
          cancel_op("cancel-other", "2026-10-04") |> Map.put("group_id", "group-99"),
          %{
            "operation_id" => "diff-inactive",
            "type" => "transfer_deposit",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-99",
            "amount_cents" => 100
          }
        ])

      assert List.last(json_response(conn, 200)["results"])["code"] == "invalid_transfer"
    end

    test "reports the source when both groups are inactive", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          open_dest(),
          cancel_op("cancel-src", "2026-10-04"),
          cancel_op("cancel-dst", "2026-10-04") |> Map.put("group_id", "group-92"),
          transfer_op(100)
        ])

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "op-xfer",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-81"
             }
    end

    test "reports group_not_active with the inactive group's id", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          open_dest(),
          cancel_op("cancel-src", "2026-10-04"),
          transfer_op(100),
          open_op(%{"operation_id" => "open-3", "group_id" => "group-83"}),
          Map.merge(pay_op(1000), %{"group_id" => "group-83", "operation_id" => "pay-3"}),
          cancel_op("cancel-dst", "2026-10-04") |> Map.put("group_id", "group-92"),
          %{
            "operation_id" => "xfer-inactive-dst",
            "type" => "transfer_deposit",
            "source_group_id" => "group-83",
            "destination_group_id" => "group-92",
            "amount_cents" => 100
          }
        ])

      results = json_response(conn, 200)["results"]
      assert Enum.at(results, 4)["code"] == "group_not_active"
      assert Enum.at(results, 4)["group_id"] == "group-81"
      assert Enum.at(results, 8)["code"] == "group_not_active"
      assert Enum.at(results, 8)["group_id"] == "group-92"
    end

    test "rejects a non-positive amount after the group checks", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          open_dest(),
          transfer_op(0),
          %{
            "operation_id" => "xfer-missing",
            "type" => "transfer_deposit",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-92"
          }
        ])

      assert [
               _,
               _,
               %{"operation_id" => "op-xfer", "code" => "invalid_amount"},
               %{"operation_id" => "xfer-missing", "code" => "invalid_operation"}
             ] = json_response(conn, 200)["results"]
    end

    test "rejects transfers that exceed held funding or destination outstanding", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          open_dest(),
          Map.merge(pay_dest(19_000), %{"operation_id" => "pay-dst"}),
          %{
            "operation_id" => "over-held",
            "type" => "transfer_deposit",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-92",
            "amount_cents" => 1001
          },
          %{
            "operation_id" => "over-out",
            "type" => "transfer_deposit",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-92",
            "amount_cents" => 501
          }
        ])

      assert [
               _,
               _,
               _,
               _,
               %{"operation_id" => "over-held", "code" => "transfer_exceeds_held_funding"},
               %{"operation_id" => "over-out", "code" => "transfer_exceeds_outstanding"}
             ] = json_response(conn, 200)["results"]
    end

    test "prefers transfer_exceeds_held_funding when both caps are exceeded", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          open_dest(),
          Map.merge(pay_dest(19_000), %{"operation_id" => "pay-dst"}),
          transfer_op(1500)
        ])

      assert List.last(json_response(conn, 200)["results"])["code"] ==
               "transfer_exceeds_held_funding"
    end
  end

  describe "payment statement after transfers" do
    test "adds held_by_group once cash from a payment has been transferred", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(10_000),
          open_dest(),
          transfer_op(4000)
        ])

      conn = get(conn, "/api/v1/payments/op-pay")

      assert json_response(conn, 200)["data"] == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 10_000,
               "held_cents" => 10_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => [
                 %{"group_id" => "group-81", "amount_cents" => 6000},
                 %{"group_id" => "group-92", "amount_cents" => 4000}
               ]
             }
    end

    test "omits groups with no held cash and keeps an empty list after none remains", %{
      conn: conn
    } do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(10_000),
          open_dest(),
          transfer_op(4000),
          %{
            "operation_id" => "reduce-all-held",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 10_000
          }
        ])

      conn = get(conn, "/api/v1/payments/op-pay")
      data = json_response(conn, 200)["data"]
      assert data["held_cents"] == 0
      assert data["held_by_group"] == []
      assert data["reduced_cents"] == 10_000
    end

    test "does not add held_by_group when a payment has never been transferred", %{conn: conn} do
      {:ok, conn} = open_and_return(conn, [open_op(), pay_op(5000)])

      conn = get(conn, "/api/v1/payments/op-pay")
      data = json_response(conn, 200)["data"]
      refute Map.has_key?(data, "held_by_group")
      assert data["held_cents"] == 5000
    end
  end

  describe "later settlement and corrections" do
    test "transferred cash settles under the destination cancellation policy", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          open_op(%{
            "operation_id" => "open-dst",
            "group_id" => "group-92",
            "arrival_on" => "2026-10-20",
            "departure_on" => "2026-10-23"
          }),
          transfer_op(5000),
          cancel_op("cancel-dst", "2026-11-01") |> Map.put("group_id", "group-92")
        ])

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "cancel-dst",
               "status" => "applied",
               "group_id" => "group-92",
               "refunded_cents" => 0,
               "retained_cents" => 5000,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_retained_cents"] == 5000
      assert ledger["cash_refunded_cents"] == 0
    end

    test "transferred cash converted on the destination receives the bonus there", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          open_dest(),
          transfer_op(5000),
          Map.merge(cancel_op("cancel-dst", "2026-11-01", "hotel_credit"), %{
            "group_id" => "group-92"
          })
        ])

      assert List.last(json_response(conn, 200)["results"])["credit_issued_cents"] == 5500

      conn = get(conn, "/api/v1/ledger?on=2026-11-01")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_converted_to_credit_cents"] == 5000
      assert ledger["credit_liability_cents"] == 5500
    end

    test "transferred hotel credit restores to its original lot without another bonus", %{
      conn: conn
    } do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{"operation_id" => "open-src", "group_id" => "group-src"}),
          credit_op("apply-src", "group-src", 4000, "2026-11-02"),
          open_op(%{"operation_id" => "open-dst", "group_id" => "group-dst"}),
          %{
            "operation_id" => "xfer-credit",
            "type" => "transfer_deposit",
            "source_group_id" => "group-src",
            "destination_group_id" => "group-dst",
            "amount_cents" => 4000
          },
          Map.merge(cancel_op("cancel-dst", "2026-11-03"), %{"group_id" => "group-dst"})
        ])

      assert List.last(json_response(conn, 200)["results"])["credit_issued_cents"] == 0
      assert List.last(json_response(conn, 200)["results"])["refunded_cents"] == 0

      conn = get(conn, "/api/v1/guests/guest-22/credit?on=2026-11-03")

      assert json_response(conn, 200)["data"] == %{
               "guest_id" => "guest-22",
               "available_cents" => 5500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 5500,
                   "expires_on" => "2027-11-01"
                 }
               ]
             }
    end

    test "reductions follow a payment across groups in reverse allocation order", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(12_000),
          open_dest(),
          transfer_op(4000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 2000
          }
        ])

      assert [
               _,
               _,
               _,
               %{"source_revision" => 3, "destination_revision" => 2},
               %{
                 "group_id" => "group-81",
                 "amount_cents" => 2000,
                 "outstanding_deposit_cents" => 11_500,
                 "revision" => 4
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-92")
      dest = json_response(conn, 200)["data"]
      assert dest["revision"] == 3
      assert dest["cash_paid_cents"] == 2000

      conn = get(conn, "/api/v1/groups/group-81")
      source = json_response(conn, 200)["data"]
      assert source["revision"] == 4
      assert source["cash_paid_cents"] == 8000

      conn = get(conn, "/api/v1/payments/op-pay")
      data = json_response(conn, 200)["data"]
      assert data["held_cents"] == 10_000
      assert data["reduced_cents"] == 2000

      assert data["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 8000},
               %{"group_id" => "group-92", "amount_cents" => 2000}
             ]
    end

    test "chargebacks follow transferred held cash and increment other groups", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(5000),
          open_dest(),
          transfer_op(5000),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert [
               _,
               _,
               _,
               _,
               %{
                 "group_id" => "group-81",
                 "charged_back_cents" => 5000,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 4
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-92")
      dest = json_response(conn, 200)["data"]
      assert dest["revision"] == 3
      assert dest["cash_paid_cents"] == 0
      assert dest["outstanding_deposit_cents"] == 19_500

      conn = get(conn, "/api/v1/groups/group-81")
      source = json_response(conn, 200)["data"]
      assert source["revision"] == 4
      assert source["cash_paid_cents"] == 0

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000
    end

    test "chargeback of dest-settled transferred cash increments the destination", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          open_dest(),
          transfer_op(5000),
          cancel_op("cancel-dst", "2026-11-01") |> Map.put("group_id", "group-92"),
          %{
            "operation_id" => "cb-1",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert List.last(json_response(conn, 200)["results"])["revision"] == 4

      conn = get(conn, "/api/v1/groups/group-92")
      dest = json_response(conn, 200)["data"]
      assert dest["status"] == "cancelled"
      assert dest["revision"] == 4

      conn = get(conn, "/api/v1/ledger")
      ledger = json_response(conn, 200)["data"]
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000
    end

    test "a credit-only transfer does not mark an unrelated cash payment", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          cancel_op("cancel-17", "2026-11-01", "hotel_credit"),
          open_op(%{"operation_id" => "open-src", "group_id" => "group-src"}),
          Map.merge(pay_op(2000), %{"group_id" => "group-src", "operation_id" => "pay-src"}),
          credit_op("apply-src", "group-src", 3000, "2026-11-02"),
          open_op(%{"operation_id" => "open-dst", "group_id" => "group-dst"}),
          %{
            "operation_id" => "xfer-credit",
            "type" => "transfer_deposit",
            "source_group_id" => "group-src",
            "destination_group_id" => "group-dst",
            "amount_cents" => 3000
          }
        ])

      conn = get(conn, "/api/v1/payments/pay-src")
      data = json_response(conn, 200)["data"]
      refute Map.has_key?(data, "held_by_group")
      assert data["held_cents"] == 2000
    end

    test "reducing after a full transfer increments the original group and reopens dest", %{
      conn: conn
    } do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(5000),
          open_dest(),
          transfer_op(5000),
          %{
            "operation_id" => "reduce-1",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 1000
          }
        ])

      assert List.last(json_response(conn, 200)["results"]) == %{
               "operation_id" => "reduce-1",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "amount_cents" => 1000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 4
             }

      conn = get(conn, "/api/v1/groups/group-92")
      dest = json_response(conn, 200)["data"]
      assert dest["revision"] == 3
      assert dest["cash_paid_cents"] == 4000
      assert dest["outstanding_deposit_cents"] == 15_500
    end

    test "does not rewrite the original payment result after a transfer", %{conn: conn} do
      {:ok, conn} =
        open_and_return(conn, [
          open_op(),
          pay_op(5000),
          open_dest(),
          transfer_op(5000)
        ])

      retry = post_batch(conn, [pay_op(5000)])

      assert json_response(retry, 200)["results"] == [
               %{
                 "operation_id" => "op-pay",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 5000,
                 "outstanding_deposit_cents" => 14_500,
                 "revision" => 2
               }
             ]

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["cash_paid_cents"] == 0
    end
  end

  describe "idempotency and same-batch visibility" do
    test "retries return the stored result without moving funding again", %{conn: conn} do
      first =
        post_batch(conn, [
          open_op(),
          pay_op(5000),
          open_dest(),
          transfer_op(2000)
        ])

      original = List.last(json_response(first, 200)["results"])

      retry = post_batch(conn, [transfer_op(2000)])
      assert List.last(json_response(retry, 200)["results"]) == original

      conn = get(conn, "/api/v1/groups/group-81")
      assert json_response(conn, 200)["data"]["cash_paid_cents"] == 3000
      assert json_response(conn, 200)["data"]["revision"] == 3

      conn = get(conn, "/api/v1/groups/group-92")
      assert json_response(conn, 200)["data"]["cash_paid_cents"] == 2000
      assert json_response(conn, 200)["data"]["revision"] == 2
    end

    test "later operations in the same batch observe the transfer", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(5000),
          open_dest(),
          transfer_op(2000),
          Map.merge(pay_dest(1000), %{"operation_id" => "pay-after", "expected_revision" => 2})
        ])

      assert [
               _,
               _,
               _,
               %{"destination_revision" => 2},
               %{"status" => "applied", "revision" => 3, "outstanding_deposit_cents" => 16_500}
             ] = json_response(conn, 200)["results"]
    end

    test "destination_expected_revision sees earlier same-batch changes", %{conn: conn} do
      conn =
        post_batch(conn, [
          open_op(),
          pay_op(1000),
          open_dest(),
          Map.merge(pay_dest(500), %{"operation_id" => "pay-dst"}),
          Map.merge(transfer_op(100), %{"destination_expected_revision" => 2})
        ])

      assert List.last(json_response(conn, 200)["results"])["status"] == "applied"
    end
  end

  defp open_and_return(conn, operations) do
    conn = post_batch(conn, operations)
    assert conn.status == 200
    {:ok, conn}
  end

  defp post_batch(conn, operations) do
    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  defp open_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-1001",
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
      },
      overrides
    )
  end

  defp open_dest do
    open_op(%{"operation_id" => "open-dst", "group_id" => "group-92"})
  end

  defp pay_op(amount_cents) do
    %{
      "operation_id" => "op-pay",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-81",
      "amount_cents" => amount_cents
    }
  end

  defp pay_dest(amount_cents) do
    %{
      "operation_id" => "pay-dst",
      "type" => "record_cash_payment",
      "occurred_on" => "2026-10-04",
      "group_id" => "group-92",
      "amount_cents" => amount_cents
    }
  end

  defp transfer_op(amount_cents) do
    %{
      "operation_id" => "op-xfer",
      "type" => "transfer_deposit",
      "source_group_id" => "group-81",
      "destination_group_id" => "group-92",
      "amount_cents" => amount_cents
    }
  end

  defp cancel_op(operation_id, occurred_on, refund_method \\ nil) do
    op = %{
      "operation_id" => operation_id,
      "type" => "cancel_group",
      "occurred_on" => occurred_on,
      "group_id" => "group-81"
    }

    if refund_method, do: Map.put(op, "refund_method", refund_method), else: op
  end

  defp credit_op(operation_id, group_id, amount_cents, occurred_on) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => occurred_on,
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end
end
