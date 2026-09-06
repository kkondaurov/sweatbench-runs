defmodule GroupStayWeb.Acceptance.HotelCreditTest do
  use GroupStayWeb.ConnCase

  @guest "guest-22"

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_op(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => @guest,
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
      },
      overrides
    )
  end

  defp pay_op(group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "pay-#{group_id}",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp cancel_op(group_id, occurred_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "cancel-#{group_id}",
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      overrides
    )
  end

  defp apply_credit_op(group_id, amount_cents, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "credit-#{group_id}",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-11-02",
        "group_id" => group_id,
        "amount_cents" => amount_cents
      },
      overrides
    )
  end

  defp group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp guest_credit(conn, guest_id \\ @guest, params \\ %{}) do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit", params)
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp ledger(conn, params \\ %{}) do
    conn
    |> get("/api/v1/ledger", params)
    |> json_response(200)
    |> Map.fetch!("data")
  end

  # Cancels group-a refundably with hotel credit, issuing a 5500 cent lot
  # (5000 cash plus the 10% bonus) that expires on 2027-11-02.
  defp issue_5500_lot(conn) do
    submit(conn, [open_op("group-a"), pay_op("group-a", 5000)])

    assert [
             %{"status" => "applied", "credit_issued_cents" => 5500}
           ] =
             submit(conn, [
               cancel_op("group-a", "2026-11-01", %{"refund_method" => "hotel_credit"})
             ])
  end

  describe "issuing credit on cancellation" do
    test "a refundable cancellation with hotel credit converts cash into a 110% lot" do
      submit(build_conn(), [
        open_op("group-z", %{
          "occurred_on" => "2099-01-01",
          "arrival_on" => "2099-06-01",
          "departure_on" => "2099-06-04"
        }),
        pay_op("group-z", 5000, %{"occurred_on" => "2099-01-02"})
      ])

      assert [
               %{
                 "operation_id" => "cancel-group-z",
                 "status" => "applied",
                 "group_id" => "group-z",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 5500,
                 "revision" => 3
               }
             ] =
               submit(build_conn(), [
                 cancel_op("group-z", "2099-02-01", %{"refund_method" => "hotel_credit"})
               ])

      assert guest_credit(build_conn()) == %{
               "guest_id" => @guest,
               "available_cents" => 5500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-group-z",
                   "remaining_cents" => 5500,
                   "expires_on" => "2100-02-02"
                 }
               ]
             }

      assert ledger(build_conn()) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             }
    end

    test "the 10% bonus rounds half cents upward" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 1005)])

      assert [%{"status" => "applied", "credit_issued_cents" => 1106}] =
               submit(build_conn(), [
                 cancel_op("group-a", "2026-11-01", %{"refund_method" => "hotel_credit"})
               ])
    end

    test "the 10% bonus rounds down below half cents" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 1004)])

      assert [%{"status" => "applied", "credit_issued_cents" => 1104}] =
               submit(build_conn(), [
                 cancel_op("group-a", "2026-11-01", %{"refund_method" => "hotel_credit"})
               ])
    end

    test "omitting refund_method still refunds cash" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 5000)])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 5000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] = submit(build_conn(), [cancel_op("group-a", "2026-11-01")])

      assert guest_credit(build_conn(), @guest, %{"on" => "2026-11-01"}) == %{
               "guest_id" => @guest,
               "available_cents" => 0,
               "lots" => []
             }

      assert ledger(build_conn()) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 5000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "an explicit cash refund method behaves like the default" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 5000)])

      assert [%{"status" => "applied", "refunded_cents" => 5000, "credit_issued_cents" => 0}] =
               submit(build_conn(), [
                 cancel_op("group-a", "2026-11-01", %{"refund_method" => "cash"})
               ])
    end

    test "hotel credit without paid cash issues no lot" do
      submit(build_conn(), [open_op("group-a")])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] =
               submit(build_conn(), [
                 cancel_op("group-a", "2026-11-01", %{"refund_method" => "hotel_credit"})
               ])

      assert ledger(build_conn())["cash_converted_to_credit_cents"] == 0
      assert guest_credit(build_conn(), @guest, %{"on" => "2026-11-01"})["lots"] == []
    end

    test "hotel credit is not available for a non-refundable cancellation" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 5000)])

      assert [
               %{
                 "operation_id" => "cancel-group-a",
                 "status" => "rejected",
                 "code" => "refund_method_not_available"
               }
             ] =
               submit(build_conn(), [
                 cancel_op("group-a", "2026-12-05", %{"refund_method" => "hotel_credit"})
               ])

      group = group(build_conn(), "group-a")
      assert group["status"] == "active"
      assert group["revision"] == 2

      assert guest_credit(build_conn(), @guest, %{"on" => "2026-12-05"})["lots"] == []

      assert ledger(build_conn()) == %{
               "cash_held_cents" => 5000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             }
    end

    test "hotel credit is not available for advance-purchase cancellations" do
      submit(build_conn(), [
        open_op("group-a", %{"rate_plan" => "advance_purchase"}),
        pay_op("group-a", 5000)
      ])

      assert [%{"status" => "rejected", "code" => "refund_method_not_available"}] =
               submit(build_conn(), [
                 cancel_op("group-a", "2026-10-04", %{"refund_method" => "hotel_credit"})
               ])

      assert group(build_conn(), "group-a")["status"] == "active"
    end

    test "an unknown refund method is an invalid operation" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 5000)])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               submit(build_conn(), [
                 cancel_op("group-a", "2026-11-01", %{"refund_method" => "voucher"})
               ])

      assert group(build_conn(), "group-a")["status"] == "active"
    end

    test "hotel credit requires the cancellation's operation identifier" do
      submit(build_conn(), [open_op("group-a"), pay_op("group-a", 5000)])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               submit(build_conn(), [
                 cancel_op("group-a", "2026-11-01", %{
                   "refund_method" => "hotel_credit",
                   "operation_id" => nil
                 })
               ])

      assert group(build_conn(), "group-a")["status"] == "active"
    end
  end

  describe "apply_hotel_credit" do
    test "redeems credit into the outstanding deposit" do
      issue_5500_lot(build_conn())
      submit(build_conn(), [open_op("group-b")])

      assert [
               %{
                 "operation_id" => "credit-group-b",
                 "status" => "applied",
                 "group_id" => "group-b",
                 "amount_cents" => 2000,
                 "outstanding_deposit_cents" => 4000,
                 "revision" => 2
               }
             ] = submit(build_conn(), [apply_credit_op("group-b", 2000)])

      group = group(build_conn(), "group-b")
      assert group["deposit_paid_cents"] == 2000
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 2000
      assert group["outstanding_deposit_cents"] == 4000

      assert guest_credit(build_conn(), @guest, %{"on" => "2026-11-02"}) == %{
               "guest_id" => @guest,
               "available_cents" => 3500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-group-a",
                   "remaining_cents" => 3500,
                   "expires_on" => "2027-11-02"
                 }
               ]
             }

      # Applying credit redeems it into the deposit: the liability is
      # unchanged and no cash is held.
      assert ledger(build_conn(), %{"on" => "2026-11-02"}) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             }
    end

    test "consumes lots by earliest expiry" do
      submit(build_conn(), [
        open_op("group-a"),
        pay_op("group-a", 1000),
        open_op("group-b"),
        pay_op("group-b", 2000)
      ])

      submit(build_conn(), [
        cancel_op("group-a", "2026-11-01", %{"refund_method" => "hotel_credit"}),
        cancel_op("group-b", "2026-11-05", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [open_op("group-c")])
      assert [%{"status" => "applied"}] = submit(build_conn(), [apply_credit_op("group-c", 1500)])

      assert guest_credit(build_conn(), @guest, %{"on" => "2026-11-06"}) == %{
               "guest_id" => @guest,
               "available_cents" => 1800,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-group-b",
                   "remaining_cents" => 1800,
                   "expires_on" => "2027-11-06"
                 }
               ]
             }
    end

    test "consumes equal expiries by source operation order" do
      submit(build_conn(), [
        open_op("group-a"),
        pay_op("group-a", 1000),
        open_op("group-b"),
        pay_op("group-b", 1000)
      ])

      submit(build_conn(), [
        cancel_op("group-b", "2026-11-01", %{"refund_method" => "hotel_credit"}),
        cancel_op("group-a", "2026-11-01", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [open_op("group-c")])
      assert [%{"status" => "applied"}] = submit(build_conn(), [apply_credit_op("group-c", 1100)])

      assert guest_credit(build_conn(), @guest, %{"on" => "2026-11-02"}) == %{
               "guest_id" => @guest,
               "available_cents" => 1100,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-group-b",
                   "remaining_cents" => 1100,
                   "expires_on" => "2027-11-02"
                 }
               ]
             }
    end

    test "rejects amounts the guest cannot cover" do
      issue_5500_lot(build_conn())
      submit(build_conn(), [open_op("group-b")])

      assert [%{"status" => "rejected", "code" => "insufficient_credit"}] =
               submit(build_conn(), [apply_credit_op("group-b", 5501)])

      assert group(build_conn(), "group-b")["revision"] == 1
    end

    test "rejects a guest without credit" do
      submit(build_conn(), [open_op("group-b")])

      assert [%{"status" => "rejected", "code" => "insufficient_credit"}] =
               submit(build_conn(), [apply_credit_op("group-b", 100)])
    end

    test "expired credit cannot be applied" do
      issue_5500_lot(build_conn())
      submit(build_conn(), [open_op("group-b")])

      assert [%{"status" => "rejected", "code" => "insufficient_credit"}] =
               submit(build_conn(), [
                 apply_credit_op("group-b", 100, %{"occurred_on" => "2027-11-02"})
               ])

      assert group(build_conn(), "group-b")["revision"] == 1
    end

    test "rejects credit exceeding the outstanding deposit" do
      issue_5500_lot(build_conn())
      submit(build_conn(), [open_op("group-b"), pay_op("group-b", 5000)])

      assert [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}] =
               submit(build_conn(), [apply_credit_op("group-b", 2000)])

      assert group(build_conn(), "group-b")["revision"] == 2
    end

    test "rejects amounts that are not usable as a payment" do
      issue_5500_lot(build_conn())
      submit(build_conn(), [open_op("group-b")])

      [0, -500, "2000", 50.5, nil]
      |> Enum.with_index()
      |> Enum.each(fn {amount, index} ->
        assert [%{"status" => "rejected", "code" => "invalid_amount"}] =
                 submit(build_conn(), [
                   apply_credit_op("group-b", amount, %{
                     "operation_id" => "credit-invalid-#{index}"
                   })
                 ])
      end)
    end

    test "rejects a missing amount" do
      issue_5500_lot(build_conn())
      submit(build_conn(), [open_op("group-b")])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               submit(build_conn(), [
                 apply_credit_op("group-b", 100) |> Map.delete("amount_cents")
               ])
    end

    test "rejects a missing group" do
      issue_5500_lot(build_conn())

      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               submit(build_conn(), [apply_credit_op("nope", 100)])
    end

    test "rejects a cancelled group" do
      issue_5500_lot(build_conn())
      submit(build_conn(), [open_op("group-b"), cancel_op("group-b", "2026-11-01")])

      assert [%{"status" => "rejected", "code" => "group_not_active"}] =
               submit(build_conn(), [apply_credit_op("group-b", 100)])
    end

    test "a stale revision is rejected before the credit rules" do
      submit(build_conn(), [open_op("group-b")])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-b",
                 "expected_revision" => 99,
                 "actual_revision" => 1
               }
             ] =
               submit(build_conn(), [
                 apply_credit_op("group-b", 100, %{"expected_revision" => 99})
               ])
    end

    test "a matching expected_revision applies" do
      issue_5500_lot(build_conn())
      submit(build_conn(), [open_op("group-b")])

      assert [%{"status" => "applied", "revision" => 2}] =
               submit(build_conn(), [apply_credit_op("group-b", 100, %{"expected_revision" => 1})])
    end
  end

  describe "settling groups funded by credit" do
    test "a refundable cash cancellation refunds cash and restores credit to its lot" do
      issue_5500_lot(build_conn())
      submit(build_conn(), [open_op("group-b"), pay_op("group-b", 3000)])
      submit(build_conn(), [apply_credit_op("group-b", 2000)])

      assert [
               %{
                 "status" => "applied",
                 "group_id" => "group-b",
                 "refunded_cents" => 3000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ] = submit(build_conn(), [cancel_op("group-b", "2026-11-20")])

      assert guest_credit(build_conn(), @guest, %{"on" => "2026-11-20"}) == %{
               "guest_id" => @guest,
               "available_cents" => 5500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-group-a",
                   "remaining_cents" => 5500,
                   "expires_on" => "2027-11-02"
                 }
               ]
             }

      assert ledger(build_conn(), %{"on" => "2026-11-20"}) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 3000,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500
             }
    end

    test "a refundable hotel-credit cancellation converts cash and restores applied credit" do
      issue_5500_lot(build_conn())
      submit(build_conn(), [open_op("group-b"), pay_op("group-b", 3000)])
      submit(build_conn(), [apply_credit_op("group-b", 2000)])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 3300,
                 "revision" => 4
               }
             ] =
               submit(build_conn(), [
                 cancel_op("group-b", "2026-11-20", %{"refund_method" => "hotel_credit"})
               ])

      # The applied credit returns to its original lot without a second
      # bonus; only the cash portion receives the 10% bonus.
      assert guest_credit(build_conn(), @guest, %{"on" => "2026-11-20"}) == %{
               "guest_id" => @guest,
               "available_cents" => 8800,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-group-a",
                   "remaining_cents" => 5500,
                   "expires_on" => "2027-11-02"
                 },
                 %{
                   "source_operation_id" => "cancel-group-b",
                   "remaining_cents" => 3300,
                   "expires_on" => "2027-11-21"
                 }
               ]
             }

      assert ledger(build_conn(), %{"on" => "2026-11-20"}) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 8000,
               "credit_liability_cents" => 8800
             }
    end

    test "credit restored to an already expired lot reduces the liability" do
      submit(build_conn(), [
        open_op("group-a", %{
          "occurred_on" => "2026-01-01",
          "arrival_on" => "2026-03-01",
          "departure_on" => "2026-03-03"
        }),
        pay_op("group-a", 1000, %{"occurred_on" => "2026-01-02"})
      ])

      submit(build_conn(), [
        cancel_op("group-a", "2026-02-01", %{"refund_method" => "hotel_credit"})
      ])

      submit(build_conn(), [
        open_op("group-b", %{"arrival_on" => "2027-03-01", "departure_on" => "2027-03-03"})
      ])

      submit(build_conn(), [apply_credit_op("group-b", 1000, %{"occurred_on" => "2026-02-05"})])

      assert ledger(build_conn(), %{"on" => "2026-02-05"})["credit_liability_cents"] == 1100

      # Cancelled after the lot's 2027-02-02 expiry: the restored amount
      # expires immediately instead of becoming available again.
      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 0}] =
               submit(build_conn(), [cancel_op("group-b", "2027-02-10")])

      assert guest_credit(build_conn(), @guest, %{"on" => "2027-02-10"}) == %{
               "guest_id" => @guest,
               "available_cents" => 0,
               "lots" => []
             }

      assert ledger(build_conn(), %{"on" => "2027-02-10"}) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 1000,
               "credit_liability_cents" => 0
             }
    end

    test "a non-refundable cancellation retains cash and consumes applied credit" do
      issue_5500_lot(build_conn())
      submit(build_conn(), [open_op("group-b"), pay_op("group-b", 3000)])
      submit(build_conn(), [apply_credit_op("group-b", 2000)])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 3000,
                 "credit_issued_cents" => 0
               }
             ] = submit(build_conn(), [cancel_op("group-b", "2026-12-05")])

      assert guest_credit(build_conn(), @guest, %{"on" => "2026-12-05"}) == %{
               "guest_id" => @guest,
               "available_cents" => 3500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-group-a",
                   "remaining_cents" => 3500,
                   "expires_on" => "2027-11-02"
                 }
               ]
             }

      assert ledger(build_conn(), %{"on" => "2026-12-05"}) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 3000,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 3500
             }
    end
  end

  describe "guest credit reads" do
    test "returns zeros for a guest without credit" do
      assert guest_credit(build_conn(), "guest-none", %{"on" => "2026-11-01"}) == %{
               "guest_id" => "guest-none",
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "omits exhausted lots" do
      issue_5500_lot(build_conn())
      submit(build_conn(), [open_op("group-b")])
      submit(build_conn(), [apply_credit_op("group-b", 5500)])

      assert guest_credit(build_conn(), @guest, %{"on" => "2026-11-02"}) == %{
               "guest_id" => @guest,
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "omits expired lots as of the on date" do
      issue_5500_lot(build_conn())

      assert guest_credit(build_conn(), @guest, %{"on" => "2027-11-01"})["available_cents"] ==
               5500

      assert guest_credit(build_conn(), @guest, %{"on" => "2027-11-02"})["available_cents"] == 0
    end

    test "orders lots by expiry, then by source operation" do
      submit(build_conn(), [
        open_op("group-a"),
        pay_op("group-a", 2000),
        open_op("group-b"),
        pay_op("group-b", 1000),
        open_op("group-c"),
        pay_op("group-c", 1000)
      ])

      submit(build_conn(), [
        cancel_op("group-b", "2026-11-01", %{"refund_method" => "hotel_credit"}),
        cancel_op("group-c", "2026-11-01", %{"refund_method" => "hotel_credit"}),
        cancel_op("group-a", "2026-11-05", %{"refund_method" => "hotel_credit"})
      ])

      assert %{
               "available_cents" => 4400,
               "lots" => [
                 %{"source_operation_id" => "cancel-group-b", "expires_on" => "2027-11-02"},
                 %{"source_operation_id" => "cancel-group-c", "expires_on" => "2027-11-02"},
                 %{"source_operation_id" => "cancel-group-a", "expires_on" => "2027-11-06"}
               ]
             } = guest_credit(build_conn(), @guest, %{"on" => "2026-11-06"})
    end
  end

  describe "ledger reads" do
    test "the credit liability reports expiry as of the on date" do
      issue_5500_lot(build_conn())

      assert ledger(build_conn(), %{"on" => "2027-11-01"})["credit_liability_cents"] == 5500
      assert ledger(build_conn(), %{"on" => "2027-11-02"})["credit_liability_cents"] == 0
    end

    test "converted cash accumulates across cancellations" do
      issue_5500_lot(build_conn())
      submit(build_conn(), [open_op("group-b"), pay_op("group-b", 1000)])

      submit(build_conn(), [
        cancel_op("group-b", "2026-11-01", %{"refund_method" => "hotel_credit"})
      ])

      assert ledger(build_conn(), %{"on" => "2026-11-02"})["cash_converted_to_credit_cents"] ==
               6000
    end

    test "an invalid on date is rejected" do
      conn = get(build_conn(), "/api/v1/ledger", %{"on" => "soon"})
      assert json_response(conn, 400) == %{"error" => %{"code" => "invalid_date"}}

      conn = get(build_conn(), "/api/v1/guests/#{@guest}/credit", %{"on" => "soon"})
      assert json_response(conn, 400) == %{"error" => %{"code" => "invalid_date"}}
    end
  end
end
