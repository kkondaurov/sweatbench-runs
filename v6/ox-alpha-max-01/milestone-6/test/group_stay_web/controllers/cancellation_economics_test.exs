defmodule GroupStayWeb.CancellationEconomicsTest do
  use GroupStayWeb.ConnCase

  # The default group stays: booked 2026-10-03, arrival 2026-12-10.
  @issue_cancel_on "2026-11-20"
  # A cancellation on 2026-11-20 is available through 2027-11-20 and expires
  # the following day.
  @issued_lot_expiry "2027-11-21"

  defp issue_standard_lot(conn, opts \\ []) do
    group_id = Keyword.get(opts, :group_id, "group-81")
    guest_id = Keyword.get(opts, :guest_id, "guest-22")
    cash = Keyword.get(opts, :cash, 6000)
    op_id = Keyword.get(opts, :operation_id, "op-cancel")

    conn =
      post_operations(conn, [
        open_operation(%{"group_id" => group_id, "guest_id" => guest_id}),
        payment_operation(group_id, cash),
        cancel_operation(group_id, %{
          "operation_id" => op_id,
          "occurred_on" => @issue_cancel_on,
          "refund_method" => "hotel_credit"
        })
      ])

    expected_credit = Keyword.get(opts, :credit_issued, round(cash * 1.1))

    assert [
             %{"status" => "applied"},
             %{"status" => "applied"},
             %{
               "status" => "applied",
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "credit_issued_cents" => ^expected_credit,
               "revision" => 3
             }
           ] = json_response(conn, 200)["results"]

    conn
  end

  defp guest_credit(conn, guest_id, on \\ nil) do
    query = if on, do: [on: on], else: []
    conn |> get_guest_credit(guest_id, query) |> json_response(200) |> Map.fetch!("data")
  end

  defp ledger_data(conn, on \\ nil) do
    query = if on, do: [on: on], else: []
    conn |> get_ledger(query) |> json_response(200) |> Map.fetch!("data")
  end

  describe "issuing hotel credit on cancellation" do
    test "converts refundable cash into a credit lot worth 110% of the cash", %{conn: conn} do
      conn = issue_standard_lot(conn)

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "revision" => 3,
                 "deposit_paid_cents" => 0,
                 "outstanding_deposit_cents" => 0,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             } = get_group(conn, "group-81") |> json_response(200)

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 6000,
               "credit_liability_cents" => 6600
             } = ledger_data(conn)

      assert %{
               "guest_id" => "guest-22",
               "available_cents" => 6600,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel",
                   "remaining_cents" => 6600,
                   "expires_on" => @issued_lot_expiry
                 }
               ]
             } = guest_credit(conn, "guest-22")
    end

    test "rounds the 10% bonus half-up on the converted cash", %{conn: conn} do
      conn = issue_standard_lot(conn, cash: 5, credit_issued: 6)

      assert %{"available_cents" => 6} = guest_credit(conn, "guest-22")

      # An exact half-cent of bonus rounds upward: 5 cents -> 5.5 -> 6.
      conn =
        post_operations(conn, [
          open_operation(%{"group_id" => "odd-group", "guest_id" => "odd-guest"}),
          payment_operation("odd-group", 15),
          cancel_operation("odd-group", %{
            "operation_id" => "op-cancel-odd",
            "occurred_on" => @issue_cancel_on,
            "refund_method" => "hotel_credit"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "credit_issued_cents" => 17}
             ] = json_response(conn, 200)["results"]

      assert %{"available_cents" => 17} = guest_credit(conn, "odd-guest")
    end

    test "issues no lot when no cash was paid", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          cancel_operation("group-81", %{
            "occurred_on" => @issue_cancel_on,
            "refund_method" => "hotel_credit"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "credit_issued_cents" => 0,
                 "refunded_cents" => 0,
                 "retained_cents" => 0
               }
             ] = json_response(conn, 200)["results"]

      assert %{"available_cents" => 0, "lots" => []} = guest_credit(conn, "guest-22")

      assert %{
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             } = ledger_data(conn)
    end

    test "rejects hotel credit for non-refundable cancellations and leaves the group active", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 6000),
          open_operation(%{
            "group_id" => "advance-group",
            "rate_plan" => "advance_purchase",
            "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 9000}]
          }),
          payment_operation("advance-group", 27_000)
        ])

      assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

      conn =
        post_operations(conn, [
          # Flexible cancelled inside its 14-day window.
          cancel_operation("group-81", %{
            "occurred_on" => "2026-11-27",
            "refund_method" => "hotel_credit"
          }),
          # Advance purchase is never refundable.
          cancel_operation("advance-group", %{
            "operation_id" => "op-cancel-advance",
            "occurred_on" => "2026-10-05",
            "refund_method" => "hotel_credit"
          })
        ])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "refund_method_not_available",
                 "group_id" => "group-81"
               },
               %{
                 "status" => "rejected",
                 "code" => "refund_method_not_available",
                 "group_id" => "advance-group"
               }
             ] = json_response(conn, 200)["results"]

      assert %{"data" => %{"status" => "active", "revision" => 2}} =
               get_group(conn, "group-81") |> json_response(200)

      assert %{"data" => %{"status" => "active", "revision" => 2}} =
               get_group(conn, "advance-group") |> json_response(200)

      assert %{
               "cash_held_cents" => 33_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             } = ledger_data(conn)

      assert %{"available_cents" => 0, "lots" => []} = guest_credit(conn, "guest-22")
    end

    test "omitting refund_method keeps refunding cash", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 6000),
          cancel_operation("group-81", %{"occurred_on" => @issue_cancel_on})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "refunded_cents" => 6000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] = json_response(conn, 200)["results"]

      assert %{
               "cash_refunded_cents" => 6000,
               "cash_converted_to_credit_cents" => 0,
               "credit_liability_cents" => 0
             } = ledger_data(conn)

      assert %{"available_cents" => 0, "lots" => []} = guest_credit(conn, "guest-22")
    end

    test "an unknown refund_method is an invalid operation", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 6000),
          cancel_operation("group-81", %{
            "occurred_on" => @issue_cancel_on,
            "refund_method" => "bitcoins"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "invalid_operation"}
             ] = json_response(conn, 200)["results"]

      assert %{"data" => %{"status" => "active"}} =
               get_group(conn, "group-81") |> json_response(200)
    end
  end

  describe "apply_hotel_credit" do
    test "redeems credit into the outstanding deposit and reports totals", %{conn: conn} do
      conn = issue_standard_lot(conn)

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "new-group",
            "guest_id" => "guest-22",
            "occurred_on" => "2027-02-01",
            "arrival_on" => "2027-04-01",
            "departure_on" => "2027-04-04",
            "rooms" => [%{"room_id" => "room-n", "nightly_rate_cents" => 12_000}]
          }),
          apply_credit_operation("new-group", 5000, %{
            "operation_id" => "op-apply-credit",
            "occurred_on" => "2027-02-10"
          })
        ])

      assert [
               %{"status" => "applied", "deposit_due_cents" => 7200},
               %{
                 "operation_id" => "op-apply-credit",
                 "status" => "applied",
                 "group_id" => "new-group",
                 "amount_cents" => 5000,
                 "outstanding_deposit_cents" => 2200,
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      assert %{
               "data" => %{
                 "revision" => 2,
                 "deposit_due_cents" => 7200,
                 "deposit_paid_cents" => 5000,
                 "outstanding_deposit_cents" => 2200,
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 5000
               }
             } = get_group(conn, "new-group") |> json_response(200)

      # Applying credit redeems it out of the lot, so the liability is unchanged...
      assert %{"cash_converted_to_credit_cents" => 6000, "credit_liability_cents" => 6600} =
               ledger_data(conn, "2027-02-10")

      # ...and the guest's available credit shrank by the applied amount.
      assert %{"available_cents" => 1600, "lots" => [%{"remaining_cents" => 1600}]} =
               guest_credit(conn, "guest-22", "2027-02-10")
    end

    test "consumes lots by earliest expiry first", %{conn: conn} do
      conn = issue_two_lots(conn)

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "spend-group",
            "guest_id" => "order-guest",
            "occurred_on" => "2026-11-10",
            "arrival_on" => "2027-02-01",
            "departure_on" => "2027-02-03",
            "rooms" => [%{"room_id" => "room-s", "nightly_rate_cents" => 15_000}]
          }),
          apply_credit_operation("spend-group", 4000, %{
            "operation_id" => "op-spend-1",
            "occurred_on" => "2026-11-10"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied", "outstanding_deposit_cents" => 2000}
             ] = json_response(conn, 200)["results"]

      assert %{
               "available_cents" => 9200,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-p",
                   "remaining_cents" => 2600,
                   "expires_on" => "2027-11-02"
                 },
                 %{
                   "source_operation_id" => "op-cancel-q",
                   "remaining_cents" => 6600,
                   "expires_on" => "2027-11-06"
                 }
               ]
             } = guest_credit(conn, "order-guest", "2026-11-10")
    end

    test "exhausted lots disappear and an application can straddle two lots", %{conn: conn} do
      conn = issue_two_lots(conn)

      # A 9-night-freeing deposit leaves room for more credit than the
      # earliest lot holds, forcing one application to span both lots.
      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "spend-group",
            "guest_id" => "order-guest",
            "occurred_on" => "2026-11-10",
            "arrival_on" => "2027-02-01",
            "departure_on" => "2027-02-04",
            "rooms" => [%{"room_id" => "room-s", "nightly_rate_cents" => 15_000}]
          }),
          apply_credit_operation("spend-group", 8000, %{
            "operation_id" => "op-spend-1",
            "occurred_on" => "2026-11-10"
          })
        ])

      assert [
               %{"status" => "applied", "deposit_due_cents" => 9000},
               %{
                 "status" => "applied",
                 "amount_cents" => 8000,
                 "outstanding_deposit_cents" => 1000,
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      # All 6600 of the earliest-expiry lot went first and ran dry; the rest
      # (1400) came from the next one.
      assert %{
               "available_cents" => 5200,
               "lots" => [%{"source_operation_id" => "op-cancel-q", "remaining_cents" => 5200}]
             } = guest_credit(conn, "order-guest", "2026-11-10")
    end

    test "equal expiries consume lots ordered by source operation id", %{conn: conn} do
      conn = issue_tied_lots(conn)

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "tie-group",
            "guest_id" => "tie-guest",
            "occurred_on" => "2026-11-11",
            "arrival_on" => "2027-02-01",
            "departure_on" => "2027-02-02",
            "rooms" => [%{"room_id" => "room-t", "nightly_rate_cents" => 10_000}]
          }),
          apply_credit_operation("tie-group", 100, %{"occurred_on" => "2026-11-11"})
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied"}] =
               json_response(conn, 200)["results"]

      assert %{
               "lots" => [
                 %{"source_operation_id" => "cancel-r", "remaining_cents" => 10},
                 %{"source_operation_id" => "cancel-s", "remaining_cents" => 110}
               ]
             } = guest_credit(conn, "tie-guest", "2026-11-11")
    end

    test "rejects amounts the guest's unexpired credit cannot cover", %{conn: conn} do
      conn = issue_standard_lot(conn)

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "new-group",
            "guest_id" => "guest-22",
            "occurred_on" => "2027-02-01",
            "arrival_on" => "2027-04-01",
            "departure_on" => "2027-04-04",
            "rooms" => [%{"room_id" => "room-n", "nightly_rate_cents" => 12_000}]
          }),
          apply_credit_operation("new-group", 5000, %{"occurred_on" => "2027-02-10"}),
          apply_credit_operation("new-group", 1700, %{
            "operation_id" => "op-too-much",
            "occurred_on" => "2027-02-11"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "insufficient_credit"}
             ] = json_response(conn, 200)["results"]

      # Only 1600 remains unexpired after the first application.
      assert %{"data" => %{"revision" => 2, "credit_paid_cents" => 5000}} =
               get_group(conn, "new-group") |> json_response(200)

      assert %{"available_cents" => 1600} = guest_credit(conn, "guest-22", "2027-02-11")
    end

    test "evaluates expiry with the operation date: the day before expiry works, expiry day fails",
         %{conn: conn} do
      conn = issue_standard_lot(conn)

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "late-group",
            "guest_id" => "guest-22",
            "occurred_on" => "2027-06-01",
            "arrival_on" => "2028-02-10",
            "departure_on" => "2028-02-12",
            "rooms" => [%{"room_id" => "room-u", "nightly_rate_cents" => 15_000}]
          }),
          apply_credit_operation("late-group", 100, %{"occurred_on" => "2027-11-20"}),
          apply_credit_operation("late-group", 100, %{
            "operation_id" => "op-after-expiry",
            "occurred_on" => @issued_lot_expiry
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "insufficient_credit"}
             ] = json_response(conn, 200)["results"]
    end

    test "caps credit at the outstanding deposit", %{conn: conn} do
      # A large conversion gives guest-rich 19800 of credit (18000 x 110%).
      conn =
        issue_standard_lot(conn, group_id: "rich-group", guest_id: "guest-rich", cash: 18_000)

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "small-group",
            "guest_id" => "guest-rich",
            "occurred_on" => "2027-05-20",
            "arrival_on" => "2027-06-10",
            "departure_on" => "2027-06-11",
            "rooms" => [%{"room_id" => "room-sm", "nightly_rate_cents" => 15_000}]
          }),
          apply_credit_operation("small-group", 4000, %{"occurred_on" => "2027-05-25"}),
          apply_credit_operation("small-group", 3000, %{
            "operation_id" => "op-exact-fit",
            "occurred_on" => "2027-05-25"
          })
        ])

      assert [
               %{"status" => "applied", "deposit_due_cents" => 3000},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"},
               %{
                 "status" => "applied",
                 "amount_cents" => 3000,
                 "outstanding_deposit_cents" => 0,
                 "revision" => 2
               }
             ] = json_response(conn, 200)["results"]

      assert %{"available_cents" => 16_800} = guest_credit(conn, "guest-rich", "2027-05-25")
    end

    test "rejects unusable amounts", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          apply_credit_operation("group-81", 0),
          apply_credit_operation("group-81", -50, %{"operation_id" => "op-negative"}),
          apply_credit_operation("group-81", "50", %{"operation_id" => "op-string"}),
          apply_credit_operation("group-81", nil, %{"operation_id" => "op-nil"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "invalid_amount"},
               %{"status" => "rejected", "code" => "invalid_amount"},
               %{"status" => "rejected", "code" => "invalid_amount"},
               %{"status" => "rejected", "code" => "invalid_amount"}
             ] = json_response(conn, 200)["results"]

      assert %{"data" => %{"revision" => 1, "credit_paid_cents" => 0}} =
               get_group(conn, "group-81") |> json_response(200)
    end

    test "checks the revision before credit rules when the group exists", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          apply_credit_operation("ghost-group", 100, %{
            "expected_revision" => 3,
            "occurred_on" => "2027-02-10"
          }),
          apply_credit_operation("group-81", 999_999, %{
            "operation_id" => "op-stale-and-broke",
            "expected_revision" => 5,
            "occurred_on" => "2027-02-10"
          }),
          apply_credit_operation("group-81", 999_999, %{"occurred_on" => "2027-02-10"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "group_not_found"},
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 5,
                 "actual_revision" => 1
               },
               %{"status" => "rejected", "code" => "insufficient_credit"}
             ] = json_response(conn, 200)["results"]

      assert %{"data" => %{"revision" => 1}} = get_group(conn, "group-81") |> json_response(200)
    end
  end

  describe "settling groups funded by credit" do
    test "a refundable cash cancellation restores applied credit to its original lot", %{
      conn: conn
    } do
      conn = issue_standard_lot(conn)

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "new-group",
            "guest_id" => "guest-22",
            "occurred_on" => "2027-02-01",
            "arrival_on" => "2027-04-01",
            "departure_on" => "2027-04-04",
            "rooms" => [%{"room_id" => "room-n", "nightly_rate_cents" => 12_000}]
          }),
          apply_credit_operation("new-group", 5000, %{"occurred_on" => "2027-02-10"}),
          cancel_operation("new-group", %{
            "operation_id" => "op-cancel-new",
            "occurred_on" => "2027-03-02"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      # Back on its original lot with its original expiry, no second bonus.
      assert %{
               "available_cents" => 6600,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel",
                   "remaining_cents" => 6600,
                   "expires_on" => @issued_lot_expiry
                 }
               ]
             } = guest_credit(conn, "guest-22", "2027-03-02")

      assert %{"data" => %{"status" => "cancelled", "credit_paid_cents" => 0}} =
               get_group(conn, "new-group") |> json_response(200)

      assert %{"credit_liability_cents" => 6600} = ledger_data(conn, "2027-03-02")
    end

    test "expiry pauses while credit funds an active group; a restored expired lot dies at once",
         %{conn: conn} do
      conn = issue_standard_lot(conn)

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "late-group",
            "guest_id" => "guest-22",
            "occurred_on" => "2027-06-01",
            "arrival_on" => "2028-02-10",
            "departure_on" => "2028-02-12",
            "rooms" => [%{"room_id" => "room-u", "nightly_rate_cents" => 15_000}]
          }),
          apply_credit_operation("late-group", 100, %{"occurred_on" => "2027-11-20"})
        ])

      assert [%{"status" => "applied"}, %{"status" => "applied"}] =
               json_response(conn, 200)["results"]

      # On the expiry date the available part is gone but the applied part
      # stays liable: its expiry is paused while it funds the group.
      assert %{"credit_liability_cents" => 100} = ledger_data(conn, @issued_lot_expiry)
      assert %{"credit_liability_cents" => 6600} = ledger_data(conn, "2027-11-20")

      conn =
        post_operations(conn, [
          cancel_operation("late-group", %{
            "operation_id" => "op-cancel-late",
            "occurred_on" => "2028-01-05"
          })
        ])

      # Refundable (flex-30 horizon 2028-01-11): the 100 restored onto the
      # expired lot reduces the liability instead of becoming available again.
      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0,
                 "revision" => 3
               }
             ] = json_response(conn, 200)["results"]

      assert %{"credit_liability_cents" => 0} = ledger_data(conn, "2028-01-05")

      assert %{"available_cents" => 0, "lots" => []} =
               guest_credit(conn, "guest-22", "2028-01-05")
    end

    test "a non-refundable cancellation retains cash and consumes applied credit", %{conn: conn} do
      conn = issue_standard_lot(conn)

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "new-group",
            "guest_id" => "guest-22",
            "occurred_on" => "2027-02-01",
            "arrival_on" => "2027-04-01",
            "departure_on" => "2027-04-04",
            "rooms" => [%{"room_id" => "room-n", "nightly_rate_cents" => 12_000}]
          }),
          payment_operation("new-group", 2000),
          apply_credit_operation("new-group", 5000, %{"occurred_on" => "2027-02-10"}),
          cancel_operation("new-group", %{"occurred_on" => "2027-03-10"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 2000,
                 "credit_issued_cents" => 0,
                 "revision" => 4
               }
             ] = json_response(conn, 200)["results"]

      assert %{
               "data" => %{
                 "status" => "cancelled",
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 0
               }
             } =
               get_group(conn, "new-group") |> json_response(200)

      # The consumed credit leaves the liability; the rest sits available.
      assert %{
               "cash_held_cents" => 0,
               "cash_retained_cents" => 2000,
               "cash_converted_to_credit_cents" => 6000,
               "credit_liability_cents" => 1600
             } = ledger_data(conn, "2027-03-10")

      assert %{"available_cents" => 1600} = guest_credit(conn, "guest-22", "2027-03-10")
    end

    test "a mixed cash-and-credit funding refunds only the cash and restores the credit", %{
      conn: conn
    } do
      conn = issue_standard_lot(conn)

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "mixed-group",
            "guest_id" => "guest-22",
            "occurred_on" => "2027-02-01",
            "arrival_on" => "2027-04-01",
            "departure_on" => "2027-04-04",
            "rooms" => [%{"room_id" => "room-n", "nightly_rate_cents" => 12_000}]
          }),
          payment_operation("mixed-group", 2000),
          apply_credit_operation("mixed-group", 5000, %{"occurred_on" => "2027-02-10"}),
          cancel_operation("mixed-group", %{
            "operation_id" => "op-cancel-mixed",
            "occurred_on" => "2027-03-02"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "refunded_cents" => 2000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] = json_response(conn, 200)["results"]

      assert %{"available_cents" => 6600} = guest_credit(conn, "guest-22", "2027-03-02")

      assert %{
               "cash_held_cents" => 0,
               "cash_refunded_cents" => 2000,
               "cash_converted_to_credit_cents" => 6000,
               "credit_liability_cents" => 6600
             } = ledger_data(conn, "2027-03-02")
    end

    test "converting cash on a second refundable cancellation issues a new lot without touching restored credit",
         %{conn: conn} do
      conn = issue_standard_lot(conn)

      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "new-group",
            "guest_id" => "guest-22",
            "occurred_on" => "2027-02-01",
            "arrival_on" => "2027-04-01",
            "departure_on" => "2027-04-04",
            "rooms" => [%{"room_id" => "room-n", "nightly_rate_cents" => 12_000}]
          }),
          payment_operation("new-group", 2000),
          apply_credit_operation("new-group", 5000, %{"occurred_on" => "2027-02-10"}),
          cancel_operation("new-group", %{
            "operation_id" => "op-cancel-second",
            "occurred_on" => "2027-03-02",
            "refund_method" => "hotel_credit"
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 2200,
                 "revision" => 4
               }
             ] = json_response(conn, 200)["results"]

      # The restored 5000 rejoined its original lot (6600 total) and the new
      # 2000 cash became its own 2200 lot. The window to 2028-03-02 spans
      # the 2028 leap day, so 365 days out is 2028-03-01 and it expires the
      # following day. Neither lot receives a second bonus.
      assert %{
               "available_cents" => 8800,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel",
                   "remaining_cents" => 6600,
                   "expires_on" => @issued_lot_expiry
                 },
                 %{
                   "source_operation_id" => "op-cancel-second",
                   "remaining_cents" => 2200,
                   "expires_on" => "2028-03-02"
                 }
               ]
             } = guest_credit(conn, "guest-22", "2027-03-02")

      assert %{"cash_converted_to_credit_cents" => 8000, "credit_liability_cents" => 8800} =
               ledger_data(conn, "2027-03-02")
    end
  end

  describe "credit reads" do
    test "omits expired lots as of the requested date and defaults to the current UTC date", %{
      conn: conn
    } do
      conn = issue_standard_lot(conn)

      assert %{"available_cents" => 6600} = guest_credit(conn, "guest-22", "2027-11-20")

      assert %{"available_cents" => 0, "lots" => []} =
               guest_credit(conn, "guest-22", "2027-11-21")

      # Today precedes the expiry, so the default view still shows the lot.
      assert %{"available_cents" => 6600} = guest_credit(conn, "guest-22")
    end

    test "the guest credit endpoint rejects an unusable on parameter", %{conn: conn} do
      conn = get_guest_credit(conn, "guest-22", on: "soon")

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_date"}}
    end

    test "the ledger endpoint reports liability as of the on parameter", %{conn: conn} do
      conn = issue_standard_lot(conn)

      assert %{"credit_liability_cents" => 6600} = ledger_data(conn, "2026-12-31")
      assert %{"credit_liability_cents" => 0} = ledger_data(conn, "2028-01-01")
    end

    test "the ledger endpoint rejects an unusable on parameter", %{conn: conn} do
      conn = get_ledger(conn, on: "not-a-date")

      assert json_response(conn, 422) == %{"error" => %{"code" => "invalid_date"}}
    end
  end

  defp issue_two_lots(conn) do
    conn =
      post_operations(conn, [
        open_operation(%{
          "group_id" => "p-group",
          "guest_id" => "order-guest",
          "arrival_on" => "2026-12-01",
          "departure_on" => "2026-12-03",
          "rooms" => [%{"room_id" => "room-p", "nightly_rate_cents" => 15_000}]
        }),
        payment_operation("p-group", 6000),
        cancel_operation("p-group", %{
          "operation_id" => "op-cancel-p",
          "occurred_on" => "2026-11-01",
          "refund_method" => "hotel_credit"
        }),
        open_operation(%{
          "group_id" => "q-group",
          "guest_id" => "order-guest",
          "occurred_on" => "2026-09-05",
          "arrival_on" => "2026-12-05",
          "departure_on" => "2026-12-07",
          "rooms" => [%{"room_id" => "room-q", "nightly_rate_cents" => 15_000}]
        }),
        payment_operation("q-group", 6000),
        cancel_operation("q-group", %{
          "operation_id" => "op-cancel-q",
          "occurred_on" => "2026-11-05",
          "refund_method" => "hotel_credit"
        })
      ])

    assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

    conn
  end

  defp issue_tied_lots(conn) do
    r_stay = %{
      "guest_id" => "tie-guest",
      "arrival_on" => "2026-12-25",
      "departure_on" => "2026-12-27",
      "rooms" => [%{"room_id" => "room-r", "nightly_rate_cents" => 10_000}]
    }

    conn =
      post_operations(conn, [
        open_operation(Map.merge(r_stay, %{"group_id" => "r-group"})),
        payment_operation("r-group", 100),
        cancel_operation("r-group", %{
          "operation_id" => "cancel-r",
          "occurred_on" => "2026-11-10",
          "refund_method" => "hotel_credit"
        }),
        open_operation(Map.merge(r_stay, %{"group_id" => "s-group"})),
        payment_operation("s-group", 100),
        cancel_operation("s-group", %{
          "operation_id" => "cancel-s",
          "occurred_on" => "2026-11-10",
          "refund_method" => "hotel_credit"
        })
      ])

    assert Enum.all?(json_response(conn, 200)["results"], &(&1["status"] == "applied"))

    conn
  end
end
