defmodule GroupStayWeb.Controllers.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase, async: false

  ## Builders

  defp pay(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "pay-" <> group_id <> "-" <> Integer.to_string(amount),
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-20",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  # Booked before 2027-01-01, so the 14-day window applies.
  defp open_flex14(group_id, overrides \\ %{}) do
    open_operation(
      Map.merge(
        %{"operation_id" => "open-" <> group_id, "group_id" => group_id},
        overrides
      )
    )
  end

  # Booked on or after 2027-01-01, so the 30-day window applies.
  defp open_flex30(group_id, overrides \\ %{}) do
    open_operation(
      Map.merge(
        %{
          "operation_id" => "open-" <> group_id,
          "group_id" => group_id,
          "occurred_on" => "2027-01-05",
          "arrival_on" => "2027-06-10",
          "departure_on" => "2027-06-13"
        },
        overrides
      )
    )
  end

  defp cancel(group_id, occurred_on, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "cancel-" <> group_id,
        "type" => "cancel_group",
        "occurred_on" => occurred_on,
        "group_id" => group_id
      },
      overrides
    )
  end

  defp apply_credit(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "apply-" <> group_id,
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-25",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  # Pays `cash` into a fresh flexible reservation booked on `cancelled_on` and
  # cancels it refundably with hotel credit selected, leaving the guest with a
  # credit lot worth 110% of the cash issued by operation `op_id`.
  defp issue_lot(conn, guest_id, group_id, op_id, cancelled_on, cash) do
    arrival = cancelled_on |> to_date() |> Date.add(90) |> Date.to_iso8601()
    departure = cancelled_on |> to_date() |> Date.add(93) |> Date.to_iso8601()

    run_batch(conn, [
      open_operation(%{
        "operation_id" => "open-" <> group_id,
        "group_id" => group_id,
        "guest_id" => guest_id,
        "occurred_on" => cancelled_on,
        "arrival_on" => arrival,
        "departure_on" => departure,
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      }),
      pay(group_id, cash, %{"occurred_on" => cancelled_on}),
      cancel(group_id, cancelled_on, %{
        "operation_id" => op_id,
        "refund_method" => "hotel_credit"
      })
    ])
  end

  defp to_date(iso), do: Date.from_iso8601!(iso)

  ## Readers

  defp fetch_guest_credit(conn, guest_id, on \\ nil) do
    query = if on, do: "?on=#{on}", else: ""

    response =
      get(conn, "/api/v1/guests/#{URI.encode_www_form(guest_id)}/credit#{query}")

    assert %{"data" => data} = json_response(response, 200)
    data
  end

  defp fetch_ledger_as_of(conn, on) do
    assert %{"data" => ledger} = get(conn, "/api/v1/ledger?on=#{on}") |> json_response(200)
    ledger
  end

  describe "policy versions" do
    test "flexible groups keep the 14-day window when booked before the cutoff", %{conn: conn} do
      run_batch(conn, [open_flex14("group-81")])

      assert %{
               "booked_on" => "2026-10-03",
               "policy_version" => "flex-14",
               "refundable_until" => "2026-11-26"
             } = fetch_group(conn, "group-81")
    end

    test "flexible groups booked on the cutoff use the 30-day window", %{conn: conn} do
      run_batch(conn, [open_flex30("group-81")])

      assert %{
               "booked_on" => "2027-01-05",
               "policy_version" => "flex-30",
               "refundable_until" => "2027-05-11"
             } = fetch_group(conn, "group-81")
    end

    test "advance purchase groups are non-refundable with a null refundable date", %{conn: conn} do
      run_batch(conn, [open_flex14("group-81", %{"rate_plan" => "advance_purchase"})])

      assert %{
               "policy_version" => "advance-nonrefundable",
               "refundable_until" => nil
             } = fetch_group(conn, "group-81")
    end

    test "cancellation on the refundable date refunds; one day later retains", %{conn: conn} do
      run_batch(conn, [
        open_flex30("g-in", %{"arrival_on" => "2027-05-10", "departure_on" => "2027-05-13"}),
        pay("g-in", 5_000),
        open_flex30("g-out", %{
          "arrival_on" => "2027-05-10",
          "departure_on" => "2027-05-13"
        }),
        pay("g-out", 5_000)
      ])

      assert [%{"status" => "applied", "refunded_cents" => 5_000, "retained_cents" => 0}] =
               run_batch(conn, [cancel("g-in", "2027-04-10")])

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 5_000}] =
               run_batch(conn, [cancel("g-out", "2027-04-11")])
    end

    test "rescheduling keeps the policy version and recomputes refundable_until", %{conn: conn} do
      run_batch(conn, [open_flex14("group-81"), pay("group-81", 1_000)])

      move = %{
        "operation_id" => "op-move",
        "type" => "reschedule_group",
        "occurred_on" => "2026-11-20",
        "group_id" => "group-81",
        "new_arrival_on" => "2026-12-24"
      }

      assert [
               %{
                 "status" => "applied",
                 "new_arrival_on" => "2026-12-24",
                 "new_departure_on" => "2026-12-27",
                 "policy_version" => "flex-14",
                 "refundable_until" => "2026-12-10",
                 "revision" => 3
               }
             ] = run_batch(conn, [move])

      assert %{"policy_version" => "flex-14", "refundable_until" => "2026-12-10"} =
               fetch_group(conn, "group-81")

      # The fixed policy is evaluated against the new arrival.
      assert [%{"status" => "applied", "refunded_cents" => 1_000}] =
               run_batch(conn, [cancel("group-81", "2026-11-27")])
    end
  end

  describe "issuing credit on cancellation" do
    test "converts refundable cash into a credit lot worth 110%, rounded half up", %{conn: conn} do
      results =
        run_batch(conn, [
          open_flex14("g-hc"),
          pay("g-hc", 5_555),
          cancel("g-hc", "2026-11-01", %{
            "operation_id" => "cancel-hc",
            "refund_method" => "hotel_credit"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "group_id" => "g-hc",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 6_111,
                 "revision" => 3
               }
             ] = results

      # 10% of 5555 is 555.5, which rounds up to 556: the lot is worth 6111.
      assert %{
               "guest_id" => "guest-22",
               "available_cents" => 6_111,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-hc",
                   "remaining_cents" => 6_111,
                   "expires_on" => "2027-11-02"
                 }
               ]
             } = fetch_guest_credit(conn, "guest-22")

      assert_ledger(conn,
        cash_held_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 5_555,
        credit_liability_cents: 6_111
      )
    end

    test "an exact half-cent bonus rounds upward", %{conn: conn} do
      issue_lot(conn, "guest-22", "g-tiny", "cancel-g-tiny", "2026-11-01", 25)

      assert %{"available_cents" => 28} = fetch_guest_credit(conn, "guest-22")
    end

    test "credit is available through 365 days after cancellation and expires the next day", %{
      conn: conn
    } do
      issue_lot(conn, "guest-22", "g-exp", "cancel-g-exp", "2026-11-01", 5_000)

      assert %{"available_cents" => 5_500} = fetch_guest_credit(conn, "guest-22", "2027-11-01")

      assert %{"available_cents" => 0, "lots" => []} =
               fetch_guest_credit(conn, "guest-22", "2027-11-02")

      assert %{"credit_liability_cents" => 5_500} = fetch_ledger_as_of(conn, "2027-11-01")
      assert %{"credit_liability_cents" => 0} = fetch_ledger_as_of(conn, "2027-11-02")
    end

    test "hotel credit is not available for a non-refundable cancellation", %{conn: conn} do
      run_batch(conn, [
        open_flex14("g-nr", %{"rate_plan" => "advance_purchase"}),
        pay("g-nr", 45_000)
      ])

      assert [%{"status" => "rejected", "code" => "refund_method_not_available"}] =
               run_batch(conn, [
                 cancel("g-nr", "2026-10-04", %{"refund_method" => "hotel_credit"})
               ])

      group = fetch_group(conn, "g-nr")
      assert group["status"] == "active"
      assert group["deposit_paid_cents"] == 45_000
      assert group["cash_paid_cents"] == 45_000
      assert group["revision"] == 2

      assert %{"available_cents" => 0, "lots" => []} = fetch_guest_credit(conn, "guest-22")

      assert_ledger(conn,
        cash_held_cents: 45_000,
        cash_converted_to_credit_cents: 0,
        credit_liability_cents: 0
      )
    end

    test "an unknown refund method is rejected and leaves the group active", %{conn: conn} do
      run_batch(conn, [open_flex14("group-81"), pay("group-81", 1_000)])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               run_batch(conn, [
                 cancel("group-81", "2026-11-26", %{"refund_method" => "store_credit"})
               ])

      assert fetch_group(conn, "group-81")["status"] == "active"
      assert fetch_group(conn, "group-81")["revision"] == 2
    end

    test "omitting refund_method keeps the historical cash behavior", %{conn: conn} do
      run_batch(conn, [open_flex14("group-81"), pay("group-81", 5_000)])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 5_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] = run_batch(conn, [cancel("group-81", "2026-11-26")])

      assert %{"available_cents" => 0, "lots" => []} = fetch_guest_credit(conn, "guest-22")

      assert_ledger(conn, cash_refunded_cents: 5_000, cash_converted_to_credit_cents: 0)
    end

    test "an explicit cash refund method behaves like an omitted one", %{conn: conn} do
      run_batch(conn, [open_flex14("group-81"), pay("group-81", 5_000)])

      assert [%{"status" => "applied", "refunded_cents" => 5_000}] =
               run_batch(conn, [
                 cancel("group-81", "2026-11-26", %{"refund_method" => "cash"})
               ])
    end

    test "a refundable cancellation without any cash issues no lot", %{conn: conn} do
      run_batch(conn, [open_flex14("group-81")])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] =
               run_batch(conn, [
                 cancel("group-81", "2026-11-26", %{"refund_method" => "hotel_credit"})
               ])

      assert %{"available_cents" => 0, "lots" => []} = fetch_guest_credit(conn, "guest-22")

      assert_ledger(conn,
        cash_converted_to_credit_cents: 0,
        credit_liability_cents: 0
      )
    end
  end

  describe "applying hotel credit" do
    test "redeems credit into the outstanding deposit and reports the new state", %{conn: conn} do
      issue_lot(conn, "guest-22", "g-src", "cancel-g-src", "2026-09-01", 5_000)
      run_batch(conn, [open_flex14("g-dst", %{"occurred_on" => "2026-09-20"})])

      assert [
               %{
                 "status" => "applied",
                 "group_id" => "g-dst",
                 "amount_cents" => 2_000,
                 "outstanding_deposit_cents" => 17_500,
                 "revision" => 2
               }
             ] =
               run_batch(conn, [
                 apply_credit("g-dst", 2_000, %{"occurred_on" => "2026-09-25"})
               ])

      group = fetch_group(conn, "g-dst")
      assert group["deposit_paid_cents"] == 2_000
      assert group["cash_paid_cents"] == 0
      assert group["credit_paid_cents"] == 2_000
      assert group["outstanding_deposit_cents"] == 17_500

      # Applying moves credit from available to applied-to-active: the liability
      # is unchanged.
      assert %{
               "available_cents" => 3_500,
               "lots" => [
                 %{"remaining_cents" => 3_500, "source_operation_id" => "cancel-g-src"}
               ]
             } = fetch_guest_credit(conn, "guest-22")

      assert_ledger(conn,
        cash_converted_to_credit_cents: 5_000,
        credit_liability_cents: 5_500
      )
    end

    test "consumes lots by earliest expiry, then by source operation id", %{conn: conn} do
      # Expiries: the two tie lots expire first (equal, so their operation ids
      # decide), then the middle lot, then the late lot.
      issue_lot(conn, "guest-fifo", "g-late", "cancel-late", "2026-09-01", 5_000)
      issue_lot(conn, "guest-fifo", "g-mid", "cancel-mid", "2026-08-20", 5_000)
      issue_lot(conn, "guest-fifo", "g-tie-z", "zzz-tie", "2026-08-15", 1_000)
      issue_lot(conn, "guest-fifo", "g-tie-a", "aaa-tie", "2026-08-15", 1_000)

      assert %{"lots" => lots_before} = fetch_guest_credit(conn, "guest-fifo", "2026-09-02")

      assert Enum.map(lots_before, &{&1["expires_on"], &1["source_operation_id"]}) == [
               {"2027-08-16", "aaa-tie"},
               {"2027-08-16", "zzz-tie"},
               {"2027-08-21", "cancel-mid"},
               {"2027-09-02", "cancel-late"}
             ]

      run_batch(conn, [
        open_flex14("g-spend", %{
          "guest_id" => "guest-fifo",
          "occurred_on" => "2026-09-10",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 40_000}]
        })
      ])

      assert [%{"status" => "applied"}] =
               run_batch(conn, [
                 apply_credit("g-spend", 6_600, %{"occurred_on" => "2026-09-11"})
               ])

      assert %{"available_cents" => 6_600, "lots" => lots_after} =
               fetch_guest_credit(conn, "guest-fifo", "2026-09-12")

      # 6600 consumed: 1100 from each same-expiry lot in operation-id order,
      # then 4400 from the earliest-expiring remaining lot.
      assert Enum.map(lots_after, &{&1["source_operation_id"], &1["remaining_cents"]}) == [
               {"cancel-mid", 1_100},
               {"cancel-late", 5_500}
             ]
    end

    test "rejects with insufficient_credit when the guest cannot cover the amount", %{
      conn: conn
    } do
      issue_lot(conn, "guest-22", "g-src", "cancel-g-src", "2026-09-01", 5_000)
      run_batch(conn, [open_flex14("g-dst", %{"occurred_on" => "2026-09-20"})])

      assert [%{"status" => "rejected", "code" => "insufficient_credit"}] =
               run_batch(conn, [
                 apply_credit("g-dst", 5_501, %{"occurred_on" => "2026-09-25"})
               ])

      assert fetch_group(conn, "g-dst")["revision"] == 1
      assert fetch_group(conn, "g-dst")["credit_paid_cents"] == 0
    end

    test "credit cannot exceed the outstanding deposit", %{conn: conn} do
      issue_lot(conn, "guest-22", "g-src", "cancel-g-src", "2026-09-01", 10_000)

      run_batch(conn, [
        open_flex14("g-dst", %{
          "occurred_on" => "2026-09-20",
          "arrival_on" => "2026-12-10",
          "departure_on" => "2026-12-11",
          "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
        })
      ])

      assert [%{"status" => "rejected", "code" => "payment_exceeds_outstanding"}] =
               run_batch(conn, [
                 apply_credit("g-dst", 3_001, %{"occurred_on" => "2026-09-25"})
               ])

      assert fetch_group(conn, "g-dst")["revision"] == 1
    end

    test "rejects unusable amounts with invalid_amount", %{conn: conn} do
      run_batch(conn, [open_flex14("g-dst")])

      for {amount, index} <- Enum.with_index([0, -1, 1.5, "100", nil]) do
        assert [%{"status" => "rejected", "code" => "invalid_amount"}] =
                 run_batch(conn, [
                   apply_credit("g-dst", amount, %{"operation_id" => "apply-bad-#{index}"})
                 ])
      end

      assert fetch_group(conn, "g-dst")["revision"] == 1
    end

    test "uses the existing group errors for missing and inactive groups", %{conn: conn} do
      run_batch(conn, [open_flex14("group-81"), cancel("group-81", "2026-11-26")])

      assert [%{"status" => "rejected", "code" => "group_not_found"}] =
               run_batch(conn, [apply_credit("ghost", 100)])

      assert [%{"status" => "rejected", "code" => "group_not_active"}] =
               run_batch(conn, [apply_credit("group-81", 100)])
    end

    test "evaluates expiry using the operation date, not the current date", %{conn: conn} do
      # The lot is usable through 2100-06-01; the application on 2100-05-31 must
      # succeed regardless of the current date.
      issue_lot(conn, "guest-old", "g-src", "cancel-g-src", "2099-06-01", 1_000)

      run_batch(conn, [
        open_flex14("g-dst", %{
          "guest_id" => "guest-old",
          "occurred_on" => "2100-05-31",
          "arrival_on" => "2100-07-01",
          "departure_on" => "2100-07-03"
        }),
        apply_credit("g-dst", 1_100, %{"occurred_on" => "2100-05-31"})
      ])

      assert fetch_group(conn, "g-dst")["credit_paid_cents"] == 1_100
    end

    test "follows the revision contract", %{conn: conn} do
      issue_lot(conn, "guest-22", "g-src", "cancel-g-src", "2026-09-01", 5_000)
      run_batch(conn, [open_flex14("g-dst", %{"occurred_on" => "2026-09-20"})])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "g-dst",
                 "expected_revision" => 2,
                 "actual_revision" => 1
               }
             ] =
               run_batch(conn, [
                 apply_credit("g-dst", 999_999, %{"expected_revision" => 2})
               ])

      assert [%{"status" => "applied", "revision" => 2}] =
               run_batch(conn, [
                 apply_credit("g-dst", 1_000, %{
                   "operation_id" => "apply-g-dst-ok",
                   "expected_revision" => 1
                 })
               ])
    end
  end

  describe "settling a group funded by credit" do
    test "a refundable cash settlement refunds the cash and restores applied credit unchanged", %{
      conn: conn
    } do
      issue_lot(conn, "guest-22", "g-src", "cancel-g-src", "2026-09-01", 5_000)

      run_batch(conn, [
        open_flex14("g-mix"),
        pay("g-mix", 8_000),
        apply_credit("g-mix", 5_000)
      ])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 8_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ] =
               run_batch(conn, [cancel("g-mix", "2026-11-26", %{"refund_method" => "cash"})])

      # The restored lot kept its original expiry and received no second bonus.
      assert %{
               "available_cents" => 5_500,
               "lots" => [
                 %{
                   "source_operation_id" => "cancel-g-src",
                   "remaining_cents" => 5_500,
                   "expires_on" => "2027-09-02"
                 }
               ]
             } = fetch_guest_credit(conn, "guest-22")

      assert_ledger(conn,
        cash_held_cents: 0,
        cash_refunded_cents: 8_000,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 5_000,
        credit_liability_cents: 5_500
      )
    end

    test "a refundable hotel-credit settlement converts only the cash portion", %{conn: conn} do
      issue_lot(conn, "guest-22", "g-src", "cancel-g-src", "2026-09-01", 5_000)

      run_batch(conn, [
        open_flex14("g-mix"),
        pay("g-mix", 8_000),
        apply_credit("g-mix", 5_000)
      ])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 8_800,
                 "revision" => 4
               }
             ] =
               run_batch(conn, [
                 cancel("g-mix", "2026-11-26", %{
                   "operation_id" => "cancel-g-mix",
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert %{"lots" => lots} = fetch_guest_credit(conn, "guest-22")

      # The applied credit returned to its original lot with its original expiry;
      # the cash became one new lot with the 10% bonus.
      assert Enum.map(lots, &{&1["source_operation_id"], &1["remaining_cents"]}) == [
               {"cancel-g-src", 5_500},
               {"cancel-g-mix", 8_800}
             ]

      assert_ledger(conn,
        cash_held_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 13_000,
        credit_liability_cents: 14_300
      )
    end

    test "a non-refundable cancellation retains cash and consumes applied credit", %{conn: conn} do
      issue_lot(conn, "guest-22", "g-src", "cancel-g-src", "2026-09-01", 5_000)

      run_batch(conn, [
        open_flex14("g-nr", %{"rate_plan" => "advance_purchase"}),
        pay("g-nr", 20_000),
        apply_credit("g-nr", 5_000)
      ])

      assert_ledger(conn,
        cash_held_cents: 20_000,
        cash_converted_to_credit_cents: 5_000,
        credit_liability_cents: 5_500
      )

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 20_000,
                 "credit_issued_cents" => 0
               }
             ] = run_batch(conn, [cancel("g-nr", "2026-10-26")])

      assert %{
               "available_cents" => 500,
               "lots" => [
                 %{"source_operation_id" => "cancel-g-src", "remaining_cents" => 500}
               ]
             } = fetch_guest_credit(conn, "guest-22", "2026-09-02")

      assert_ledger(conn,
        cash_held_cents: 0,
        cash_retained_cents: 20_000,
        cash_converted_to_credit_cents: 5_000,
        credit_liability_cents: 500
      )
    end

    test "restored credit whose expiry has already passed expires immediately", %{conn: conn} do
      # Lot of 5500 issued 2026-09-01, expiring 2027-09-02.
      issue_lot(conn, "guest-old", "g-src", "cancel-g-src", "2026-09-01", 5_000)

      run_batch(conn, [
        open_flex14("g-dst", %{
          "guest_id" => "guest-old",
          "occurred_on" => "2027-03-01",
          "arrival_on" => "2028-06-10",
          "departure_on" => "2028-06-13"
        })
      ])

      assert [%{"status" => "applied"}] =
               run_batch(conn, [
                 apply_credit("g-dst", 5_000, %{"occurred_on" => "2027-03-01"})
               ])

      # While funding the active group the credit stays liable even past its own
      # expiry; only the unapplied remainder follows the calendar.
      assert_ledger(conn,
        cash_converted_to_credit_cents: 5_000,
        credit_liability_cents: 5_500
      )

      assert %{"credit_liability_cents" => 5_000} = fetch_ledger_as_of(conn, "2027-10-01")

      assert %{"available_cents" => 0, "lots" => []} =
               fetch_guest_credit(conn, "guest-old", "2027-10-01")

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] =
               run_batch(conn, [
                 cancel("g-dst", "2028-01-10", %{"refund_method" => "hotel_credit"})
               ])

      # On restoration the original expiry had already passed, so the restored
      # amount reduced the liability instead of becoming available again. Only
      # the never-applied remainder (itself expired by then) is left on later
      # dates, while reads dated before its expiry still see it.
      assert %{"credit_liability_cents" => 0} = fetch_ledger_as_of(conn, "2028-01-10")

      assert %{"available_cents" => 0, "lots" => []} =
               fetch_guest_credit(conn, "guest-old", "2028-01-10")

      assert %{"credit_liability_cents" => 500} = fetch_ledger_as_of(conn, "2027-06-01")
    end
  end

  describe "batch processing with credit operations" do
    test "operations observe earlier operations and revisions chain through credit", %{conn: conn} do
      results =
        run_batch(conn, [
          open_flex14("g-one", %{"operation_id" => "op-1"}),
          pay("g-one", 10_000, %{"operation_id" => "op-2"}),
          cancel("g-one", "2026-11-26", %{
            "operation_id" => "op-3",
            "refund_method" => "hotel_credit",
            "expected_revision" => 2
          }),
          open_flex14("g-two", %{"operation_id" => "op-4"}),
          apply_credit("g-two", 11_000, %{
            "operation_id" => "op-5",
            "expected_revision" => 1
          })
        ])

      assert [
               %{"operation_id" => "op-1", "status" => "applied", "revision" => 1},
               %{"operation_id" => "op-2", "status" => "applied", "revision" => 2},
               %{
                 "operation_id" => "op-3",
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 11_000,
                 "revision" => 3
               },
               %{"operation_id" => "op-4", "status" => "applied"},
               %{
                 "operation_id" => "op-5",
                 "status" => "applied",
                 "outstanding_deposit_cents" => 8_500,
                 "revision" => 2
               }
             ] = results

      assert %{"credit_paid_cents" => 11_000, "deposit_paid_cents" => 11_000} =
               fetch_group(conn, "g-two")

      assert_ledger(conn,
        cash_held_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 10_000,
        credit_liability_cents: 11_000
      )
    end

    test "an unknown credit operation type is rejected like any other", %{conn: conn} do
      run_batch(conn, [open_flex14("group-81")])

      assert [%{"status" => "rejected", "code" => "invalid_operation"}] =
               run_batch(conn, [
                 %{
                   "operation_id" => "op-grant",
                   "type" => "grant_hotel_credit",
                   "group_id" => "group-81",
                   "amount_cents" => 1_000
                 }
               ])
    end
  end

  describe "guest credit endpoint" do
    test "returns zeros for a guest without credit", %{conn: conn} do
      assert %{
               "guest_id" => "nobody",
               "available_cents" => 0,
               "lots" => []
             } = fetch_guest_credit(conn, "nobody")
    end

    test "orders lots by expiry and then by source operation id", %{conn: conn} do
      issue_lot(conn, "guest-order", "g-second", "cancel-g-second", "2099-01-02", 1_000)
      issue_lot(conn, "guest-order", "g-first", "cancel-g-first", "2099-01-01", 1_000)
      issue_lot(conn, "guest-order", "g-tie-z", "zzz-cancel", "2099-01-01", 1_000)
      issue_lot(conn, "guest-order", "g-tie-a", "aaa-cancel", "2099-01-01", 1_000)

      assert %{"lots" => lots} = fetch_guest_credit(conn, "guest-order", "2099-01-03")

      assert Enum.map(lots, &{&1["expires_on"], &1["source_operation_id"]}) == [
               {"2100-01-02", "aaa-cancel"},
               {"2100-01-02", "cancel-g-first"},
               {"2100-01-02", "zzz-cancel"},
               {"2100-01-03", "cancel-g-second"}
             ]

      assert %{"available_cents" => 4_400} = fetch_guest_credit(conn, "guest-order")
    end

    test "reports expiry as of the requested date", %{conn: conn} do
      issue_lot(conn, "guest-on", "g-src", "cancel-g-src", "2026-11-01", 1_000)

      assert %{"available_cents" => 1_100} = fetch_guest_credit(conn, "guest-on", "2026-12-31")
      assert %{"available_cents" => 1_100} = fetch_guest_credit(conn, "guest-on", "2027-11-01")
      assert %{"available_cents" => 0} = fetch_guest_credit(conn, "guest-on", "2027-11-02")

      # Without the parameter the current UTC date decides, and the lot is far
      # from expiry.
      assert %{"available_cents" => 1_100} = fetch_guest_credit(conn, "guest-on")
    end

    test "rejects unparsable on dates", %{conn: conn} do
      for path <- ["/api/v1/ledger?on=not-a-date", "/api/v1/guests/g/credit?on=13/13/2026"] do
        response = get(conn, path)
        assert json_response(response, 422) == %{"error" => %{"code" => "invalid_date"}}
      end
    end
  end

  defp assert_ledger(conn, expectations) do
    assert fetch_ledger(conn) ==
             Map.merge(
               %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "credit_liability_cents" => 0
               },
               Map.new(expectations, fn {k, v} -> {Atom.to_string(k), v} end)
             )
  end
end
