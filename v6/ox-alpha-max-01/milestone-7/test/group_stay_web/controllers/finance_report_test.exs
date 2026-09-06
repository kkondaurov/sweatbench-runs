defmodule GroupStayWeb.FinanceReportTest do
  use GroupStayWeb.ConnCase

  @start "2027-01-01"

  # A lot issued by a refundable hotel-credit cancellation on 2026-11-20 is
  # available through 2027-11-20 and expires on 2027-11-21.
  @issued_lot_expiry "2027-11-21"

  defp results(conn), do: conn |> json_response(200) |> Map.fetch!("results")

  defp ledger_data(conn, query \\ []),
    do: conn |> get_ledger(query) |> json_response(200) |> Map.fetch!("data")

  defp zero_cash_movements do
    %{
      "received_cents" => 0,
      "transferred_in_cents" => 0,
      "transferred_out_cents" => 0,
      "refunded_cents" => 0,
      "retained_cents" => 0,
      "converted_to_credit_cents" => 0,
      "reduced_cents" => 0,
      "charged_back_cents" => 0
    }
  end

  defp zero_credit_movements do
    %{
      "issued_cents" => 0,
      "expired_cents" => 0,
      "consumed_cents" => 0,
      "revoked_cents" => 0,
      "absorbed_cents" => 0
    }
  end

  defp cash_entry(property_id, opening, movements, closing) do
    %{
      "property_id" => property_id,
      "opening_held_cents" => opening,
      "movements" => Map.merge(zero_cash_movements(), movements),
      "closing_held_cents" => closing
    }
  end

  defp credit_entry(opening, movements, closing) do
    %{
      "opening_liability_cents" => opening,
      "movements" => Map.merge(zero_credit_movements(), movements),
      "closing_liability_cents" => closing
    }
  end

  # Every successful daily report carries a late-adjustments block; days
  # without close-forwarded postings show it entirely zeroed.
  defp zero_late_adjustments do
    %{
      "cash" => [],
      "credit" => %{
        "issued_cents" => 0,
        "expired_cents" => 0,
        "consumed_cents" => 0,
        "revoked_cents" => 0,
        "absorbed_cents" => 0
      }
    }
  end

  # A flexible two-night single-room group: lodging 40000, deposit due 8000.
  # Booked on 2027-01-02, so it uses the flex-30 policy and stays refundable
  # until 30 days before its arrival.
  defp open_2027_group(group_id, property_id, overrides \\ %{}) do
    open_operation(
      Map.merge(
        %{
          "group_id" => group_id,
          "property_id" => property_id,
          "occurred_on" => "2027-01-02",
          "arrival_on" => "2027-03-10",
          "departure_on" => "2027-03-12",
          "rooms" => [%{"room_id" => "room-#{group_id}", "nightly_rate_cents" => 20_000}]
        },
        overrides
      )
    )
  end

  describe "starting finance reporting" do
    test "the applied result contains exactly operation_id, status, and starts_on", %{conn: conn} do
      conn =
        post_operations(conn, [start_reporting_operation(@start, %{"operation_id" => "op-start"})])

      assert [%{"operation_id" => "op-start", "status" => "applied", "starts_on" => @start}] =
               results(conn)
    end

    test "rejects a missing or invalid starts_on", %{conn: conn} do
      conn =
        post_operations(conn, [
          %{"operation_id" => "op-no-date", "type" => "start_finance_reporting"},
          start_reporting_operation("soon", %{"operation_id" => "op-bad-date"}),
          start_reporting_operation("2027-13-01", %{"operation_id" => "op-bad-month"})
        ])

      for result <- results(conn) do
        assert %{"status" => "rejected", "code" => "invalid_reporting_date"} = result
      end

      # Nothing was started by the rejected attempts.
      assert conn
             |> get_finance_report(%{"date" => @start})
             |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}
    end

    test "a retry replays durably while any other start is rejected", %{conn: conn} do
      start = start_reporting_operation(@start, %{"operation_id" => "op-start"})

      conn = post_operations(conn, [start])
      assert [%{"status" => "applied"}] = results(conn)

      # An exact retry replays the stored applied result verbatim.
      conn = post_operations(conn, [start])

      assert [%{"operation_id" => "op-start", "status" => "applied", "starts_on" => @start}] =
               results(conn)

      # Any other start operation is rejected once reporting has begun.
      conn =
        post_operations(conn, [
          start_reporting_operation(@start, %{"operation_id" => "op-second"}),
          start_reporting_operation("2027-02-01", %{"operation_id" => "op-third"})
        ])

      assert [
               %{"status" => "rejected", "code" => "reporting_already_started"},
               %{"status" => "rejected", "code" => "reporting_already_started"}
             ] = results(conn)

      assert %{"date" => @start} = Map.take(finance_report(conn, @start), ["date"])
    end

    test "reusing the original identifier with a changed payload conflicts", %{conn: conn} do
      start = start_reporting_operation(@start, %{"operation_id" => "op-start"})

      conn = post_operations(conn, [start])
      assert [%{"status" => "applied"}] = results(conn)

      variant = start_reporting_operation("2027-06-01", %{"operation_id" => "op-start"})

      conn = post_operations(conn, [variant])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "operation_id_conflict",
                 "operation_id" => "op-start"
               }
             ] = results(conn)
    end
  end

  describe "reading one day" do
    test "a missing or invalid date is rejected", %{conn: conn} do
      conn = post_operations(conn, [start_reporting_operation(@start)])

      for params <- [%{}, %{"date" => "yesterday"}, %{"date" => "2027-02-30"}] do
        assert conn
               |> get_finance_report(params)
               |> json_response(422) == %{"error" => %{"code" => "invalid_reporting_date"}}
      end
    end

    test "the report is unavailable before reporting starts and before starts_on", %{conn: conn} do
      assert conn
             |> get_finance_report(%{"date" => @start})
             |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

      conn = post_operations(conn, [start_reporting_operation(@start)])

      assert conn
             |> get_finance_report(%{"date" => "2026-12-31"})
             |> json_response(404) == %{"error" => %{"code" => "report_not_available"}}

      assert %{"status" => "open"} = finance_report(conn, @start)
    end

    test "an empty inception day reports zero credit and no cash entries", %{conn: conn} do
      conn = post_operations(conn, [start_reporting_operation(@start)])

      assert finance_report(conn, @start) == %{
               "date" => @start,
               "status" => "open",
               "cash" => [],
               "credit" => credit_entry(0, %{}, 0),
               "late_adjustments" => zero_late_adjustments()
             }
    end
  end

  describe "opening position and posting dates" do
    test "every committed operation lands in the opening, even with occurred_on after starts_on",
         %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          payment_operation("group-81", 3_000, %{"occurred_on" => "2027-05-01"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      conn = post_operations(conn, [start_reporting_operation(@start)])

      assert finance_report(conn, @start) == %{
               "date" => @start,
               "status" => "open",
               "cash" => [cash_entry("ams-canal", 3_000, %{}, 3_000)],
               "credit" => credit_entry(0, %{}, 0),
               "late_adjustments" => zero_late_adjustments()
             }
    end

    test "in one batch, operations before the start open it and operations after it move it", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(),
          open_operation(%{
            "group_id" => "group-b",
            "property_id" => "rot-lake",
            "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 20_000}]
          }),
          payment_operation("group-81", 1_000),
          start_reporting_operation(@start),
          payment_operation("group-81", 500)
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      # group-b was opened before the start but never funded: it appears
      # nowhere. The pre-start payment sits in the opening; the post-start
      # payment moves.
      assert finance_report(conn, @start) == %{
               "date" => @start,
               "status" => "open",
               "cash" => [cash_entry("ams-canal", 1_000, %{"received_cents" => 500}, 1_500)],
               "credit" => credit_entry(0, %{}, 0),
               "late_adjustments" => zero_late_adjustments()
             }
    end

    test "an occurrence before starts_on posts at starts_on, and a later submission revises the earlier open report",
         %{conn: conn} do
      conn = post_operations(conn, [open_operation(), start_reporting_operation(@start)])
      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      before = finance_report(conn, @start)
      assert before["cash"] == []

      conn =
        post_operations(conn, [
          payment_operation("group-81", 1_200, %{"occurred_on" => "2026-12-25"})
        ])

      assert [%{"status" => "applied"}] = results(conn)

      after_submission = finance_report(conn, @start)

      assert after_submission == %{
               "date" => @start,
               "status" => "open",
               "cash" => [cash_entry("ams-canal", 0, %{"received_cents" => 1_200}, 1_200)],
               "credit" => credit_entry(0, %{}, 0),
               "late_adjustments" => zero_late_adjustments()
             }

      # Reading repeatedly changes nothing anywhere.
      assert finance_report(conn, @start) == after_submission

      assert finance_report(conn, "2027-01-02") ==
               %{
                 "date" => "2027-01-02",
                 "status" => "open",
                 "cash" => [cash_entry("ams-canal", 1_200, %{}, 1_200)],
                 "credit" => credit_entry(0, %{}, 0),
                 "late_adjustments" => zero_late_adjustments()
               }

      assert %{"cash_held_cents" => 1_200} = ledger_data(conn)
    end
  end

  describe "daily cash movements" do
    test "payments report per property in property_id order and untouched properties are omitted",
         %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          open_operation(%{
            "group_id" => "group-b",
            "property_id" => "rot-lake",
            "guest_id" => "guest-22",
            "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 20_000}]
          }),
          open_operation(%{
            "group_id" => "group-c",
            "property_id" => "zen-park",
            "guest_id" => "guest-22",
            "rooms" => [%{"room_id" => "room-d", "nightly_rate_cents" => 20_000}]
          }),
          open_operation(%{
            "group_id" => "group-d",
            "property_id" => "quiet-quay",
            "guest_id" => "guest-22",
            "rooms" => [%{"room_id" => "room-e", "nightly_rate_cents" => 20_000}]
          }),
          start_reporting_operation(@start),
          payment_operation("group-c", 700, %{"occurred_on" => "2027-01-02"}),
          payment_operation("group-81", 200, %{"occurred_on" => "2027-01-03"}),
          payment_operation("group-b", 900, %{"occurred_on" => "2027-01-04"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      assert finance_report(conn, "2027-01-02")["cash"] == [
               cash_entry("zen-park", 0, %{"received_cents" => 700}, 700)
             ]

      assert finance_report(conn, "2027-01-04")["cash"] == [
               cash_entry("ams-canal", 200, %{}, 200),
               cash_entry("rot-lake", 0, %{"received_cents" => 900}, 900),
               cash_entry("zen-park", 700, %{}, 700)
             ]
    end

    test "transfers move held cash between the groups' properties and stay equal company-wide", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(),
          open_operation(%{
            "group_id" => "group-b",
            "property_id" => "rot-lake",
            "guest_id" => "guest-22",
            "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 20_000}]
          }),
          start_reporting_operation(@start),
          payment_operation("group-81", 5_000, %{"occurred_on" => "2027-01-02"}),
          transfer_deposit_operation("group-81", "group-b", 3_000, %{
            "occurred_on" => "2027-01-05"
          })
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      assert finance_report(conn, "2027-01-05")["cash"] == [
               cash_entry(
                 "ams-canal",
                 5_000,
                 %{"transferred_out_cents" => 3_000},
                 2_000
               ),
               cash_entry(
                 "rot-lake",
                 0,
                 %{"transferred_in_cents" => 3_000},
                 3_000
               )
             ]
    end

    test "moving hotel credit reports no cash movement and leaves liability flat", %{conn: conn} do
      holder = "credit-holder"

      conn =
        post_operations(conn, [
          open_operation(),
          # Issue the lot before reporting starts so it is opening liability.
          payment_operation("group-81", 1_000),
          cancel_operation("group-81", %{
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          }),
          open_operation(%{
            "group_id" => holder,
            "property_id" => "rot-lake",
            "guest_id" => "guest-22",
            "arrival_on" => "2027-03-10",
            "departure_on" => "2027-03-12",
            "rooms" => [%{"room_id" => "room-h", "nightly_rate_cents" => 20_000}]
          }),
          start_reporting_operation(@start),
          apply_credit_operation(holder, 1_100, %{"occurred_on" => "2026-11-20"}),
          open_operation(%{
            "group_id" => "credit-final",
            "property_id" => "zen-park",
            "guest_id" => "guest-22",
            "arrival_on" => "2027-03-10",
            "departure_on" => "2027-03-12",
            "rooms" => [%{"room_id" => "room-z", "nightly_rate_cents" => 20_000}]
          }),
          transfer_deposit_operation(holder, "credit-final", 600, %{"occurred_on" => "2027-01-05"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      # Applying credit posts nothing; transferring it moves no cash.
      assert finance_report(conn, @start)["credit"] == credit_entry(1_100, %{}, 1_100)

      assert finance_report(conn, "2027-01-05") == %{
               "date" => "2027-01-05",
               "status" => "open",
               "cash" => [],
               "credit" => credit_entry(1_100, %{}, 1_100),
               "late_adjustments" => zero_late_adjustments()
             }
    end

    test "cancelling selected rooms settles only their allocations", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          start_reporting_operation(@start),
          # Fills room-a's 9000 deposit and 3000 of room-b's 10500.
          payment_operation("group-81", 12_000),
          cancel_rooms_operation("group-81", ["room-a"], %{"occurred_on" => "2026-11-20"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{
                 "status" => "applied",
                 "cancelled_room_ids" => ["room-a"],
                 "refunded_cents" => 9_000,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 0
               }
             ] = results(conn)

      assert finance_report(conn, @start)["cash"] == [
               cash_entry(
                 "ams-canal",
                 0,
                 %{"received_cents" => 12_000, "refunded_cents" => 9_000},
                 3_000
               )
             ]
    end

    test "a refundable cash cancellation refunds at the settling property", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(),
          start_reporting_operation(@start),
          payment_operation("group-81", 4_000),
          cancel_operation("group-81", %{"occurred_on" => "2026-11-20"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      # Both operations post to starts_on: the payment arrives and is
      # refunded within the same day's report.
      assert finance_report(conn, @start)["cash"] == [
               cash_entry(
                 "ams-canal",
                 0,
                 %{"received_cents" => 4_000, "refunded_cents" => 4_000},
                 0
               )
             ]
    end

    test "a non-refundable cancellation retains at the settling property", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_operation(%{
            "group_id" => "advance-group",
            "rate_plan" => "advance_purchase",
            "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 10_000}]
          }),
          start_reporting_operation(@start),
          payment_operation("advance-group", 30_000),
          cancel_operation("advance-group", %{"occurred_on" => "2026-12-30"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      assert finance_report(conn, @start)["cash"] == [
               cash_entry(
                 "ams-canal",
                 0,
                 %{"received_cents" => 30_000, "retained_cents" => 30_000},
                 0
               )
             ]
    end

    test "charging back a refunded payment reverses refunded into charged-back cash", %{
      conn: conn
    } do
      payment_id = "op-pay-cb"

      conn =
        post_operations(conn, [
          open_2027_group("cb-group", "ams-canal"),
          start_reporting_operation(@start),
          payment_operation("cb-group", 1_000, %{
            "occurred_on" => "2027-01-05",
            "operation_id" => payment_id
          }),
          cancel_operation("cb-group", %{"occurred_on" => "2027-01-10"}),
          charge_back_payment_operation(payment_id, %{"occurred_on" => "2027-01-15"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      assert finance_report(conn, "2027-01-05")["cash"] == [
               cash_entry("ams-canal", 0, %{"received_cents" => 1_000}, 1_000)
             ]

      assert finance_report(conn, "2027-01-10")["cash"] == [
               cash_entry("ams-canal", 1_000, %{"refunded_cents" => 1_000}, 0)
             ]

      assert finance_report(conn, "2027-01-15")["cash"] == [
               cash_entry(
                 "ams-canal",
                 0,
                 %{"refunded_cents" => -1_000, "charged_back_cents" => 1_000},
                 0
               )
             ]
    end

    test "a reduction follows transferred cash to the property where it is held", %{conn: conn} do
      payment_id = "op-pay-reduce"

      conn =
        post_operations(conn, [
          open_operation(),
          open_operation(%{
            "group_id" => "group-b",
            "property_id" => "rot-lake",
            "guest_id" => "guest-22",
            "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 20_000}]
          }),
          start_reporting_operation(@start),
          payment_operation("group-81", 8_000, %{
            "occurred_on" => "2027-01-02",
            "operation_id" => payment_id
          }),
          transfer_deposit_operation("group-81", "group-b", 3_000, %{
            "occurred_on" => "2027-01-03"
          }),
          reduce_cash_payment_operation(payment_id, 3_000, %{"occurred_on" => "2027-01-04"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      # The transferred slice was removed first: the reduction posts to the
      # holding property, not the payment's original one.
      assert finance_report(conn, "2027-01-04")["cash"] == [
               cash_entry("ams-canal", 5_000, %{}, 5_000),
               cash_entry("rot-lake", 3_000, %{"reduced_cents" => 3_000}, 0)
             ]

      assert %{"cash_held_cents" => 5_000, "cash_reduced_cents" => 3_000} = ledger_data(conn)
    end
  end

  describe "hotel-credit liability movements" do
    test "converting settled cash issues credit at the settling property's cancellation", %{
      conn: conn
    } do
      conn =
        post_operations(conn, [
          open_operation(),
          start_reporting_operation(@start),
          payment_operation("group-81", 1_000),
          cancel_operation("group-81", %{
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          })
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      assert finance_report(conn, @start) == %{
               "date" => @start,
               "status" => "open",
               "cash" => [
                 cash_entry(
                   "ams-canal",
                   0,
                   %{"received_cents" => 1_000, "converted_to_credit_cents" => 1_000},
                   0
                 )
               ],
               "credit" => credit_entry(0, %{"issued_cents" => 1_100}, 1_100),
               "late_adjustments" => zero_late_adjustments()
             }
    end

    test "charging back converted principal reclassifies the cash and revokes the credit", %{
      conn: conn
    } do
      payment_id = "op-pay-conv"

      conn =
        post_operations(conn, [
          open_2027_group("conv-group", "zen-park"),
          start_reporting_operation(@start),
          payment_operation("conv-group", 1_000, %{
            "occurred_on" => "2027-01-03",
            "operation_id" => payment_id
          }),
          cancel_operation("conv-group", %{
            "occurred_on" => "2027-01-05",
            "refund_method" => "hotel_credit"
          }),
          charge_back_payment_operation(payment_id, %{"occurred_on" => "2027-01-08"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      assert finance_report(conn, "2027-01-05") == %{
               "date" => "2027-01-05",
               "status" => "open",
               "cash" => [
                 cash_entry("zen-park", 1_000, %{"converted_to_credit_cents" => 1_000}, 0)
               ],
               "credit" => credit_entry(0, %{"issued_cents" => 1_100}, 1_100),
               "late_adjustments" => zero_late_adjustments()
             }

      assert finance_report(conn, "2027-01-08") == %{
               "date" => "2027-01-08",
               "status" => "open",
               "cash" => [
                 cash_entry(
                   "zen-park",
                   0,
                   %{"converted_to_credit_cents" => -1_000, "charged_back_cents" => 1_000},
                   0
                 )
               ],
               "credit" => credit_entry(1_100, %{"revoked_cents" => 1_100}, 0),
               "late_adjustments" => zero_late_adjustments()
             }
    end

    test "expiry shows on the day after availability even with no operation submitted then", %{
      conn: conn
    } do
      holder_id = "holder-group"

      conn =
        post_operations(conn, [
          open_operation(),
          start_reporting_operation(@start),
          payment_operation("group-81", 1_000, %{"occurred_on" => "2027-01-02"}),
          cancel_operation("group-81", %{
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          }),
          open_2027_group(holder_id, "ams-canal"),
          apply_credit_operation(holder_id, 100, %{"occurred_on" => "2027-02-01"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      # Applying credit itself has no movement column and leaves the
      # liability flat.
      assert finance_report(conn, "2027-02-01")["credit"] == credit_entry(1_100, %{}, 1_100)

      # The last available day comes and goes with no expiry yet.
      assert finance_report(conn, "2027-11-20")["credit"] == credit_entry(1_100, %{}, 1_100)

      # On the expiry date only the unapplied part dies; the applied part
      # stays liable because its expiry is paused while it funds the group.
      assert finance_report(conn, @issued_lot_expiry)["credit"] ==
               credit_entry(1_100, %{"expired_cents" => 1_000}, 100)

      # The report reconciles with the existing current view of that day.
      assert %{"credit_liability_cents" => 100} = ledger_data(conn, on: @issued_lot_expiry)
    end

    test "settling applied credit consumes it on the settlement date", %{conn: conn} do
      holder_id = "holder-group"

      conn =
        post_operations(conn, [
          open_operation(),
          start_reporting_operation(@start),
          payment_operation("group-81", 1_000, %{"occurred_on" => "2027-01-02"}),
          cancel_operation("group-81", %{
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          }),
          open_2027_group(holder_id, "ams-canal"),
          apply_credit_operation(holder_id, 1_100, %{"occurred_on" => "2027-02-01"}),
          cancel_operation(holder_id, %{"occurred_on" => "2028-01-10"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      # The holder cancelled long after arrival (flex-30 horizon passed), so
      # the applied 1100 is consumed rather than restored; expiry had already
      # taken the unapplied part... none here, since all 1100 was applied.
      assert finance_report(conn, "2028-01-10") == %{
               "date" => "2028-01-10",
               "status" => "open",
               "cash" => [],
               "credit" => credit_entry(1_100, %{"consumed_cents" => 1_100}, 0),
               "late_adjustments" => zero_late_adjustments()
             }
    end

    test "a restoration onto an already-expired lot expires immediately", %{conn: conn} do
      holder_id = "late-holder"

      conn =
        post_operations(conn, [
          open_operation(),
          start_reporting_operation(@start),
          payment_operation("group-81", 1_000, %{"occurred_on" => "2027-01-02"}),
          cancel_operation("group-81", %{
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          }),
          # Booked late in 2027 so the lot can expire while this reservation
          # is still cancellable within its flex-30 window.
          open_operation(%{
            "group_id" => holder_id,
            "occurred_on" => "2027-11-01",
            "arrival_on" => "2028-01-20",
            "departure_on" => "2028-01-22",
            "rooms" => [%{"room_id" => "room-late", "nightly_rate_cents" => 20_000}]
          }),
          apply_credit_operation(holder_id, 100, %{"occurred_on" => "2027-11-01"}),
          cancel_operation(holder_id, %{"occurred_on" => "2027-12-01"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      assert finance_report(conn, @issued_lot_expiry)["credit"] ==
               credit_entry(1_100, %{"expired_cents" => 1_000}, 100)

      # The refundable restoration lands on an expired lot: it reduces the
      # liability immediately instead of becoming available again.
      assert finance_report(conn, "2027-12-01") == %{
               "date" => "2027-12-01",
               "status" => "open",
               "cash" => [],
               "credit" => credit_entry(100, %{"expired_cents" => 100}, 0),
               "late_adjustments" => zero_late_adjustments()
             }

      assert %{"available_cents" => 0} =
               conn
               |> get_guest_credit("guest-22", on: "2027-12-01")
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "a shortfall absorbs a later restoration instead of revoking or issuing", %{conn: conn} do
      p1 = "op-pay-p1"
      p2 = "op-pay-p2"
      holder_id = "shortfall-holder"

      conn =
        post_operations(conn, [
          open_operation(),
          open_operation(%{
            "group_id" => "funded-group",
            "guest_id" => "guest-22",
            "rooms" => [%{"room_id" => "room-f", "nightly_rate_cents" => 20_000}]
          }),
          start_reporting_operation(@start),
          payment_operation("funded-group", 600, %{
            "occurred_on" => "2027-01-02",
            "operation_id" => p1
          }),
          payment_operation("funded-group", 400, %{
            "occurred_on" => "2027-01-02",
            "operation_id" => p2
          }),
          cancel_operation("funded-group", %{
            "occurred_on" => "2026-11-20",
            "refund_method" => "hotel_credit"
          }),
          open_2027_group(holder_id, "ams-canal"),
          apply_credit_operation(holder_id, 1_100, %{"occurred_on" => "2027-01-10"}),
          charge_back_payment_operation(p1, %{"occurred_on" => "2027-01-15"}),
          charge_back_payment_operation(p2, %{"occurred_on" => "2027-01-16"}),
          cancel_operation(holder_id, %{"occurred_on" => "2027-01-20"})
        ])

      results_list = results(conn)
      assert Enum.all?(results_list, &(&1["status"] == "applied"))
      # Both entitlements telescope into the one 1100 lot: bonus(600)=660 to
      # p1, bonus(1000)-bonus(600)=440 to p2. With everything applied, both
      # clawbacks are unrecoverable and revoke nothing.
      assert finance_report(conn, "2027-01-15")["credit"] ==
               credit_entry(1_100, %{}, 1_100)

      assert finance_report(conn, "2027-01-16")["credit"] ==
               credit_entry(1_100, %{}, 1_100)

      # The refundable settlement restores the 1100 onto the shortfalled lot,
      # where the clawback absorbs all of it.
      assert finance_report(conn, "2027-01-20") == %{
               "date" => "2027-01-20",
               "status" => "open",
               "cash" => [],
               "credit" => credit_entry(1_100, %{"absorbed_cents" => 1_100}, 0),
               "late_adjustments" => zero_late_adjustments()
             }

      # The conversions were charged back along the way: each reversal took
      # its share out of converted and into charged-back classification.
      assert %{
               "cash_converted_to_credit_cents" => 0,
               "cash_charged_back_cents" => 1_000,
               "cash_held_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             } = ledger_data(conn)
    end
  end

  describe "durability and reconciliation" do
    test "rejected operations leave no movement and durable retries report nothing twice", %{
      conn: conn
    } do
      payment = payment_operation("group-81", 500, %{"occurred_on" => "2027-01-02"})

      conn =
        post_operations(conn, [
          open_operation(),
          start_reporting_operation(@start),
          payment,
          payment_operation("group-81", 999_999, %{"occurred_on" => "2027-01-03"})
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "rejected", "code" => "payment_exceeds_outstanding"}
             ] = results(conn)

      first_reading = finance_report(conn, "2027-01-03")

      assert first_reading == %{
               "date" => "2027-01-03",
               "status" => "open",
               "cash" => [cash_entry("ams-canal", 500, %{}, 500)],
               "credit" => credit_entry(0, %{}, 0),
               "late_adjustments" => zero_late_adjustments()
             }

      # The exact retry returns its stored result and adds no movement.
      conn = post_operations(conn, [payment])
      assert [%{"status" => "applied", "amount_cents" => 500}] = results(conn)

      assert finance_report(conn, "2027-01-03") == first_reading
      assert %{"cash_held_cents" => 500} = ledger_data(conn)
    end

    test "the report reconciles with the ledger and reads never change state", %{conn: conn} do
      conn =
        post_operations(conn, [
          open_2027_group("rec-group", "ams-canal"),
          open_operation(%{
            "group_id" => "group-b",
            "property_id" => "rot-lake",
            "guest_id" => "guest-22",
            "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 20_000}]
          }),
          start_reporting_operation(@start),
          payment_operation("rec-group", 6_000, %{"occurred_on" => "2027-01-02"}),
          transfer_deposit_operation("rec-group", "group-b", 1_500, %{
            "occurred_on" => "2027-01-03"
          }),
          cancel_operation("rec-group", %{"occurred_on" => "2027-01-04"}),
          payment_operation("group-b", 500, %{"occurred_on" => "2027-01-04"})
        ])

      assert Enum.all?(results(conn), &(&1["status"] == "applied"))

      # Every property's held cash walks forward day by day.
      assert finance_report(conn, "2027-01-02")["cash"] == [
               cash_entry("ams-canal", 0, %{"received_cents" => 6_000}, 6_000)
             ]

      assert finance_report(conn, "2027-01-03")["cash"] == [
               cash_entry("ams-canal", 6_000, %{"transferred_out_cents" => 1_500}, 4_500),
               cash_entry("rot-lake", 0, %{"transferred_in_cents" => 1_500}, 1_500)
             ]

      report = finance_report(conn, "2027-01-04")

      assert report["cash"] == [
               cash_entry("ams-canal", 4_500, %{"refunded_cents" => 4_500}, 0),
               cash_entry("rot-lake", 1_500, %{"received_cents" => 500}, 2_000)
             ]

      # The closings tie out to the current ledger view.
      assert %{"cash_held_cents" => held} = ledger_data(conn)
      assert Enum.sum(Enum.map(report["cash"], & &1["closing_held_cents"])) == held
    end
  end
end
