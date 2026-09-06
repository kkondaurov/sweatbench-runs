defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp results(conn), do: json_response(conn, 200)["results"]

  defp single_result(conn, operations) do
    [result] = conn |> submit(operations) |> results()
    result
  end

  # One room at 10000/night for three nights: lodging 30000, deposit 6000.
  defp open_group_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
      },
      overrides
    )
  end

  defp open_group(conn, overrides \\ %{}) do
    result = single_result(conn, [open_group_op(overrides)])
    assert result["status"] == "applied"
    result
  end

  defp pay_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5000
      },
      overrides
    )
  end

  defp pay(conn, overrides \\ %{}) do
    result = single_result(conn, [pay_op(overrides)])
    assert result["status"] == "applied"
    result
  end

  defp cancel_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp cancel(conn, overrides) do
    result = single_result(conn, [cancel_op(overrides)])
    assert result["status"] == "applied"
    result
  end

  defp apply_credit_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 1000
      },
      overrides
    )
  end

  defp get_group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_credit(conn, guest_id, on \\ nil) do
    path =
      case on do
        nil -> "/api/v1/guests/#{guest_id}/credit"
        date -> "/api/v1/guests/#{guest_id}/credit?on=#{date}"
      end

    conn |> get(path) |> json_response(200) |> Map.fetch!("data")
  end

  defp get_ledger(conn, on \\ nil) do
    path = if on, do: "/api/v1/ledger?on=#{on}", else: "/api/v1/ledger"
    conn |> get(path) |> json_response(200) |> Map.fetch!("data")
  end

  # Opens a group for the guest, pays cash into it, and cancels it as hotel
  # credit so the guest holds a credit lot.
  defp issue_credit(conn, group_id, op_id, cash_cents, cancelled_on \\ "2026-10-04") do
    open_group(conn, %{
      "operation_id" => "op-open-#{group_id}",
      "group_id" => group_id
    })

    pay(conn, %{
      "operation_id" => "op-pay-#{group_id}",
      "group_id" => group_id,
      "amount_cents" => cash_cents
    })

    cancel(conn, %{
      "operation_id" => op_id,
      "group_id" => group_id,
      "occurred_on" => cancelled_on,
      "refund_method" => "hotel_credit"
    })
  end

  describe "policy versions" do
    test "flexible groups booked before 2027-01-01 keep the 14-day window", %{conn: conn} do
      open_group(conn, %{"occurred_on" => "2026-12-31"})
      group = get_group(conn, "group-81")

      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2026-11-26"

      # Cancelling on refundable_until is refundable; the next day is not.
      pay(conn)
      result = single_result(conn, [cancel_op(%{"occurred_on" => "2026-11-26"})])
      assert result["refunded_cents"] == 5000
      assert result["retained_cents"] == 0
    end

    test "flexible groups booked on or after 2027-01-01 use the 30-day window", %{conn: conn} do
      open_group(conn, %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-13"
      })

      group = get_group(conn, "group-81")
      assert group["policy_version"] == "flex-30"
      assert group["refundable_until"] == "2027-02-08"

      pay(conn)

      # 30 days before arrival is refundable; 29 days is not.
      result = single_result(conn, [cancel_op(%{"occurred_on" => "2027-02-08"})])
      assert result["refunded_cents"] == 5000

      open_group(conn, %{
        "operation_id" => "op-open-2",
        "group_id" => "group-82",
        "occurred_on" => "2027-01-02",
        "arrival_on" => "2027-03-10",
        "departure_on" => "2027-03-13"
      })

      pay(conn, %{"operation_id" => "op-pay-2", "group_id" => "group-82"})

      result =
        single_result(conn, [
          cancel_op(%{
            "operation_id" => "op-cancel-2",
            "group_id" => "group-82",
            "occurred_on" => "2027-02-09"
          })
        ])

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 5000
    end

    test "advance-purchase groups stay non-refundable", %{conn: conn} do
      open_group(conn, %{"rate_plan" => "advance_purchase", "occurred_on" => "2027-02-01"})
      group = get_group(conn, "group-81")

      assert group["policy_version"] == "advance-nonrefundable"
      assert group["refundable_until"] == nil
    end

    test "rescheduling never moves a group to a newer policy", %{conn: conn} do
      open_group(conn, %{"occurred_on" => "2026-12-31"})

      result =
        single_result(conn, [
          %{
            "operation_id" => "op-move",
            "type" => "reschedule_group",
            "occurred_on" => "2027-01-05",
            "group_id" => "group-81",
            "new_arrival_on" => "2027-02-20"
          }
        ])

      assert result["status"] == "applied"
      assert result["policy_version"] == "flex-14"
      # refundable_until is recomputed from the new arrival.
      assert result["refundable_until"] == "2027-02-06"

      group = get_group(conn, "group-81")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-02-06"
    end

    test "groups created before this release remain readable with their implied policy", %{
      conn: conn
    } do
      Repo.insert!(%Group{
        group_id: "group-legacy-14",
        guest_id: "guest-22",
        property_id: "ams-canal",
        arrival_on: ~D[2027-02-10],
        departure_on: ~D[2027-02-13],
        booked_on: ~D[2026-11-15],
        rate_plan: "flexible",
        lodging_total_cents: 30000,
        deposit_due_cents: 6000
      })

      Repo.insert!(%Group{
        group_id: "group-legacy-30",
        guest_id: "guest-22",
        property_id: "ams-canal",
        arrival_on: ~D[2027-04-10],
        departure_on: ~D[2027-04-13],
        booked_on: ~D[2027-01-01],
        rate_plan: "flexible",
        lodging_total_cents: 30000,
        deposit_due_cents: 6000
      })

      Repo.insert!(%Group{
        group_id: "group-legacy-advance",
        guest_id: "guest-22",
        property_id: "ams-canal",
        arrival_on: ~D[2027-04-10],
        departure_on: ~D[2027-04-13],
        booked_on: ~D[2026-11-15],
        rate_plan: "advance_purchase",
        lodging_total_cents: 30000,
        deposit_due_cents: 30000
      })

      group = get_group(conn, "group-legacy-14")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2027-01-27"
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 0
      assert group["deposit_paid_cents"] == 0

      group = get_group(conn, "group-legacy-30")
      assert group["policy_version"] == "flex-30"
      assert group["refundable_until"] == "2027-03-11"

      group = get_group(conn, "group-legacy-advance")
      assert group["policy_version"] == "advance-nonrefundable"
      assert group["refundable_until"] == nil
    end
  end

  describe "cancel_group refund_method" do
    test "omitting refund_method still settles as cash", %{conn: conn} do
      open_group(conn)
      pay(conn)

      result = single_result(conn, [cancel_op(%{"occurred_on" => "2026-11-26"})])
      assert result["refunded_cents"] == 5000
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      assert get_credit(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "hotel credit on a refundable cancellation issues a lot worth 110% of the cash", %{
      conn: conn
    } do
      open_group(conn)
      pay(conn)

      result =
        single_result(conn, [
          cancel_op(%{"occurred_on" => "2026-11-26", "refund_method" => "hotel_credit"})
        ])

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "applied",
               "group_id" => "group-81",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 5500,
               "revision" => 3
             }

      # The converted cash is neither refunded nor retained.
      assert get_ledger(conn) == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 5000,
               "credit_liability_cents" => 5500,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0
             }

      credit = get_credit(conn, "guest-22")

      assert credit == %{
               "guest_id" => "guest-22",
               "available_cents" => 5500,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel",
                   "remaining_cents" => 5500,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      group = get_group(conn, "group-81")
      assert group["status"] == "cancelled"
      # The group's paid totals describe active rooms only.
      assert group["deposit_paid_cents"] == 0
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 0
    end

    test "the 10% bonus rounds half up", %{conn: conn} do
      # 10% of 1005 is exactly 100.5, rounding up to 101.
      issue_credit(conn, "group-up", "op-cancel-up", 1005)

      [lot] = get_credit(conn, "guest-22")["lots"]
      assert lot["remaining_cents"] == 1106

      # 10% of 1004 is 100.4, rounding down to 100.
      issue_credit(conn, "group-down", "op-cancel-down", 1004)

      lots = get_credit(conn, "guest-22")["lots"]
      assert Enum.map(lots, & &1["remaining_cents"]) |> Enum.sort() == [1104, 1106]
    end

    test "the issued lot is available through 365 days after cancellation", %{conn: conn} do
      issue_credit(conn, "group-81", "op-cancel", 1000, "2026-10-04")

      assert get_credit(conn, "guest-22", "2027-10-04")["available_cents"] == 1100
      assert get_credit(conn, "guest-22", "2027-10-05")["available_cents"] == 0

      assert get_ledger(conn, "2027-10-04")["credit_liability_cents"] == 1100
      assert get_ledger(conn, "2027-10-05")["credit_liability_cents"] == 0
    end

    test "hotel credit is rejected for a non-refundable cancellation", %{conn: conn} do
      open_group(conn)
      pay(conn)

      # Inside the 14-day window.
      result =
        single_result(conn, [
          cancel_op(%{"occurred_on" => "2026-11-27", "refund_method" => "hotel_credit"})
        ])

      assert result == %{
               "operation_id" => "op-cancel",
               "status" => "rejected",
               "code" => "refund_method_not_available"
             }

      group = get_group(conn, "group-81")
      assert group["status"] == "active"
      assert group["revision"] == 2

      assert get_credit(conn, "guest-22")["available_cents"] == 0

      assert get_ledger(conn) == %{
               "cash_held_cents" => 5000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "hotel credit is rejected for an advance-purchase cancellation", %{conn: conn} do
      open_group(conn, %{"rate_plan" => "advance_purchase"})
      pay(conn)

      result = single_result(conn, [cancel_op(%{"refund_method" => "hotel_credit"})])
      assert result["status"] == "rejected"
      assert result["code"] == "refund_method_not_available"
      assert get_group(conn, "group-81")["status"] == "active"
    end

    test "a stale revision is rejected before the refund method domain rule", %{conn: conn} do
      open_group(conn)
      pay(conn)

      result =
        single_result(conn, [
          cancel_op(%{
            "occurred_on" => "2026-11-27",
            "refund_method" => "hotel_credit",
            "expected_revision" => 99
          })
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "stale_revision"
      assert result["actual_revision"] == 2
    end

    test "hotel credit with no cash paid issues nothing", %{conn: conn} do
      open_group(conn)

      result =
        single_result(conn, [
          cancel_op(%{"occurred_on" => "2026-11-26", "refund_method" => "hotel_credit"})
        ])

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      assert get_credit(conn, "guest-22")["lots"] == []
      assert get_ledger(conn)["cash_converted_to_credit_cents"] == 0
    end

    test "an unknown refund method is an invalid operation", %{conn: conn} do
      open_group(conn)

      result = single_result(conn, [cancel_op(%{"refund_method" => "voucher"})])
      assert result["status"] == "rejected"
      assert result["code"] == "invalid_operation"
      assert get_group(conn, "group-81")["revision"] == 1
    end
  end

  describe "apply_hotel_credit" do
    test "applies credit to an active group's outstanding deposit", %{conn: conn} do
      issue_credit(conn, "group-source", "op-cancel", 2000)

      open_group(conn, %{"operation_id" => "op-open-target", "group_id" => "group-target"})

      result =
        single_result(conn, [
          apply_credit_op(%{"group_id" => "group-target", "amount_cents" => 1500})
        ])

      assert result == %{
               "operation_id" => "op-credit",
               "status" => "applied",
               "group_id" => "group-target",
               "amount_cents" => 1500,
               "outstanding_deposit_cents" => 4500,
               "revision" => 2
             }

      group = get_group(conn, "group-target")
      assert group["deposit_paid_cents"] == 1500
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 1500
      assert group["outstanding_deposit_cents"] == 4500

      # The lot is partially consumed.
      credit = get_credit(conn, "guest-22")
      assert credit["available_cents"] == 700
      assert [%{"remaining_cents" => 700}] = credit["lots"]

      # Applying credit moves it from available to applied without changing
      # the liability.
      assert get_ledger(conn)["credit_liability_cents"] == 2200
    end

    test "credit cannot exceed the outstanding deposit", %{conn: conn} do
      issue_credit(conn, "group-source", "op-cancel", 2000)
      open_group(conn, %{"operation_id" => "op-open-target", "group_id" => "group-target"})

      result =
        single_result(conn, [
          apply_credit_op(%{"group_id" => "group-target", "amount_cents" => 6001})
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "payment_exceeds_outstanding"

      # Paying exactly the outstanding deposit is fine.
      result =
        single_result(conn, [
          apply_credit_op(%{
            "operation_id" => "op-credit-2",
            "group_id" => "group-target",
            "amount_cents" => 2200
          })
        ])

      assert result["status"] == "applied"
      assert result["outstanding_deposit_cents"] == 3800
    end

    test "rejects with insufficient_credit when the guest cannot cover the amount", %{conn: conn} do
      issue_credit(conn, "group-source", "op-cancel", 100)
      open_group(conn, %{"operation_id" => "op-open-target", "group_id" => "group-target"})

      result =
        single_result(conn, [
          apply_credit_op(%{"group_id" => "group-target", "amount_cents" => 111})
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "insufficient_credit"

      # A guest with no credit at all is also insufficient.
      open_group(conn, %{
        "operation_id" => "op-open-other",
        "group_id" => "group-other",
        "guest_id" => "guest-99"
      })

      result =
        single_result(conn, [
          apply_credit_op(%{"operation_id" => "op-credit-2", "group_id" => "group-other"})
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "insufficient_credit"
    end

    test "uses the payment validation errors where they apply", %{conn: conn} do
      issue_credit(conn, "group-source", "op-cancel", 2000)

      result = single_result(conn, [apply_credit_op(%{"group_id" => "nope"})])
      assert result["status"] == "rejected"
      assert result["code"] == "group_not_found"

      open_group(conn, %{"operation_id" => "op-open-target", "group_id" => "group-target"})

      single_result(conn, [
        cancel_op(%{"operation_id" => "op-cancel-target", "group_id" => "group-target"})
      ])

      result =
        single_result(conn, [
          apply_credit_op(%{"operation_id" => "op-credit-2", "group_id" => "group-target"})
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "group_not_active"

      open_group(conn, %{
        "operation_id" => "op-open-active",
        "group_id" => "group-active"
      })

      for {amount, code} <- [
            {0, "invalid_amount"},
            {-5, "invalid_amount"},
            {"500", "invalid_amount"}
          ] do
        result =
          single_result(conn, [
            apply_credit_op(%{
              "operation_id" => "op-credit-#{amount}",
              "group_id" => "group-active",
              "amount_cents" => amount
            })
          ])

        assert result["status"] == "rejected"
        assert result["code"] == code
      end

      result =
        single_result(conn, [
          apply_credit_op(%{"operation_id" => "op-credit-missing", "group_id" => "group-active"})
          |> Map.delete("amount_cents")
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_operation"

      assert get_group(conn, "group-active")["revision"] == 1
    end

    test "evaluates expiry using the operation's occurred_on date", %{conn: conn} do
      # Lot issued on 2026-10-04 expires on 2027-10-04.
      issue_credit(conn, "group-source", "op-cancel", 1000)

      open_group(conn, %{
        "operation_id" => "op-open-late",
        "group_id" => "group-late",
        "arrival_on" => "2028-01-10",
        "departure_on" => "2028-01-13"
      })

      # Usable on its expiry date...
      result =
        single_result(conn, [
          apply_credit_op(%{
            "group_id" => "group-late",
            "occurred_on" => "2027-10-04",
            "amount_cents" => 1000
          })
        ])

      assert result["status"] == "applied"

      # ...but not the day after.
      open_group(conn, %{
        "operation_id" => "op-open-later",
        "group_id" => "group-later",
        "arrival_on" => "2028-01-10",
        "departure_on" => "2028-01-13"
      })

      result =
        single_result(conn, [
          apply_credit_op(%{
            "operation_id" => "op-credit-2",
            "group_id" => "group-later",
            "occurred_on" => "2027-10-05",
            "amount_cents" => 100
          })
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "insufficient_credit"
    end

    test "consumes lots by earliest expiry, then by source operation for equal expiries", %{
      conn: conn
    } do
      # Two lots with different expiries.
      issue_credit(conn, "group-first", "op-cancel-later", 1000, "2026-10-10")
      issue_credit(conn, "group-second", "op-cancel-sooner", 1000, "2026-10-04")

      open_group(conn, %{"operation_id" => "op-open-target", "group_id" => "group-target"})

      single_result(conn, [
        apply_credit_op(%{
          "group_id" => "group-target",
          "occurred_on" => "2026-10-11",
          "amount_cents" => 1500
        })
      ])

      # The earlier-expiring lot is consumed first.
      [lot] = get_credit(conn, "guest-22")["lots"]
      assert lot["source_operation_id"] == "op-cancel-later"
      assert lot["remaining_cents"] == 700
      assert lot["expires_on"] == "2027-10-10"
    end

    test "equal expiries are consumed by source_operation_id order", %{conn: conn} do
      # Same cancellation date, so both lots expire the same day.
      issue_credit(conn, "group-b", "op-cancel-b", 500)
      issue_credit(conn, "group-a", "op-cancel-a", 500)

      open_group(conn, %{"operation_id" => "op-open-target", "group_id" => "group-target"})

      single_result(conn, [
        apply_credit_op(%{"group_id" => "group-target", "amount_cents" => 300})
      ])

      lots = get_credit(conn, "guest-22")["lots"]

      assert lots == [
               %{
                 "source_operation_id" => "op-cancel-a",
                 "remaining_cents" => 250,
                 "expires_on" => "2027-10-04"
               },
               %{
                 "source_operation_id" => "op-cancel-b",
                 "remaining_cents" => 550,
                 "expires_on" => "2027-10-04"
               }
             ]
    end

    test "follows the revision contract", %{conn: conn} do
      issue_credit(conn, "group-source", "op-cancel", 2000)
      open_group(conn, %{"operation_id" => "op-open-target", "group_id" => "group-target"})

      result =
        single_result(conn, [
          apply_credit_op(%{
            "group_id" => "group-target",
            "amount_cents" => 100,
            "expected_revision" => 1
          })
        ])

      assert result["status"] == "applied"
      assert result["revision"] == 2

      result =
        single_result(conn, [
          apply_credit_op(%{
            "operation_id" => "op-credit-2",
            "group_id" => "group-target",
            "amount_cents" => 100,
            "expected_revision" => 1
          })
        ])

      assert result == %{
               "operation_id" => "op-credit-2",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-target",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      # Revision is checked before the credit domain rules.
      result =
        single_result(conn, [
          apply_credit_op(%{
            "operation_id" => "op-credit-3",
            "group_id" => "group-target",
            "amount_cents" => 999_999,
            "expected_revision" => 99
          })
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "stale_revision"
      assert get_group(conn, "group-target")["revision"] == 2
    end

    test "rejections do not advance the revision", %{conn: conn} do
      issue_credit(conn, "group-source", "op-cancel", 100)
      open_group(conn, %{"operation_id" => "op-open-target", "group_id" => "group-target"})

      for op <- [
            apply_credit_op(%{"amount_cents" => 999_999}),
            apply_credit_op(%{"operation_id" => "op-credit-2", "amount_cents" => 0}),
            apply_credit_op(%{"operation_id" => "op-credit-3", "amount_cents" => 6001})
          ] do
        assert single_result(conn, [op])["status"] == "rejected"
        assert get_group(conn, "group-target")["revision"] == 1
      end
    end

    test "a later operation in the same batch can use freshly issued credit", %{conn: conn} do
      results =
        conn
        |> submit([
          open_group_op(%{"group_id" => "group-source"}),
          pay_op(%{
            "operation_id" => "op-pay-source",
            "group_id" => "group-source",
            "amount_cents" => 1000
          }),
          cancel_op(%{
            "operation_id" => "op-cancel-source",
            "group_id" => "group-source",
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          }),
          open_group_op(%{"operation_id" => "op-open-target", "group_id" => "group-target"}),
          apply_credit_op(%{
            "operation_id" => "op-credit",
            "group_id" => "group-target",
            "amount_cents" => 1100
          })
        ])
        |> results()

      assert Enum.map(results, & &1["status"]) == ~w(applied applied applied applied applied)
      assert Enum.at(results, 2)["credit_issued_cents"] == 1100
      assert Enum.at(results, 4)["outstanding_deposit_cents"] == 4900
      assert Enum.at(results, 4)["revision"] == 2
    end
  end

  describe "settling credit-funded groups" do
    setup %{conn: conn} do
      # guest-22 holds a 1100-cent lot expiring 2027-10-04 from cancelling
      # group-source.
      issue_credit(conn, "group-source", "op-cancel-source", 1000)

      open_group(conn, %{
        "operation_id" => "op-open-target",
        "group_id" => "group-target",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13"
      })

      pay(conn, %{
        "operation_id" => "op-pay-target",
        "group_id" => "group-target",
        "amount_cents" => 2000
      })

      single_result(conn, [
        apply_credit_op(%{
          "operation_id" => "op-credit-target",
          "group_id" => "group-target",
          "amount_cents" => 1100
        })
      ])

      :ok
    end

    test "refundable cash cancellation refunds cash and restores credit", %{conn: conn} do
      assert get_ledger(conn)["credit_liability_cents"] == 1100

      result =
        single_result(conn, [
          cancel_op(%{"group_id" => "group-target", "occurred_on" => "2026-11-01"})
        ])

      assert result["refunded_cents"] == 2000
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 0

      # The credit returns to its original lot with its original expiry.
      credit = get_credit(conn, "guest-22")

      assert credit == %{
               "guest_id" => "guest-22",
               "available_cents" => 1100,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-source",
                   "remaining_cents" => 1100,
                   "expires_on" => "2027-10-04"
                 }
               ]
             }

      # Restoration does not change the liability.
      assert get_ledger(conn)["credit_liability_cents"] == 1100

      # The restored credit can fund another group.
      open_group(conn, %{"operation_id" => "op-open-next", "group_id" => "group-next"})

      result =
        single_result(conn, [
          apply_credit_op(%{
            "operation_id" => "op-credit-next",
            "group_id" => "group-next",
            "amount_cents" => 500
          })
        ])

      assert result["status"] == "applied"
      assert get_credit(conn, "guest-22")["available_cents"] == 600
    end

    test "refundable hotel-credit cancellation converts cash and restores credit without a second bonus",
         %{conn: conn} do
      result =
        single_result(conn, [
          cancel_op(%{
            "group_id" => "group-target",
            "occurred_on" => "2026-11-01",
            "refund_method" => "hotel_credit"
          })
        ])

      # The 2000 cash becomes a lot worth 2200; the applied credit is
      # restored at its original 1100, not 1210.
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0
      assert result["credit_issued_cents"] == 2200

      credit = get_credit(conn, "guest-22")
      assert credit["available_cents"] == 3300

      assert credit["lots"] == [
               %{
                 "source_operation_id" => "op-cancel-source",
                 "remaining_cents" => 1100,
                 "expires_on" => "2027-10-04"
               },
               %{
                 "source_operation_id" => "op-cancel",
                 "remaining_cents" => 2200,
                 "expires_on" => "2027-11-01"
               }
             ]

      ledger = get_ledger(conn)
      assert ledger["cash_converted_to_credit_cents"] == 3000
      assert ledger["credit_liability_cents"] == 3300
    end

    test "restored credit whose expiry has passed expires immediately", %{conn: conn} do
      # Cancel group-target after the source lot's 2027-10-04 expiry. The
      # group's flex-14 refundable_until is 2027-12-27, so this is still
      # refundable.
      result =
        single_result(conn, [
          %{
            "operation_id" => "op-reschedule",
            "type" => "reschedule_group",
            "occurred_on" => "2026-11-01",
            "group_id" => "group-target",
            "new_arrival_on" => "2028-01-10"
          }
        ])

      assert result["status"] == "applied"

      assert get_ledger(conn)["credit_liability_cents"] == 1100

      result =
        single_result(conn, [
          cancel_op(%{"group_id" => "group-target", "occurred_on" => "2027-10-05"})
        ])

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 2000
      assert result["retained_cents"] == 0

      # The restored amount is neither available nor carried as liability.
      assert get_credit(conn, "guest-22", "2027-10-05")["available_cents"] == 0
      assert get_ledger(conn, "2027-10-05")["credit_liability_cents"] == 0
    end

    test "non-refundable cancellation retains cash and consumes applied credit", %{conn: conn} do
      assert get_ledger(conn)["credit_liability_cents"] == 1100

      # Inside the window: non-refundable.
      result =
        single_result(conn, [
          cancel_op(%{"group_id" => "group-target", "occurred_on" => "2026-12-01"})
        ])

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 2000
      assert result["credit_issued_cents"] == 0

      assert get_credit(conn, "guest-22")["available_cents"] == 0

      ledger = get_ledger(conn)
      assert ledger["cash_retained_cents"] == 2000
      assert ledger["credit_liability_cents"] == 0

      # The group's paid totals describe active rooms only; the settled
      # rooms keep their own accounting.
      group = get_group(conn, "group-target")
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 0

      [room] = group["rooms"]
      assert room["status"] == "cancelled"
      assert room["deposit_due_cents"] == 6000
      assert room["cash_paid_cents"] == 2000
      assert room["credit_paid_cents"] == 1100
    end
  end

  describe "guest credit endpoint" do
    test "a guest without credit has none available", %{conn: conn} do
      assert get_credit(conn, "guest-nobody") == %{
               "guest_id" => "guest-nobody",
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "orders lots by expiry, then source operation, and omits exhausted lots", %{conn: conn} do
      issue_credit(conn, "group-b", "op-cancel-b", 500)
      issue_credit(conn, "group-a", "op-cancel-a", 500)
      issue_credit(conn, "group-c", "op-cancel-c", 500, "2026-10-01")

      open_group(conn, %{"operation_id" => "op-open-target", "group_id" => "group-target"})

      # Exhaust the earliest lot (op-cancel-c, expiring 2027-10-01).
      single_result(conn, [
        apply_credit_op(%{"group_id" => "group-target", "amount_cents" => 550})
      ])

      lots = get_credit(conn, "guest-22")["lots"]

      assert lots == [
               %{
                 "source_operation_id" => "op-cancel-a",
                 "remaining_cents" => 550,
                 "expires_on" => "2027-10-04"
               },
               %{
                 "source_operation_id" => "op-cancel-b",
                 "remaining_cents" => 550,
                 "expires_on" => "2027-10-04"
               }
             ]
    end

    test "defaults to the current UTC date", %{conn: conn} do
      today = Date.utc_today()
      today_iso = Date.to_iso8601(today)

      open_group(conn, %{
        "occurred_on" => today_iso,
        "arrival_on" => Date.to_iso8601(Date.add(today, 60)),
        "departure_on" => Date.to_iso8601(Date.add(today, 63))
      })

      pay(conn, %{"occurred_on" => today_iso})

      assert single_result(conn, [
               cancel_op(%{"occurred_on" => today_iso, "refund_method" => "hotel_credit"})
             ])["status"] == "applied"

      assert get_credit(conn, "guest-22")["available_cents"] == 5500

      assert get_credit(conn, "guest-22", Date.to_iso8601(Date.add(today, 366)))[
               "available_cents"
             ] == 0

      assert get_ledger(conn)["credit_liability_cents"] == 5500
    end

    test "an invalid on date is rejected", %{conn: conn} do
      conn = get(conn, "/api/v1/guests/guest-22/credit?on=soon")

      assert json_response(conn, 400) == %{"error" => %{"code" => "invalid_date"}}
    end
  end

  describe "ledger" do
    test "credit liability includes both available and applied credit", %{conn: conn} do
      issue_credit(conn, "group-one", "op-cancel-1", 1000)
      issue_credit(conn, "group-two", "op-cancel-2", 500, "2026-10-10")

      open_group(conn, %{"operation_id" => "op-open-target", "group_id" => "group-target"})

      single_result(conn, [
        apply_credit_op(%{
          "group_id" => "group-target",
          "occurred_on" => "2026-10-11",
          "amount_cents" => 800
        })
      ])

      # 300 + 550 available plus 800 applied.
      assert get_ledger(conn)["credit_liability_cents"] == 1650
    end

    test "converted cash accumulates across cancellations", %{conn: conn} do
      issue_credit(conn, "group-one", "op-cancel-1", 1000)
      issue_credit(conn, "group-two", "op-cancel-2", 2000)

      ledger = get_ledger(conn)
      assert ledger["cash_converted_to_credit_cents"] == 3000
      assert ledger["credit_liability_cents"] == 3300
    end

    test "an invalid on date is rejected", %{conn: conn} do
      conn = get(conn, "/api/v1/ledger?on=not-a-date")

      assert json_response(conn, 400) == %{"error" => %{"code" => "invalid_date"}}
    end
  end
end
