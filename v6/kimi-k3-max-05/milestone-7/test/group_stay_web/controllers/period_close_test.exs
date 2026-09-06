defmodule GroupStayWeb.PeriodCloseTest do
  use GroupStayWeb.ConnCase, async: false

  defp post_batch(conn, body) do
    post(conn, ~p"/api/v1/partner-batches", body)
  end

  defp get_report(query) do
    get(build_conn(), "/api/v1/finance/daily-report" <> query)
  end

  defp report(date) do
    conn = get_report("?date=#{date}")
    assert %{"data" => data} = json_response(conn, 200)
    data
  end

  defp get_ledger(query \\ "") do
    conn = get(build_conn(), "/api/v1/ledger" <> query)
    json_response(conn, 200)["data"]
  end

  defp get_group(group_id) do
    conn = get(build_conn(), "/api/v1/groups/#{group_id}")
    json_response(conn, 200)["data"]
  end

  defp get_payment(payment_operation_id) do
    conn = get(build_conn(), "/api/v1/payments/#{payment_operation_id}")
    json_response(conn, 200)["data"]
  end

  # Two flexible rooms for three nights: deposits 9_000 and 10_500 (19_500 in
  # total). Booked 2026-10-03 with arrival 2026-12-10, so the flexible policy
  # is refundable through 2026-11-26.
  defp open_op(overrides \\ %{}) do
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
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  # One flexible room for two nights at 20_000: an 8_000 deposit.
  defp open_one_room_op(group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => "op-open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-12",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 20_000}]
      },
      overrides
    )
  end

  defp payment_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp cancel_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-20",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp chargeback_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-11-22",
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  defp start_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-start",
        "type" => "start_finance_reporting",
        "occurred_on" => "2026-10-01",
        "starts_on" => "2026-10-01"
      },
      overrides
    )
  end

  defp close_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-close",
        "type" => "close_finance_period",
        "occurred_on" => "2026-10-31",
        "period_end_on" => "2026-10-31"
      },
      overrides
    )
  end

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

  defp zero_late_adjustments do
    %{"cash" => [], "credit" => zero_credit_movements()}
  end

  # Opens, funds, and refunds a flexible group into a hotel credit lot of
  # `cash_cents` + 10%, expiring on 2027-11-20.
  defp issue_credit(conn, guest_id, group_id, cash_cents) do
    operations = [
      open_op(%{
        "operation_id" => "op-open-#{group_id}",
        "group_id" => group_id,
        "guest_id" => guest_id
      }),
      payment_op(%{
        "operation_id" => "op-pay-#{group_id}",
        "group_id" => group_id,
        "amount_cents" => cash_cents
      }),
      cancel_op(%{
        "operation_id" => "op-cancel-#{group_id}",
        "group_id" => group_id,
        "refund_method" => "hotel_credit"
      })
    ]

    conn = post_batch(conn, %{"operations" => operations})
    assert %{"results" => [_, _, %{"status" => "applied"}]} = json_response(conn, 200)
  end

  describe "close_finance_period" do
    test "the applied result contains exactly operation_id, status, and period_end_on", %{
      conn: conn
    } do
      operations = [start_op(), close_op()]
      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [%{"status" => "applied"}, result]} = json_response(conn, 200)

      assert result == %{
               "operation_id" => "op-close",
               "status" => "applied",
               "period_end_on" => "2026-10-31"
             }
    end

    test "rejects invalid_period before reporting has started, durably", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [close_op()]})
      assert %{"results" => [rejected]} = json_response(conn, 200)

      assert rejected == %{
               "operation_id" => "op-close",
               "status" => "rejected",
               "code" => "invalid_period"
             }

      # the rejection is remembered and replays verbatim
      conn = post_batch(build_conn(), %{"operations" => [close_op()]})
      assert %{"results" => [^rejected]} = json_response(conn, 200)

      # reporting can still start afterwards
      conn = post_batch(build_conn(), %{"operations" => [start_op()]})
      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)
    end

    test "rejects a cutoff before starts_on and invalid or missing dates", %{conn: conn} do
      operations = [
        start_op(),
        close_op(%{"operation_id" => "op-c1", "period_end_on" => "2026-09-30"}),
        close_op(%{"operation_id" => "op-c2", "period_end_on" => "2026-13-01"}),
        close_op(%{"operation_id" => "op-c3", "period_end_on" => "31/10/2026"}),
        close_op(%{"operation_id" => "op-c4", "period_end_on" => nil}),
        close_op(%{"operation_id" => "op-c5"}) |> Map.delete("period_end_on"),
        close_op(%{"operation_id" => "op-c6"}) |> Map.delete("occurred_on"),
        close_op(%{"operation_id" => "op-c7", "occurred_on" => nil})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{
               "results" => [
                 _,
                 before_start,
                 bad_month,
                 bad_format,
                 nil_date,
                 missing,
                 no_date,
                 no_id
               ]
             } =
               json_response(conn, 200)

      assert before_start["code"] == "invalid_period"
      assert bad_month["code"] == "invalid_reporting_date"
      assert bad_format["code"] == "invalid_reporting_date"
      assert nil_date["code"] == "invalid_reporting_date"
      assert missing["code"] == "invalid_reporting_date"
      assert no_date["code"] == "invalid_operation"
      assert no_id["code"] == "invalid_operation"

      # none of them closed anything: every day since the start is still open
      assert report("2026-10-01")["status"] == "open"
      assert report("2026-10-31")["status"] == "open"
    end

    test "a cutoff on starts_on itself is valid", %{conn: conn} do
      operations = [start_op(), close_op(%{"period_end_on" => "2026-10-01"})]
      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, %{"status" => "applied"}]} = json_response(conn, 200)

      assert report("2026-10-01")["status"] == "closed"
      assert report("2026-10-02")["status"] == "open"
    end

    test "a cutoff must move strictly past the latest successful close", %{conn: conn} do
      conn = post_batch(conn, %{"operations" => [start_op(), close_op()]})
      assert %{"results" => [_, applied]} = json_response(conn, 200)
      assert applied["status"] == "applied"

      # a retry of the original close returns the exact stored result
      conn = post_batch(build_conn(), %{"operations" => [close_op()]})
      assert %{"results" => [^applied]} = json_response(conn, 200)

      # a different operation attempting the same or an earlier cutoff fails
      for period_end_on <- ["2026-10-31", "2026-10-15", "2026-10-01"] do
        conn =
          post_batch(build_conn(), %{
            "operations" => [
              close_op(%{
                "operation_id" => "op-close-#{period_end_on}",
                "period_end_on" => period_end_on
              })
            ]
          })

        assert %{"results" => [rejected]} = json_response(conn, 200)
        assert rejected["status"] == "rejected"
        assert rejected["code"] == "invalid_period"
      end

      # a strictly later cutoff succeeds
      conn =
        post_batch(build_conn(), %{
          "operations" => [
            close_op(%{"operation_id" => "op-close-2", "period_end_on" => "2026-11-30"})
          ]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      # reusing the original identifier with a different payload conflicts
      conn =
        post_batch(build_conn(), %{
          "operations" => [close_op(%{"period_end_on" => "2026-12-31"})]
        })

      assert %{"results" => [conflict]} = json_response(conn, 200)
      assert conflict["code"] == "operation_id_conflict"

      # the stored result of the original close is still served verbatim
      conn = get(build_conn(), "/api/v1/operations/op-close")
      assert json_response(conn, 200) == %{"data" => applied}
    end
  end

  describe "published reports" do
    test "reports through the cutoff are closed and later reports stay open", %{conn: conn} do
      operations = [
        start_op(),
        open_op(),
        payment_op(),
        close_op(%{"period_end_on" => "2026-10-05"})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      for date <- ["2026-10-01", "2026-10-04", "2026-10-05"] do
        assert report(date)["status"] == "closed"
      end

      assert report("2026-10-06")["status"] == "open"

      # a day without movements is published too
      assert report("2026-10-02") == %{
               "date" => "2026-10-02",
               "status" => "closed",
               "cash" => [],
               "credit" => %{
                 "opening_liability_cents" => 0,
                 "movements" => zero_credit_movements(),
                 "closing_liability_cents" => 0
               },
               "late_adjustments" => zero_late_adjustments()
             }
    end

    test "a published report is byte-for-byte stable across later operations and closes", %{
      conn: conn
    } do
      operations = [start_op(), open_op(), payment_op()]
      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      open_report = report("2026-10-04")
      assert open_report["status"] == "open"

      conn =
        post_batch(build_conn(), %{"operations" => [close_op(%{"period_end_on" => "2026-10-05"})]})

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      closed_report = report("2026-10-04")
      assert closed_report == %{open_report | "status" => "closed"}

      # a later old-dated payment cannot change the published day
      conn =
        post_batch(build_conn(), %{
          "operations" => [
            payment_op(%{
              "operation_id" => "op-pay-2",
              "occurred_on" => "2026-10-04",
              "amount_cents" => 3_000
            })
          ]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)
      assert report("2026-10-04") == closed_report

      # nor can a later close
      conn =
        post_batch(build_conn(), %{
          "operations" => [
            close_op(%{"operation_id" => "op-close-2", "period_end_on" => "2026-11-30"})
          ]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)
      assert report("2026-10-04") == closed_report

      # the day the late payment landed on was published by that second close
      day = report("2026-10-06")
      assert day["status"] == "closed"

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "closing_held_cents" => 8_000,
                 "movements" => movements
               }
             ] = day["cash"]

      assert movements["received_cents"] == 0

      assert [
               %{"property_id" => "ams-canal", "movements" => late_movements}
             ] = day["late_adjustments"]["cash"]

      assert late_movements["received_cents"] == 3_000
    end

    test "a frozen report includes the derived credit expiry and survives later corrections", %{
      conn: conn
    } do
      issue_credit(conn, "guest-22", "group-91", 10_000)

      conn =
        post_batch(build_conn(), %{
          "operations" => [start_op(%{"starts_on" => "2026-11-21"})]
        })

      assert %{"results" => [_]} = json_response(conn, 200)

      conn =
        post_batch(build_conn(), %{
          "operations" => [close_op(%{"period_end_on" => "2027-11-25"})]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      # the lot expired on 2027-11-20; the frozen boundary day carries the
      # derived expiry with no partner operation behind it
      boundary = report("2027-11-21")

      assert boundary["status"] == "closed"

      assert %{
               "opening_liability_cents" => 11_000,
               "closing_liability_cents" => 0,
               "movements" => %{"expired_cents" => 11_000}
             } = boundary["credit"]

      # a dormant revocation after the close keeps the frozen report intact
      conn =
        post_batch(build_conn(), %{
          "operations" => [
            chargeback_op(%{
              "operation_id" => "op-chargeback-91",
              "payment_operation_id" => "op-pay-group-91",
              "occurred_on" => "2027-11-26"
            })
          ]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)
      assert report("2027-11-21") == boundary
      assert report("2027-11-26")["credit"]["movements"] == zero_credit_movements()
    end
  end

  describe "posting after a close" do
    test "an old-dated operation posts on the first open day as a late adjustment", %{conn: conn} do
      operations = [
        start_op(),
        open_op(),
        payment_op(),
        close_op(%{"period_end_on" => "2026-10-05"})
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn =
        post_batch(build_conn(), %{
          "operations" => [
            payment_op(%{
              "operation_id" => "op-pay-2",
              "occurred_on" => "2026-10-04",
              "amount_cents" => 3_000
            })
          ]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      day = report("2026-10-06")
      assert day["status"] == "open"

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "closing_held_cents" => 8_000,
                 "movements" => movements
               }
             ] = day["cash"]

      assert movements == zero_cash_movements()

      assert day["late_adjustments"] == %{
               "cash" => [
                 %{
                   "property_id" => "ams-canal",
                   "movements" => %{zero_cash_movements() | "received_cents" => 3_000}
                 }
               ],
               "credit" => zero_credit_movements()
             }
    end

    test "an operation whose occurred_on is already in the open period keeps that date", %{
      conn: conn
    } do
      operations = [start_op(), open_op(), close_op(%{"period_end_on" => "2026-10-05"})]
      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn =
        post_batch(build_conn(), %{
          "operations" => [payment_op(%{"occurred_on" => "2026-10-20"})]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      day = report("2026-10-20")

      assert [
               %{
                 "opening_held_cents" => 0,
                 "closing_held_cents" => 5_000,
                 "movements" => %{"received_cents" => 5_000}
               }
             ] = day["cash"]

      assert day["late_adjustments"] == zero_late_adjustments()

      # nothing posts on the first open day
      assert report("2026-10-06")["cash"] == []
    end

    test "operations immediately before and after a close in one batch post on either side", %{
      conn: conn
    } do
      operations = [
        start_op(),
        open_op(),
        payment_op(%{"occurred_on" => "2026-10-04"}),
        close_op(%{"period_end_on" => "2026-10-05"}),
        payment_op(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-10-03",
          "amount_cents" => 3_000
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # the payment before the close posted into the period being closed
      day = report("2026-10-04")
      assert day["status"] == "closed"
      assert [%{"movements" => %{"received_cents" => 5_000}}] = day["cash"]
      assert day["late_adjustments"] == zero_late_adjustments()

      # the old-dated payment after the close posted on the first open day
      day = report("2026-10-06")
      assert day["status"] == "open"
      assert [%{"movements" => movements}] = day["cash"]
      assert movements == zero_cash_movements()

      assert [
               %{"property_id" => "ams-canal", "movements" => late_movements}
             ] = day["late_adjustments"]["cash"]

      assert late_movements["received_cents"] == 3_000
    end

    test "an operation keeps the posting date chosen when it commits", %{conn: conn} do
      operations = [start_op(), open_op(), payment_op(%{"occurred_on" => "2026-10-20"})]
      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      conn =
        post_batch(build_conn(), %{
          "operations" => [close_op(%{"period_end_on" => "2026-10-31"})]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      # the payment stays on its original day inside the published period
      day = report("2026-10-20")
      assert day["status"] == "closed"

      assert [
               %{
                 "opening_held_cents" => 0,
                 "closing_held_cents" => 5_000,
                 "movements" => %{"received_cents" => 5_000}
               }
             ] = day["cash"]

      assert day["late_adjustments"] == zero_late_adjustments()

      # and nothing leaks onto the first open day
      day = report("2026-11-01")
      assert day["status"] == "open"
      assert [%{"movements" => movements}] = day["cash"]
      assert movements == zero_cash_movements()
      assert day["late_adjustments"] == zero_late_adjustments()
    end

    test "credit issued by a late operation expires on its posting day when the true boundary closed",
         %{conn: conn} do
      operations = [
        start_op(),
        open_one_room_op("group-81", %{}),
        payment_op(%{"amount_cents" => 5_000}),
        close_op(%{"period_end_on" => "2027-11-30"}),
        # old-dated refundable cancellation into hotel credit: the lot's
        # expiry (2027-11-20) and its boundary fell inside the closed period,
        # so the liability enters and leaves on the first open day
        cancel_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, _, cancel]} = json_response(conn, 200)
      assert cancel["status"] == "applied"
      assert cancel["credit_issued_cents"] == 5_500

      day = report("2027-12-01")
      assert day["status"] == "open"

      assert %{
               "opening_liability_cents" => 0,
               "closing_liability_cents" => 0,
               "movements" => movements
             } = day["credit"]

      assert movements == %{zero_credit_movements() | "expired_cents" => 5_500}

      assert %{zero_credit_movements() | "issued_cents" => 5_500} ==
               day["late_adjustments"]["credit"]

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "closing_held_cents" => 0
               }
             ] = day["cash"]

      assert [
               %{"movements" => %{"converted_to_credit_cents" => 5_000}}
             ] = day["late_adjustments"]["cash"]

      # the report reconciles with the current view: the lot is already past
      assert %{"credit_liability_cents" => 0} = get_ledger("?on=2027-12-01")
    end

    test "a late transfer moves held cash between properties on the first open day", %{conn: conn} do
      operations = [
        start_op(),
        open_op(),
        open_one_room_op("group-82", %{"property_id" => "yyz-airport"}),
        payment_op(),
        close_op(%{"period_end_on" => "2026-10-05"}),
        %{
          "operation_id" => "op-transfer",
          "type" => "transfer_deposit",
          "occurred_on" => "2026-10-04",
          "source_group_id" => "group-81",
          "destination_group_id" => "group-82",
          "amount_cents" => 2_000
        }
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      day = report("2026-10-06")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 5_000,
                 "closing_held_cents" => 3_000,
                 "movements" => movements_a
               },
               %{
                 "property_id" => "yyz-airport",
                 "opening_held_cents" => 0,
                 "closing_held_cents" => 2_000,
                 "movements" => movements_b
               }
             ] = day["cash"]

      assert movements_a == zero_cash_movements()
      assert movements_b == zero_cash_movements()

      assert day["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" => %{zero_cash_movements() | "transferred_out_cents" => 2_000}
               },
               %{
                 "property_id" => "yyz-airport",
                 "movements" => %{zero_cash_movements() | "transferred_in_cents" => 2_000}
               }
             ]
    end

    test "a second close moves the first open day forward", %{conn: conn} do
      operations = [
        start_op(),
        open_op(),
        payment_op(%{
          "operation_id" => "op-pay-1",
          "occurred_on" => "2026-10-02",
          "amount_cents" => 2_000
        }),
        close_op(%{"period_end_on" => "2026-10-31"}),
        payment_op(%{
          "operation_id" => "op-pay-2",
          "occurred_on" => "2026-10-03",
          "amount_cents" => 3_000
        }),
        close_op(%{"operation_id" => "op-close-2", "period_end_on" => "2026-11-30"}),
        payment_op(%{
          "operation_id" => "op-pay-3",
          "occurred_on" => "2026-10-04",
          "amount_cents" => 4_000
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      # the first late payment posted on the day after the first cutoff; that
      # report is now published and keeps its late adjustments
      day = report("2026-11-01")
      assert day["status"] == "closed"

      assert [
               %{
                 "opening_held_cents" => 2_000,
                 "closing_held_cents" => 5_000,
                 "movements" => movements
               }
             ] = day["cash"]

      assert movements == zero_cash_movements()

      assert [
               %{"movements" => %{"received_cents" => 3_000}}
             ] = day["late_adjustments"]["cash"]

      # the second late payment posts on the day after the second cutoff
      day = report("2026-12-01")
      assert day["status"] == "open"

      assert [
               %{
                 "opening_held_cents" => 5_000,
                 "closing_held_cents" => 9_000,
                 "movements" => movements
               }
             ] = day["cash"]

      assert movements == zero_cash_movements()

      assert [
               %{"movements" => %{"received_cents" => 4_000}}
             ] = day["late_adjustments"]["cash"]
    end
  end

  describe "late adjustments" do
    test "signed classifications survive even when their net balance effect is zero", %{
      conn: conn
    } do
      operations = [
        start_op(),
        open_op(),
        payment_op(),
        # refundable: the cash settles as a refund inside the period
        cancel_op(%{"occurred_on" => "2026-11-20"}),
        close_op(%{"period_end_on" => "2026-11-30"}),
        # the chargeback corrects a published day, so it posts on 2026-12-01
        chargeback_op(%{"occurred_on" => "2026-11-22"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, cancel, _, chargeback]} = json_response(conn, 200)
      assert cancel["refunded_cents"] == 5_000
      assert chargeback["charged_back_cents"] == 5_000

      # the published refund day is untouched
      refunded_day = report("2026-11-20")
      assert refunded_day["status"] == "closed"
      assert [%{"movements" => %{"refunded_cents" => 5_000}}] = refunded_day["cash"]
      assert refunded_day["late_adjustments"] == zero_late_adjustments()

      day = report("2026-12-01")
      assert day["status"] == "open"

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "closing_held_cents" => 0,
                 "movements" => movements
               }
             ] = day["cash"]

      assert movements == zero_cash_movements()

      assert day["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" =>
                   Map.merge(zero_cash_movements(), %{
                     "refunded_cents" => -5_000,
                     "charged_back_cents" => 5_000
                   })
               }
             ]

      assert day["late_adjustments"]["credit"] == zero_credit_movements()

      # the ledger reclassification is unaffected by the reporting split
      assert %{"cash_refunded_cents" => 0, "cash_charged_back_cents" => 5_000} = get_ledger()
    end

    test "late credit movements list under the credit object and feed its balances", %{
      conn: conn
    } do
      operations = [
        start_op(),
        open_op(),
        payment_op(),
        # converts 5_000 cash into a 5_500 credit lot inside the period
        cancel_op(%{"occurred_on" => "2026-11-20", "refund_method" => "hotel_credit"}),
        close_op(%{"period_end_on" => "2026-11-30"}),
        # revokes the entitlement against a published day
        chargeback_op(%{"occurred_on" => "2026-11-22"})
      ]

      conn = post_batch(conn, %{"operations" => operations})

      assert %{"results" => [_, _, _, cancel, _, chargeback]} = json_response(conn, 200)
      assert cancel["credit_issued_cents"] == 5_500
      assert chargeback["charged_back_cents"] == 5_000

      # the published issuance day is untouched
      issued_day = report("2026-11-20")
      assert issued_day["status"] == "closed"
      assert %{"movements" => %{"issued_cents" => 5_500}} = issued_day["credit"]
      assert [%{"movements" => %{"converted_to_credit_cents" => 5_000}}] = issued_day["cash"]

      day = report("2026-12-01")

      assert %{
               "opening_liability_cents" => 5_500,
               "closing_liability_cents" => 0,
               "movements" => movements
             } = day["credit"]

      assert movements == zero_credit_movements()

      assert %{zero_credit_movements() | "revoked_cents" => 5_500} ==
               day["late_adjustments"]["credit"]

      assert day["late_adjustments"]["cash"] == [
               %{
                 "property_id" => "ams-canal",
                 "movements" =>
                   Map.merge(zero_cash_movements(), %{
                     "converted_to_credit_cents" => -5_000,
                     "charged_back_cents" => 5_000
                   })
               }
             ]
    end

    test "late cash rows are ordered by property and omit properties without late movements", %{
      conn: conn
    } do
      operations = [
        start_op(),
        open_op(),
        open_one_room_op("group-82", %{"property_id" => "yyz-airport"}),
        close_op(%{"period_end_on" => "2026-10-05"}),
        payment_op(%{
          "operation_id" => "op-pay-1",
          "occurred_on" => "2026-10-03",
          "amount_cents" => 3_000
        }),
        payment_op(%{
          "operation_id" => "op-pay-2",
          "group_id" => "group-82",
          "occurred_on" => "2026-10-04",
          "amount_cents" => 4_000
        })
      ]

      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => results} = json_response(conn, 200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      day = report("2026-10-06")

      assert [
               %{
                 "property_id" => "ams-canal",
                 "opening_held_cents" => 0,
                 "closing_held_cents" => 3_000,
                 "movements" => movements_a
               },
               %{
                 "property_id" => "yyz-airport",
                 "opening_held_cents" => 0,
                 "closing_held_cents" => 4_000,
                 "movements" => movements_b
               }
             ] = day["cash"]

      assert movements_a == zero_cash_movements()
      assert movements_b == zero_cash_movements()

      assert [
               %{"property_id" => "ams-canal", "movements" => %{"received_cents" => 3_000}},
               %{"property_id" => "yyz-airport", "movements" => %{"received_cents" => 4_000}}
             ] = day["late_adjustments"]["cash"]

      # a day with ordinary movements only lists no late cash rows
      day = report("2026-10-04")
      assert day["status"] == "closed"
      assert day["late_adjustments"]["cash"] == []
    end
  end

  describe "current-state semantics" do
    test "a close changes no group, ledger, payment statement, or stored operation result", %{
      conn: conn
    } do
      operations = [start_op(), open_op(), payment_op()]
      conn = post_batch(conn, %{"operations" => operations})
      assert %{"results" => [_, _, payment]} = json_response(conn, 200)

      group_before = get_group("group-81")
      ledger_before = get_ledger()
      statement_before = get_payment("op-pay")

      conn =
        post_batch(build_conn(), %{
          "operations" => [close_op(%{"period_end_on" => "2026-10-31"})]
        })

      assert %{"results" => [%{"status" => "applied"}]} = json_response(conn, 200)

      assert get_group("group-81") == group_before
      assert get_ledger() == ledger_before
      assert get_payment("op-pay") == statement_before

      # the stored payment result replays verbatim as well
      conn = post_batch(build_conn(), %{"operations" => [payment_op()]})
      assert %{"results" => [^payment]} = json_response(conn, 200)
    end
  end
end
