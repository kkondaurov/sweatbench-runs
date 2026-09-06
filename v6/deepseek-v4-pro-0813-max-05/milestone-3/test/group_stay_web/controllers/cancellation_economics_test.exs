defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  import GroupStay.TestOps

  # Opens a source group for the guest, pays it, and cancels it with hotel
  # credit, returning the credit-issuing result.
  defp issue_credit(conn, overrides) do
    group_id = Map.get(overrides, :group_id, "group-src")
    guest_id = Map.get(overrides, :guest_id, "guest-src")
    cash = Map.get(overrides, :cash, 10_000)
    booked_on = Map.get(overrides, :booked_on, "2026-10-03")
    arrival_on = Map.get(overrides, :arrival_on, "2026-12-10")
    cancel_on = Map.get(overrides, :cancel_on, "2026-11-26")
    departure_on = Date.to_iso8601(Date.add(Date.from_iso8601!(arrival_on), 3))

    conn =
      submit(conn, [
        open_group(%{
          "operation_id" => "open-#{group_id}",
          "group_id" => group_id,
          "guest_id" => guest_id,
          "occurred_on" => booked_on,
          "arrival_on" => arrival_on,
          "departure_on" => departure_on
        }),
        payment(%{
          "operation_id" => "pay-#{group_id}",
          "group_id" => group_id,
          "amount_cents" => cash
        }),
        cancel(%{
          "operation_id" => "cancel-#{group_id}",
          "group_id" => group_id,
          "occurred_on" => cancel_on,
          "refund_method" => "hotel_credit"
        })
      ])

    results = json_response(conn, 200)["results"]

    assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"}] =
             results

    {conn, Enum.at(results, 2)}
  end

  defp open_target(conn, overrides) do
    group_id = Map.get(overrides, :group_id, "group-target")
    guest_id = Map.get(overrides, :guest_id, "guest-src")
    booked_on = Map.get(overrides, :booked_on, "2026-10-03")
    arrival_on = Map.get(overrides, :arrival_on, "2026-12-10")
    departure_on = Date.to_iso8601(Date.add(Date.from_iso8601!(arrival_on), 3))

    conn =
      submit(conn, [
        open_group(%{
          "operation_id" => "open-#{group_id}",
          "group_id" => group_id,
          "guest_id" => guest_id,
          "occurred_on" => booked_on,
          "arrival_on" => arrival_on,
          "departure_on" => departure_on
        })
      ])

    [%{"status" => "applied"}] = json_response(conn, 200)["results"]
    conn
  end

  describe "policy versions" do
    test "flexible groups booked before 2027 keep the 14-day window", %{conn: conn} do
      conn =
        submit(conn, [
          open_group(%{
            "group_id" => "group-old",
            "occurred_on" => "2026-12-31",
            "arrival_on" => "2027-03-01",
            "departure_on" => "2027-03-03"
          })
        ])

      assert [_] = json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-old")), 200)["data"]
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2027-02-15"
    end

    test "flexible groups booked on 2027-01-01 use the 30-day window", %{conn: conn} do
      conn =
        submit(conn, [
          open_group(%{
            "group_id" => "group-new",
            "occurred_on" => "2027-01-01",
            "arrival_on" => "2027-06-01",
            "departure_on" => "2027-06-03"
          })
        ])

      assert [_] = json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-new")), 200)["data"]
      assert data["policy_version"] == "flex-30"
      assert data["refundable_until"] == "2027-05-02"
    end

    test "advance purchase groups are advance-nonrefundable with no refundable date", %{
      conn: conn
    } do
      conn =
        submit(conn, [open_group(%{"group_id" => "grp-adv", "rate_plan" => "advance_purchase"})])

      assert [_] = json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("grp-adv")), 200)["data"]
      assert data["policy_version"] == "advance-nonrefundable"
      assert data["refundable_until"] == nil
    end

    test "rescheduling never moves a group to a newer policy", %{conn: conn} do
      conn =
        submit(conn, [
          open_group(%{
            "group_id" => "group-old-fixed",
            "occurred_on" => "2026-12-31",
            "arrival_on" => "2027-03-01",
            "departure_on" => "2027-03-03"
          })
        ])

      assert [_] = json_response(conn, 200)["results"]

      conn =
        json_post(
          conn,
          reschedule(%{
            "operation_id" => "op-move",
            "group_id" => "group-old-fixed",
            "occurred_on" => "2027-01-02",
            "new_arrival_on" => "2027-06-01"
          })
        )

      [result] = json_response(conn, 200)["results"]

      assert result == %{
               "operation_id" => "op-move",
               "status" => "applied",
               "group_id" => "group-old-fixed",
               "new_arrival_on" => "2027-06-01",
               "new_departure_on" => "2027-06-03",
               "policy_version" => "flex-14",
               "refundable_until" => "2027-05-18",
               "revision" => 2
             }

      data = json_response(get(conn, groups_path("group-old-fixed")), 200)["data"]
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2027-05-18"
    end

    test "an advance purchase reschedule reports a null refundable_until", %{conn: conn} do
      conn =
        submit(conn, [open_group(%{"group_id" => "grp-adv-2", "rate_plan" => "advance_purchase"})])

      assert [_] = json_response(conn, 200)["results"]

      conn =
        json_post(
          conn,
          reschedule(%{
            "operation_id" => "op-move-2",
            "group_id" => "grp-adv-2",
            "occurred_on" => "2026-11-01",
            "new_arrival_on" => "2027-06-01"
          })
        )

      [result] = json_response(conn, 200)["results"]

      assert result["status"] == "applied"
      assert result["policy_version"] == "advance-nonrefundable"
      assert result["refundable_until"] == nil
    end
  end

  describe "cancellation windows" do
    test "flex-30 refunds through its 30-day window and retains afterwards", %{conn: conn} do
      submit(conn, [
        open_group(%{
          "operation_id" => "op-a",
          "group_id" => "grp-refund",
          "occurred_on" => "2027-01-05",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-03"
        })
      ])

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-refund",
          "group_id" => "grp-refund",
          "amount_cents" => 5_000
        })
      )

      conn =
        json_post(
          conn,
          cancel(%{
            "operation_id" => "cancel-refund",
            "group_id" => "grp-refund",
            "occurred_on" => "2027-05-02"
          })
        )

      assert [%{"status" => "applied", "refunded_cents" => 5_000, "retained_cents" => 0}] =
               json_response(conn, 200)["results"]

      submit(conn, [
        open_group(%{
          "operation_id" => "op-b",
          "group_id" => "grp-retain",
          "occurred_on" => "2027-01-05",
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-03"
        })
      ])

      json_post(
        conn,
        payment(%{
          "operation_id" => "pay-retain",
          "group_id" => "grp-retain",
          "amount_cents" => 5_000
        })
      )

      conn =
        json_post(
          conn,
          cancel(%{
            "operation_id" => "cancel-retain",
            "group_id" => "grp-retain",
            "occurred_on" => "2027-05-03"
          })
        )

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 5_000}] =
               json_response(conn, 200)["results"]
    end

    test "flexible groups booked on or after the cutover use the 30-day window", %{conn: conn} do
      # A group's policy follows its booked_on date, not its creation order.
      conn =
        submit(conn, [
          open_group(%{
            "group_id" => "grp-late-book",
            "occurred_on" => "2027-02-01",
            "arrival_on" => "2027-06-01",
            "departure_on" => "2027-06-03"
          })
        ])

      assert [_] = json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("grp-late-book")), 200)["data"]
      assert data["policy_version"] == "flex-30"
      assert data["refundable_until"] == "2027-05-02"
    end
  end

  describe "hotel credit on cancellation" do
    test "refundable hotel_credit cancellation converts cash at 110%", %{conn: conn} do
      {conn, cancel_result} = issue_credit(conn, %{})

      assert cancel_result == %{
               "operation_id" => "cancel-group-src",
               "status" => "applied",
               "group_id" => "group-src",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => 11_000,
               "revision" => 3
             }

      assert json_response(get(conn, guest_credit_path("guest-src")), 200) == %{
               "data" => %{
                 "guest_id" => "guest-src",
                 "available_cents" => 11_000,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-group-src",
                     "remaining_cents" => 11_000,
                     "expires_on" => "2027-11-27"
                   }
                 ]
               }
             }

      assert json_response(get(conn, "/api/v1/ledger"), 200) == %{
               "data" => %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 10_000,
                 "credit_liability_cents" => 11_000
               }
             }

      data = json_response(get(conn, groups_path("group-src")), 200)["data"]

      assert %{
               "status" => "cancelled",
               "cash_paid_cents" => 10_000,
               "credit_paid_cents" => 0,
               "deposit_paid_cents" => 10_000
             } = data
    end

    test "the 10% bonus rounds each conversion half-up", %{conn: conn} do
      {conn, r1} = issue_credit(conn, %{group_id: "src-9999", guest_id: "g1", cash: 9_999})
      assert r1["credit_issued_cents"] == 10_999

      {_conn, r2} = issue_credit(conn, %{group_id: "src-5", guest_id: "g2", cash: 5})
      assert r2["credit_issued_cents"] == 6
    end

    test "hotel_credit is rejected for a non-refundable cancellation, group stays active", %{
      conn: conn
    } do
      open_group!(conn)
      json_post(conn, payment(%{"amount_cents" => 10_000}))

      conn =
        json_post(
          conn,
          cancel(%{"occurred_on" => "2026-12-01", "refund_method" => "hotel_credit"})
        )

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-cancel",
                   "status" => "rejected",
                   "code" => "refund_method_not_available"
                 }
               ]
             }

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"status" => "active", "revision" => 2} = data
    end

    test "advance purchase with hotel_credit is rejected and stays active", %{conn: conn} do
      submit(conn, [open_group(%{"group_id" => "grp-adv-3", "rate_plan" => "advance_purchase"})])

      conn =
        json_post(
          conn,
          cancel(%{
            "group_id" => "grp-adv-3",
            "occurred_on" => "2026-10-20",
            "refund_method" => "hotel_credit"
          })
        )

      assert [%{"status" => "rejected", "code" => "refund_method_not_available"}] =
               json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("grp-adv-3")), 200)["data"]
      assert %{"status" => "active", "revision" => 1} = data
    end

    test "an unusable refund_method is invalid_operation", %{conn: conn} do
      open_group!(conn)

      conn = json_post(conn, cancel(%{"refund_method" => "vouchers"}))

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-81")), 200)["data"]
      assert %{"status" => "active", "revision" => 1} = data
    end
  end

  describe "apply_hotel_credit" do
    test "applies unexpired credit to an active group", %{conn: conn} do
      {conn, _} = issue_credit(conn, %{})

      conn = open_target(conn, %{})

      conn =
        json_post(conn, apply_credit(%{"group_id" => "group-target", "amount_cents" => 5_000}))

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-apply-credit",
                   "status" => "applied",
                   "group_id" => "group-target",
                   "amount_cents" => 5_000,
                   "outstanding_deposit_cents" => 14_500,
                   "revision" => 2
                 }
               ]
             }

      data = json_response(get(conn, groups_path("group-target")), 200)["data"]

      assert %{
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 5_000,
               "deposit_paid_cents" => 5_000,
               "outstanding_deposit_cents" => 14_500,
               "status" => "active"
             } = data

      assert json_response(get(conn, guest_credit_path("guest-src")), 200) == %{
               "data" => %{
                 "guest_id" => "guest-src",
                 "available_cents" => 6_000,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-group-src",
                     "remaining_cents" => 6_000,
                     "expires_on" => "2027-11-27"
                   }
                 ]
               }
             }

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_converted_to_credit_cents"] == 10_000
      assert ledger["credit_liability_cents"] == 11_000
    end

    test "cash payments observe the credit-paid outstanding", %{conn: conn} do
      {conn, _} = issue_credit(conn, %{})
      open_target(conn, %{})

      json_post(conn, apply_credit(%{"group_id" => "group-target", "amount_cents" => 5_000}))

      conn =
        json_post(
          conn,
          payment(%{
            "operation_id" => "op-pay-full",
            "group_id" => "group-target",
            "amount_cents" => 14_500
          })
        )

      assert [%{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 3}] =
               json_response(conn, 200)["results"]

      conn =
        json_post(
          conn,
          payment(%{
            "operation_id" => "op-pay-over",
            "group_id" => "group-target",
            "amount_cents" => 1
          })
        )

      assert [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}] =
               json_response(conn, 200)["results"]
    end

    test "credit cannot exceed the outstanding deposit", %{conn: conn} do
      conn =
        submit(conn, [
          open_group(%{
            "operation_id" => "open-big",
            "group_id" => "group-big",
            "guest_id" => "guest-big",
            "rooms" => [%{"room_id" => "big-room", "nightly_rate_cents" => 200_000}]
          }),
          payment(%{
            "operation_id" => "pay-big",
            "group_id" => "group-big",
            "amount_cents" => 90_000
          }),
          cancel(%{
            "operation_id" => "cancel-big",
            "group_id" => "group-big",
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          })
        ])

      [_, _, big_cancel] = json_response(conn, 200)["results"]
      assert big_cancel["credit_issued_cents"] == 99_000

      open_target(conn, %{group_id: "group-big-target", guest_id: "guest-big"})

      conn =
        json_post(
          conn,
          apply_credit(%{
            "group_id" => "group-big-target",
            "amount_cents" => 20_000
          })
        )

      assert [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}] =
               json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-big-target")), 200)["data"]

      assert %{
               "revision" => 1,
               "credit_paid_cents" => 0,
               "outstanding_deposit_cents" => 19_500
             } = data
    end

    test "insufficient_credit when the guest cannot cover the request", %{conn: conn} do
      {conn, _} = issue_credit(conn, %{cash: 1_000})
      open_target(conn, %{})

      conn =
        json_post(conn, apply_credit(%{"group_id" => "group-target", "amount_cents" => 1_200}))

      assert [%{"status" => "rejected", "code" => "insufficient_credit"}] =
               json_response(conn, 200)["results"]

      data = json_response(get(conn, groups_path("group-target")), 200)["data"]
      assert %{"revision" => 1, "credit_paid_cents" => 0} = data
    end

    test "an unusable amount is invalid_amount and missing amount is invalid_operation", %{
      conn: conn
    } do
      {conn, _} = issue_credit(conn, %{})
      open_target(conn, %{})

      for amount <- [0, -5, 10.5, "1000"] do
        op =
          apply_credit(%{
            "operation_id" => "apply-bad-#{inspect(amount)}",
            "group_id" => "group-target",
            "amount_cents" => amount
          })

        [result] = json_response(json_post(conn, op), 200)["results"]
        assert result["code"] == "invalid_amount"
      end

      op =
        apply_credit(%{"operation_id" => "op-no-amount", "group_id" => "group-target"})
        |> Map.delete("amount_cents")

      [result] = json_response(json_post(conn, op), 200)["results"]
      assert result["code"] == "invalid_operation"

      op =
        apply_credit(%{"operation_id" => "op-no-date", "group_id" => "group-target"})
        |> Map.delete("occurred_on")

      [result] = json_response(json_post(conn, op), 200)["results"]
      assert result["code"] == "invalid_operation"

      data = json_response(get(conn, groups_path("group-target")), 200)["data"]
      assert %{"revision" => 1, "credit_paid_cents" => 0} = data
    end

    test "expired credit cannot be applied", %{conn: conn} do
      {conn, _} = issue_credit(conn, %{})
      open_target(conn, %{})

      # The lot expires on 2027-11-27; it is still available the day before.
      conn =
        json_post(
          conn,
          apply_credit(%{
            "operation_id" => "op-day-before",
            "group_id" => "group-target",
            "occurred_on" => "2027-11-26",
            "amount_cents" => 5_000
          })
        )

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      conn =
        json_post(
          conn,
          apply_credit(%{
            "operation_id" => "op-expired",
            "group_id" => "group-target",
            "occurred_on" => "2027-11-27",
            "amount_cents" => 5_000
          })
        )

      assert [%{"status" => "rejected", "code" => "insufficient_credit"}] =
               json_response(conn, 200)["results"]
    end

    test "consumes lots by earliest expiry, then by source_operation_id", %{conn: conn} do
      {conn, _} =
        issue_credit(conn, %{
          group_id: "src-later",
          guest_id: "guest-order",
          cash: 1_000,
          cancel_on: "2026-11-20"
        })

      {conn, _} =
        issue_credit(conn, %{
          group_id: "src-sooner",
          guest_id: "guest-order",
          cash: 5_000,
          cancel_on: "2026-11-01"
        })

      open_target(conn, %{group_id: "group-order", guest_id: "guest-order"})

      conn =
        json_post(
          conn,
          apply_credit(%{
            "operation_id" => "op-order",
            "group_id" => "group-order",
            "occurred_on" => "2026-12-05",
            "amount_cents" => 3_000
          })
        )

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      data = json_response(get(conn, guest_credit_path("guest-order")), 200)["data"]

      assert Enum.map(data["lots"], & &1["source_operation_id"]) == [
               "cancel-src-sooner",
               "cancel-src-later"
             ]

      assert Enum.map(data["lots"], & &1["remaining_cents"]) == [2_500, 1_100]
      assert data["available_cents"] == 3_600
    end

    test "equal expiries consume by ascending source_operation_id", %{conn: conn} do
      {conn, _} =
        issue_credit(conn, %{
          group_id: "src-z",
          guest_id: "guest-eq",
          cash: 5_000,
          cancel_on: "2026-11-26"
        })

      {conn, _} =
        issue_credit(conn, %{
          group_id: "src-a",
          guest_id: "guest-eq",
          cash: 1_000,
          cancel_on: "2026-11-26"
        })

      open_target(conn, %{group_id: "group-eq", guest_id: "guest-eq"})

      conn =
        json_post(
          conn,
          apply_credit(%{
            "operation_id" => "op-eq",
            "group_id" => "group-eq",
            "occurred_on" => "2026-11-27",
            "amount_cents" => 500
          })
        )

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      data = json_response(get(conn, guest_credit_path("guest-eq")), 200)["data"]

      assert Enum.map(data["lots"], & &1["source_operation_id"]) == [
               "cancel-src-a",
               "cancel-src-z"
             ]

      assert Enum.map(data["lots"], & &1["remaining_cents"]) == [600, 5_500]
    end

    test "follows the revision contract and group errors", %{conn: conn} do
      {conn, _} = issue_credit(conn, %{})
      open_target(conn, %{})

      conn =
        json_post(
          conn,
          apply_credit(%{
            "group_id" => "group-target",
            "amount_cents" => 1_000,
            "expected_revision" => 1
          })
        )

      assert [%{"status" => "applied", "revision" => 2}] = json_response(conn, 200)["results"]

      conn =
        json_post(
          conn,
          apply_credit(%{
            "operation_id" => "op-apply-stale",
            "group_id" => "group-target",
            "amount_cents" => 1_000,
            "expected_revision" => 1
          })
        )

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-apply-stale",
                   "status" => "rejected",
                   "code" => "stale_revision",
                   "group_id" => "group-target",
                   "expected_revision" => 1,
                   "actual_revision" => 2
                 }
               ]
             }

      conn =
        json_post(
          conn,
          apply_credit(%{
            "operation_id" => "op-apply-ghost",
            "group_id" => "ghost",
            "amount_cents" => 1_000
          })
        )

      assert [%{"code" => "group_not_found"}] = json_response(conn, 200)["results"]

      conn =
        json_post(
          conn,
          apply_credit(%{
            "operation_id" => "op-apply-not-yet",
            "group_id" => "target-cancelled",
            "amount_cents" => 1_000
          })
        )

      assert [%{"code" => "group_not_found"}] = json_response(conn, 200)["results"]

      submit(conn, [open_group(%{"group_id" => "target-cancelled", "guest_id" => "guest-src"})])
      json_post(conn, cancel(%{"group_id" => "target-cancelled"}))

      conn =
        json_post(
          conn,
          apply_credit(%{
            "operation_id" => "op-apply-inactive",
            "group_id" => "target-cancelled",
            "amount_cents" => 1_000
          })
        )

      assert [%{"code" => "group_not_active"}] = json_response(conn, 200)["results"]
    end
  end

  describe "settling groups funded by credit" do
    test "refundable cancellation returns applied credit without a second bonus", %{conn: conn} do
      {conn, _} = issue_credit(conn, %{})
      open_target(conn, %{})

      conn =
        json_post(
          conn,
          apply_credit(%{
            "operation_id" => "op-apply-all",
            "group_id" => "group-target",
            "occurred_on" => "2026-10-10",
            "amount_cents" => 11_000
          })
        )

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      conn =
        json_post(conn, cancel(%{"operation_id" => "op-cancel-2", "group_id" => "group-target"}))

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "op-cancel-2",
                   "status" => "applied",
                   "group_id" => "group-target",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 0,
                   "revision" => 3
                 }
               ]
             }

      assert json_response(get(conn, guest_credit_path("guest-src")), 200) == %{
               "data" => %{
                 "guest_id" => "guest-src",
                 "available_cents" => 11_000,
                 "lots" => [
                   %{
                     "source_operation_id" => "cancel-group-src",
                     "remaining_cents" => 11_000,
                     "expires_on" => "2027-11-27"
                   }
                 ]
               }
             }

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["credit_liability_cents"] == 11_000
      assert ledger["cash_converted_to_credit_cents"] == 10_000
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_retained_cents"] == 0

      data = json_response(get(conn, groups_path("group-target")), 200)["data"]

      assert %{
               "status" => "cancelled",
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 11_000,
               "deposit_paid_cents" => 11_000
             } = data
    end

    test "credit restored after its expiry reduces the liability instead", %{conn: conn} do
      {conn, _} = issue_credit(conn, %{})

      conn =
        open_target(conn, %{
          group_id: "group-late",
          arrival_on: "2027-12-20",
          booked_on: "2026-10-03"
        })

      conn =
        json_post(
          conn,
          apply_credit(%{
            "operation_id" => "op-apply-late",
            "group_id" => "group-late",
            "occurred_on" => "2027-01-15",
            "amount_cents" => 11_000
          })
        )

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      # The lot expired on 2027-11-27. Cancelling on the expiry date is
      # refundable (more than 14 days before arrival), so the restored
      # amount expires immediately instead of becoming available again.
      conn =
        json_post(
          conn,
          cancel(%{
            "operation_id" => "op-cancel-late",
            "group_id" => "group-late",
            "occurred_on" => "2027-11-27"
          })
        )

      assert [%{"status" => "applied", "credit_issued_cents" => 0}] =
               json_response(conn, 200)["results"]

      assert json_response(get(conn, guest_credit_path("guest-src")), 200) == %{
               "data" => %{
                 "guest_id" => "guest-src",
                 "available_cents" => 0,
                 "lots" => []
               }
             }

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["credit_liability_cents"] == 0
      assert ledger["cash_converted_to_credit_cents"] == 10_000
    end

    test "non-refundable cancellation consumes applied credit", %{conn: conn} do
      {conn, _} = issue_credit(conn, %{})
      open_target(conn, %{})

      conn =
        json_post(
          conn,
          apply_credit(%{
            "operation_id" => "op-apply-late-2",
            "group_id" => "group-target",
            "occurred_on" => "2026-10-10",
            "amount_cents" => 11_000
          })
        )

      assert [%{"status" => "applied"}] = json_response(conn, 200)["results"]

      conn =
        json_post(
          conn,
          cancel(%{
            "operation_id" => "op-cancel-late-2",
            "group_id" => "group-target",
            "occurred_on" => "2026-12-01"
          })
        )

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 0}] =
               json_response(conn, 200)["results"]

      assert json_response(get(conn, guest_credit_path("guest-src")), 200) == %{
               "data" => %{
                 "guest_id" => "guest-src",
                 "available_cents" => 0,
                 "lots" => []
               }
             }

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["credit_liability_cents"] == 0

      data = json_response(get(conn, groups_path("group-target")), 200)["data"]

      assert %{
               "status" => "cancelled",
               "cash_paid_cents" => 0,
               "credit_paid_cents" => 11_000,
               "deposit_paid_cents" => 11_000
             } = data
    end

    test "mixed funding converts cash and restores credit on refundable hotel_credit", %{
      conn: conn
    } do
      {conn, _} = issue_credit(conn, %{guest_id: "guest-mix"})
      open_target(conn, %{group_id: "group-mix", guest_id: "guest-mix"})

      json_post(conn, payment(%{"group_id" => "group-mix", "amount_cents" => 10_000}))

      conn =
        json_post(
          conn,
          apply_credit(%{
            "operation_id" => "op-apply-mix",
            "group_id" => "group-mix",
            "occurred_on" => "2026-11-27",
            "amount_cents" => 5_000
          })
        )

      assert [%{"status" => "applied", "outstanding_deposit_cents" => 4_500}] =
               json_response(conn, 200)["results"]

      conn =
        json_post(
          conn,
          cancel(%{
            "operation_id" => "cancel-mix",
            "group_id" => "group-mix",
            "occurred_on" => "2026-11-26",
            "refund_method" => "hotel_credit"
          })
        )

      assert json_response(conn, 200) == %{
               "results" => [
                 %{
                   "operation_id" => "cancel-mix",
                   "status" => "applied",
                   "group_id" => "group-mix",
                   "refunded_cents" => 0,
                   "retained_cents" => 0,
                   "credit_issued_cents" => 11_000,
                   "revision" => 4
                 }
               ]
             }

      data = json_response(get(conn, guest_credit_path("guest-mix")), 200)["data"]

      assert Enum.map(data["lots"], & &1["source_operation_id"]) == [
               "cancel-group-src",
               "cancel-mix"
             ]

      assert Enum.map(data["lots"], & &1["remaining_cents"]) == [11_000, 11_000]
      assert data["available_cents"] == 22_000

      ledger = json_response(get(conn, "/api/v1/ledger"), 200)["data"]
      assert ledger["cash_converted_to_credit_cents"] == 20_000
      assert ledger["credit_liability_cents"] == 22_000
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_retained_cents"] == 0
    end
  end

  describe "guest credit reads" do
    test "an unknown guest has no credit", %{conn: conn} do
      assert json_response(get(conn, guest_credit_path("guest-nobody")), 200) == %{
               "data" => %{
                 "guest_id" => "guest-nobody",
                 "available_cents" => 0,
                 "lots" => []
               }
             }
    end

    test "reports expiry as of the on date", %{conn: conn} do
      {conn, _} = issue_credit(conn, %{})

      assert json_response(get(conn, guest_credit_path("guest-src") <> "?on=2027-11-26"), 200) ==
               %{
                 "data" => %{
                   "guest_id" => "guest-src",
                   "available_cents" => 11_000,
                   "lots" => [
                     %{
                       "source_operation_id" => "cancel-group-src",
                       "remaining_cents" => 11_000,
                       "expires_on" => "2027-11-27"
                     }
                   ]
                 }
               }

      assert json_response(get(conn, guest_credit_path("guest-src") <> "?on=2027-11-27"), 200) ==
               %{
                 "data" => %{
                   "guest_id" => "guest-src",
                   "available_cents" => 0,
                   "lots" => []
                 }
               }
    end

    test "rejects an unusable on date", %{conn: conn} do
      assert json_response(get(conn, guest_credit_path("guest-src") <> "?on=soon"), 422) ==
               %{"error" => %{"code" => "invalid_date"}}

      assert json_response(get(conn, guest_credit_path("guest-src") <> "?on=2026-02-30"), 422) ==
               %{"error" => %{"code" => "invalid_date"}}
    end
  end

  describe "ledger reads" do
    test "liability includes applied credit until the lot expires", %{conn: conn} do
      {conn, _} = issue_credit(conn, %{})
      open_target(conn, %{})

      json_post(conn, apply_credit(%{"group_id" => "group-target", "amount_cents" => 5_000}))

      on_day_before = json_response(get(conn, "/api/v1/ledger?on=2027-11-26"), 200)["data"]
      assert on_day_before["credit_liability_cents"] == 11_000

      on_expiry = json_response(get(conn, "/api/v1/ledger?on=2027-11-27"), 200)["data"]
      assert on_expiry["credit_liability_cents"] == 5_000
    end
  end
end
