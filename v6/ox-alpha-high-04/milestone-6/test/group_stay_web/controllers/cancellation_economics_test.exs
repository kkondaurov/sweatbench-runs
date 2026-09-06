defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: true

  import GroupStay.TestOperations

  defp d(days, base \\ ~D[2026-11-01]), do: base |> Date.add(days) |> Date.to_iso8601()

  defp submit(conn, operations) do
    post(conn, "/api/v1/partner-batches", batch(List.wrap(operations)))
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp get_data(conn, path) do
    conn
    |> get(path)
    |> json_response(200)
    |> Map.fetch!("data")
  end

  # Issues one lot worth 21450 to guest-22, from a fully-paid flexible group
  # cancelled on 2026-11-01 under the id "op-issue". Expires 2027-11-01.
  defp issue_lot(conn, op_id) do
    results =
      submit(conn, [
        open_group(),
        pay("group-81", 19500),
        cancel("group-81", "2026-11-01", %{
          "operation_id" => op_id,
          "refund_method" => "hotel_credit"
        })
      ])

    assert Enum.all?(results, &(&1["status"] == "applied"))
  end

  # A second active flexible group for guest-22 with a large enough deposit to
  # absorb credit applications.
  defp open_target(conn) do
    op =
      open_group(%{
        "operation_id" => "open-target",
        "group_id" => "group-target",
        "occurred_on" => "2026-10-20",
        "arrival_on" => "2027-01-10",
        "departure_on" => "2027-01-13",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 80000}]
      })

    submit(conn, [op])
  end

  ## Policy versions and refund windows

  describe "policy versions" do
    test "flexible groups booked before the cutoff use the 14-day window", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))

      data = get_data(conn, "/api/v1/groups/group-81")

      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2026-11-26"
    end

    test "flexible groups booked on the cutoff use the 30-day window", %{conn: conn} do
      op =
        open_group(%{
          "group_id" => "group-f30",
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-04-20",
          "departure_on" => "2027-04-22"
        })

      post(conn, "/api/v1/partner-batches", batch([op]))

      data = get_data(conn, "/api/v1/groups/group-f30")

      assert data["policy_version"] == "flex-30"
      assert data["refundable_until"] == "2027-03-21"
    end

    test "advance purchase groups are advance-nonrefundable with no refund date", %{conn: conn} do
      op = open_group(%{"group_id" => "group-ap", "rate_plan" => "advance_purchase"})
      post(conn, "/api/v1/partner-batches", batch([op]))

      data = get_data(conn, "/api/v1/groups/group-ap")

      assert data["policy_version"] == "advance-nonrefundable"
      assert data["refundable_until"] == nil
    end

    test "a flex-30 cancellation on the refundable date is refundable, a day later is not", %{
      conn: conn
    } do
      op = fn id ->
        # 3 nights at 10000 -> 30000 lodging -> 6000 flexible deposit.
        open_group(%{
          "operation_id" => id,
          "group_id" => id,
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-04-20",
          "departure_on" => "2027-04-23",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
        })
      end

      submit(conn, [op.("g-ok"), pay("g-ok", 6000)])
      results = submit(conn, cancel("g-ok", "2027-03-21"))

      assert [%{"status" => "applied", "refunded_cents" => 6000, "retained_cents" => 0}] =
               results

      submit(conn, [op.("g-late"), pay("g-late", 6000)])
      results = submit(conn, cancel("g-late", "2027-03-22"))

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 6000}] =
               results
    end

    test "rescheduling keeps the policy version and recomputes the refund date", %{conn: conn} do
      post(conn, "/api/v1/partner-batches", batch([open_group()]))

      conn = post(conn, "/api/v1/partner-batches", batch([reschedule("group-81", "2027-01-05")]))

      assert [
               %{
                 "status" => "applied",
                 "new_arrival_on" => "2027-01-05",
                 "new_departure_on" => "2027-01-08",
                 # Booked 2026-10-03, so the version stays flex-14 even though
                 # the moved stay reaches past the flex-30 cutoff.
                 "policy_version" => "flex-14",
                 # 2027-01-05 minus 14 days.
                 "refundable_until" => "2026-12-22",
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      conn = get(conn, "/api/v1/groups/group-81")

      assert %{"data" => %{"policy_version" => "flex-14", "refundable_until" => "2026-12-22"}} =
               json_response(conn, 200)
    end
  end

  ## Issuing credit on cancellation

  describe "issuing hotel credit on refundable cancellation" do
    test "converts the cash into a lot worth 110% with zero refund and retention", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 19500)])

      results =
        submit(
          conn,
          cancel("group-81", "2026-11-01", %{
            "operation_id" => "cancel-17",
            "refund_method" => "hotel_credit"
          })
        )

      assert [
               %{
                 "status" => "applied",
                 "group_id" => "group-81",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 21450,
                 "revision" => 3
               }
             ] = results

      assert get_data(conn, "/api/v1/groups/group-81")["status"] == "cancelled"

      assert get_data(conn, "/api/v1/ledger") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 19500,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 21450,
               "credit_shortfall_cents" => 0
             }
    end

    test "the lot carries the operation id and expires 365 days after cancellation", %{
      conn: conn
    } do
      submit(conn, [open_group(), pay("group-81", 19500)])

      submit(
        conn,
        cancel("group-81", "2026-11-01", %{
          "operation_id" => "cancel-17",
          "refund_method" => "hotel_credit"
        })
      )

      assert get_data(conn, "/api/v1/guests/guest-22/credit") == %{
               "guest_id" => "guest-22",
               "available_cents" => 21450,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-17",
                   "remaining_cents" => 21450,
                   "expires_on" => d(365)
                 }
               ]
             }
    end

    test "the bonus follows the standard rounding rule", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 145)])

      results =
        submit(conn, cancel("group-81", "2026-11-01", %{"refund_method" => "hotel_credit"}))

      # 10% of 145 is 14.5 cents, rounded upward to 15.
      assert [%{"status" => "applied", "credit_issued_cents" => 160}] = results
    end

    test "omitting refund_method settles in cash and reports credit_issued_cents zero", %{
      conn: conn
    } do
      submit(conn, [open_group(), pay("group-81", 19500)])

      results = submit(conn, cancel("group-81", "2026-11-01"))

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 19500,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] = results

      assert get_data(conn, "/api/v1/ledger")["cash_refunded_cents"] == 19500
      assert get_data(conn, "/api/v1/guests/guest-22/credit")["lots"] == []
    end

    test "an explicit null refund_method means cash", %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 19500)])

      results = submit(conn, cancel("group-81", "2026-11-01", %{"refund_method" => nil}))

      assert [%{"status" => "applied", "refunded_cents" => 19500}] = results
    end

    test "an unknown refund_method is an invalid operation", %{conn: conn} do
      submit(conn, [open_group()])

      results = submit(conn, cancel("group-81", "2026-11-01", %{"refund_method" => "points"}))

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] = results
    end

    test "hotel credit is refused for a non-refundable cancellation and the group stays active",
         %{conn: conn} do
      submit(conn, [open_group(), pay("group-81", 19500)])

      results =
        submit(conn, cancel("group-81", "2026-11-27", %{"refund_method" => "hotel_credit"}))

      assert [%{"status" => "rejected", "code" => "refund_method_not_available"}] = results

      data = get_data(conn, "/api/v1/groups/group-81")

      assert data["status"] == "active"
      assert data["revision"] == 2
      assert get_data(conn, "/api/v1/ledger")["cash_held_cents"] == 19500
    end

    test "hotel credit is refused for advance purchase groups", %{conn: conn} do
      submit(conn, [
        open_group(%{"group_id" => "group-ap", "rate_plan" => "advance_purchase"}),
        pay("group-ap", 100)
      ])

      results =
        submit(conn, cancel("group-ap", "2026-12-30", %{"refund_method" => "hotel_credit"}))

      assert [%{"status" => "rejected", "code" => "refund_method_not_available"}] = results
      assert get_data(conn, "/api/v1/groups/group-ap")["status"] == "active"
    end

    test "converting an unpaid deposit issues nothing", %{conn: conn} do
      submit(conn, [open_group()])

      results =
        submit(conn, cancel("group-81", "2026-11-01", %{"refund_method" => "hotel_credit"}))

      assert [%{"status" => "applied", "credit_issued_cents" => 0}] = results

      assert get_data(conn, "/api/v1/guests/guest-22/credit") == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }

      assert get_data(conn, "/api/v1/ledger")["credit_liability_cents"] == 0
    end
  end

  ## Applying credit

  describe "apply_hotel_credit" do
    test "redeems credit into the outstanding deposit and pauses its expiry", %{conn: conn} do
      issue_lot(conn, "op-issue")
      open_target(conn)

      results =
        submit(
          conn,
          apply_hotel_credit("group-target", 10000, %{"occurred_on" => "2026-11-02"})
        )

      assert [
               %{
                 "status" => "applied",
                 "group_id" => "group-target",
                 "amount_cents" => 10000,
                 "outstanding_deposit_cents" => 38000,
                 "revision" => 2
               }
             ] = results

      # Expiry pauses while the credit funds the group, so the liability does
      # not change; availability drops by the applied amount.
      assert get_data(conn, "/api/v1/ledger")["credit_liability_cents"] == 21450

      assert get_data(conn, "/api/v1/guests/guest-22/credit") == %{
               "guest_id" => "guest-22",
               "available_cents" => 11450,
               "lots" => [
                 %{
                   "source_operation_id" => "op-issue",
                   "remaining_cents" => 11450,
                   "expires_on" => d(365)
                 }
               ]
             }
    end

    test "consumes lots by earliest expiry, then by source operation id", %{conn: conn} do
      setup_tied_lots(conn)
      open_target(conn)

      assert get_data(conn, "/api/v1/guests/guest-22/credit")["lots"] ==
               [
                 %{
                   "source_operation_id" => "lot-early",
                   "remaining_cents" => 550,
                   "expires_on" => "2027-10-23"
                 },
                 %{
                   "source_operation_id" => "lot-bb",
                   "remaining_cents" => 550,
                   "expires_on" => "2027-11-01"
                 },
                 %{
                   "source_operation_id" => "lot-zz",
                   "remaining_cents" => 550,
                   "expires_on" => "2027-11-01"
                 }
               ]

      # 700 exhausts the earliest-expiry lot and dips into the lot whose
      # source operation id sorts first among the tied expiries.
      assert [%{"status" => "applied"}] =
               submit(
                 conn,
                 apply_hotel_credit("group-target", 700, %{"occurred_on" => "2026-11-02"})
               )

      assert get_data(conn, "/api/v1/guests/guest-22/credit")["lots"] ==
               [
                 %{
                   "source_operation_id" => "lot-bb",
                   "remaining_cents" => 400,
                   "expires_on" => "2027-11-01"
                 },
                 %{
                   "source_operation_id" => "lot-zz",
                   "remaining_cents" => 550,
                   "expires_on" => "2027-11-01"
                 }
               ]
    end

    test "rejects a request beyond the guest's unexpired credit", %{conn: conn} do
      issue_lot(conn, "op-issue")
      open_target(conn)

      # Equal to the outstanding deposit, so this trips on credit, not the cap.
      results = submit(conn, apply_hotel_credit("group-target", 48000))

      assert [%{"status" => "rejected", "code" => "insufficient_credit"}] = results

      data = get_data(conn, "/api/v1/groups/group-target")

      assert data["revision"] == 1
      assert data["credit_paid_cents"] == 0
      assert get_data(conn, "/api/v1/ledger")["credit_liability_cents"] == 21450
    end

    test "credit cannot exceed the outstanding deposit", %{conn: conn} do
      issue_lot(conn, "op-issue")
      open_target(conn)

      submit(conn, pay("group-target", 47990))

      results = submit(conn, apply_hotel_credit("group-target", 100))

      assert [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}] = results
    end

    test "inactive groups reject credit", %{conn: conn} do
      open_target(conn)
      submit(conn, [cancel("group-target", "2026-12-27")])

      results = submit(conn, apply_hotel_credit("group-target", 100))

      assert [%{"status" => "rejected", "code" => "group_not_active"}] = results
    end

    test "amount validation follows the existing payment errors", %{conn: conn} do
      open_target(conn)

      for bad <- [0, -1, 2.5, "100"] do
        assert [%{"status" => "rejected", "code" => "invalid_amount"}] =
                 submit(conn, apply_hotel_credit("group-target", bad))
      end

      results =
        submit(conn, [
          %{
            "type" => "apply_hotel_credit",
            "operation_id" => "op-x",
            "occurred_on" => "2026-11-01"
          }
        ])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] = results
    end

    test "follows the revision contract", %{conn: conn} do
      issue_lot(conn, "op-issue")
      open_target(conn)

      results =
        submit(conn, apply_hotel_credit("ghost", 100, %{"expected_revision" => 9}))

      assert [%{"status" => "rejected", "code" => "group_not_found"}] = results

      submit(conn, pay("group-target", 1000))

      results =
        submit(conn, apply_hotel_credit("group-target", 100, %{"expected_revision" => 1}))

      assert [%{"status" => "rejected", "code" => "stale_revision", "actual_revision" => 2}] =
               results

      results =
        submit(conn, apply_hotel_credit("group-target", 100, %{"expected_revision" => 2}))

      assert [%{"status" => "applied", "revision" => 3}] = results
    end

    # Three small lots for guest-22: one expiring earlier and two sharing an
    # expiry, ordered among themselves by source operation id.
    defp setup_tied_lots(conn) do
      specs = [
        {"glot-early", "lot-early", "2026-10-23", "2026-11-20"},
        {"glot-bb", "lot-bb", "2026-11-01", "2026-11-30"},
        {"glot-zz", "lot-zz", "2026-11-01", "2026-11-30"}
      ]

      for {group_id, op_id, cancelled_on, arrival_on} <- specs do
        # 2 nights at 1250 -> 2500 lodging -> 500 flexible deposit.
        open =
          open_group(%{
            "operation_id" => "open-" <> group_id,
            "group_id" => group_id,
            "arrival_on" => arrival_on,
            "departure_on" => Date.to_iso8601(Date.from_iso8601!(arrival_on) |> Date.add(2)),
            "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 1250}]
          })

        cancel_date = Date.from_iso8601!(cancelled_on)
        # Arrivals sit at least 14 days past every cancellation date here.
        pre_cancel = Date.to_iso8601(Date.add(cancel_date, -1))

        assert [%{"status" => "applied"}, %{"status" => "applied"}, %{"status" => "applied"}] =
                 submit(conn, [
                   open,
                   pay(group_id, 500, %{"occurred_on" => pre_cancel}),
                   cancel(group_id, cancelled_on, %{
                     "operation_id" => op_id,
                     "refund_method" => "hotel_credit"
                   })
                 ])
      end

      :ok
    end
  end

  ## Settling a group funded by credit

  describe "settling a group funded by credit" do
    test "a refundable cash cancellation restores applied credit with its original expiry", %{
      conn: conn
    } do
      issue_lot(conn, "op-issue")
      open_target(conn)

      submit(conn, [
        apply_hotel_credit("group-target", 5000, %{"occurred_on" => "2026-11-02"}),
        pay("group-target", 8000)
      ])

      results = submit(conn, cancel("group-target", "2026-11-20"))

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 8000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] = results

      # The full lot is available again with its original expiry — a second
      # bonus would have made it 23595 instead of 21450.
      assert get_data(conn, "/api/v1/guests/guest-22/credit") == %{
               "guest_id" => "guest-22",
               "available_cents" => 21450,
               "lots" => [
                 %{
                   "source_operation_id" => "op-issue",
                   "remaining_cents" => 21450,
                   "expires_on" => d(365)
                 }
               ]
             }

      assert get_data(conn, "/api/v1/ledger")["credit_liability_cents"] == 21450
    end

    test "a non-refundable cancellation retains cash and consumes applied credit", %{conn: conn} do
      issue_lot(conn, "op-issue")
      open_target(conn)

      submit(conn, [
        apply_hotel_credit("group-target", 5000, %{"occurred_on" => "2026-11-02"}),
        pay("group-target", 3000)
      ])

      results = submit(conn, cancel("group-target", "2027-01-03"))

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 3000,
                 "credit_issued_cents" => 0
               }
             ] = results

      # The consumed portion leaves the liability permanently.
      assert get_data(conn, "/api/v1/ledger") == %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 3000,
               "cash_converted_to_credit_cents" => 19500,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 16450,
               "credit_shortfall_cents" => 0
             }

      assert get_data(conn, "/api/v1/guests/guest-22/credit") == %{
               "guest_id" => "guest-22",
               "available_cents" => 16450,
               "lots" => [
                 %{
                   "source_operation_id" => "op-issue",
                   "remaining_cents" => 16450,
                   "expires_on" => d(365)
                 }
               ]
             }
    end

    test "mixed funding: refundable hotel-credit settlement converts cash and restores credit", %{
      conn: conn
    } do
      issue_lot(conn, "op-issue")
      open_target(conn)

      submit(conn, [
        apply_hotel_credit("group-target", 5000, %{"occurred_on" => "2026-11-02"}),
        pay("group-target", 9000)
      ])

      results =
        submit(
          conn,
          cancel("group-target", "2026-11-20", %{
            "operation_id" => "cancel-mix",
            "refund_method" => "hotel_credit"
          })
        )

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 9900
               }
             ] = results

      # Restored original lot plus the newly issued lot.
      assert get_data(conn, "/api/v1/guests/guest-22/credit") == %{
               "guest_id" => "guest-22",
               "available_cents" => 31350,
               "lots" => [
                 %{
                   "source_operation_id" => "op-issue",
                   "remaining_cents" => 21450,
                   "expires_on" => d(365)
                 },
                 %{
                   "source_operation_id" => "cancel-mix",
                   "remaining_cents" => 9900,
                   "expires_on" => d(365, ~D[2026-11-20])
                 }
               ]
             }

      assert get_data(conn, "/api/v1/ledger")["cash_converted_to_credit_cents"] == 28500
      assert get_data(conn, "/api/v1/ledger")["credit_liability_cents"] == 31350
    end

    test "restored credit already past its expiry reduces the liability immediately", %{
      conn: conn
    } do
      # Lot issued 2026-05-01 for guest-late, worth 1100, expiring 2027-05-01.
      submit(conn, [
        open_group(%{
          "operation_id" => "open-glot",
          "group_id" => "group-glot",
          "guest_id" => "guest-late",
          "occurred_on" => "2026-04-01",
          "arrival_on" => "2026-06-15",
          "departure_on" => "2026-06-17",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 2500}]
        }),
        pay("group-glot", 1000),
        cancel("group-glot", "2026-05-01", %{
          "operation_id" => "cancel-lot",
          "refund_method" => "hotel_credit"
        })
      ])

      # Fully redeemed into a group whose refundable cancellation lands after
      # the lot's expiry.
      submit(conn, [
        open_group(%{
          "operation_id" => "open-big",
          "group_id" => "group-big",
          "guest_id" => "guest-late",
          "occurred_on" => "2027-01-10",
          "arrival_on" => "2027-11-30",
          "departure_on" => "2027-12-03",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 50000}]
        }),
        apply_hotel_credit("group-big", 1100, %{
          "operation_id" => "op-fund",
          "occurred_on" => "2027-01-15"
        })
      ])

      assert get_data(conn, "/api/v1/ledger?on=2027-02-01")["credit_liability_cents"] == 1100

      results = submit(conn, cancel("group-big", "2027-07-01"))

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] = results

      # The restoration finds the expiry already past: nothing becomes
      # available again and the liability drops to zero.
      assert get_data(conn, "/api/v1/ledger?on=2027-02-01")["credit_liability_cents"] == 0

      assert get_data(conn, "/api/v1/guests/guest-late/credit?on=2027-01-01") == %{
               "guest_id" => "guest-late",
               "available_cents" => 0,
               "lots" => []
             }
    end
  end

  ## Credit and ledger reads

  describe "GET /api/v1/guests/:guest_id/credit" do
    test "starts empty for unknown guests", %{conn: conn} do
      assert get_data(conn, "/api/v1/guests/nobody/credit") == %{
               "guest_id" => "nobody",
               "available_cents" => 0,
               "lots" => []
             }
    end

    test "expiry is reported as of the optional on date", %{conn: conn} do
      issue_lot(conn, "op-issue")

      on_expiry_day = get_data(conn, "/api/v1/guests/guest-22/credit?on=#{d(365)}")
      assert on_expiry_day["available_cents"] == 21450
      assert length(on_expiry_day["lots"]) == 1

      day_after = get_data(conn, "/api/v1/guests/guest-22/credit?on=#{d(366)}")
      assert day_after == %{"guest_id" => "guest-22", "available_cents" => 0, "lots" => []}
    end

    test "exhausted lots are omitted", %{conn: conn} do
      issue_lot(conn, "op-issue")
      open_target(conn)

      submit(conn, apply_hotel_credit("group-target", 21450, %{"occurred_on" => "2026-11-02"}))

      assert get_data(conn, "/api/v1/guests/guest-22/credit") == %{
               "guest_id" => "guest-22",
               "available_cents" => 0,
               "lots" => []
             }
    end
  end

  describe "GET /api/v1/ledger" do
    test "the on parameter reports expiry as of that date", %{conn: conn} do
      today = Date.utc_today()
      cancelled_on = Date.add(today, -360)

      # Cancel a tiny flexible group today(-360); the lot of 132 expires in 5 days.
      submit(conn, [
        open_group(%{
          "operation_id" => "op-now",
          "group_id" => "group-now",
          "occurred_on" => Date.to_iso8601(cancelled_on),
          "arrival_on" => Date.to_iso8601(Date.add(cancelled_on, 40)),
          "departure_on" => Date.to_iso8601(Date.add(cancelled_on, 43)),
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 200}]
        }),
        pay("group-now", 120),
        cancel("group-now", Date.to_iso8601(cancelled_on), %{
          "operation_id" => "cancel-now",
          "refund_method" => "hotel_credit"
        })
      ])

      today_ledger = get_data(conn, "/api/v1/ledger")
      assert today_ledger["credit_liability_cents"] == 132
      assert today_ledger["cash_converted_to_credit_cents"] == 120

      after_expiry = get_data(conn, "/api/v1/ledger?on=#{Date.to_iso8601(Date.add(today, 6))}")
      assert after_expiry["credit_liability_cents"] == 0
      assert after_expiry["cash_converted_to_credit_cents"] == 120
    end
  end
end
